//
// VoiceRecordingViewModel.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

@MainActor
final class VoiceRecordingViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case permissionDenied
        case preparing
        case recording(startDate: Date)
        case error(message: String)

        var isActive: Bool {
            switch self {
            case .preparing, .recording: true
            case .idle, .requestingPermission, .permissionDenied, .error: false
            }
        }

        var alertMessage: String {
            switch self {
            case .error(let message): message
            case .permissionDenied: String(localized: "voice.error.mic_permission", defaultValue: "microphone access is required to record voice notes.", comment: "Alert message when the microphone permission is denied")
            case .idle, .requestingPermission, .preparing, .recording: ""
            }
        }

        fileprivate func duration(for date: Date) -> TimeInterval {
            switch self {
            case .idle, .requestingPermission, .preparing, .permissionDenied, .error: 0
            case .recording(let startDate): date.timeIntervalSince(startDate)
            }
        }
    }

    var showAlert: Bool {
        get {
            switch state {
            case .permissionDenied, .error:   true
            case .idle, .requestingPermission, .preparing, .recording: false
            }
        }
        set {
            if !newValue { state = .idle }
        }
    }

    @Published private(set) var state = State.idle {
        didSet { releaseHoldOwnerIfOver() }
    }
    /// True while the active session streams audio live (push-to-talk); the
    /// composer switches its recording HUD to the LIVE treatment.
    @Published private(set) var isLiveStreaming = false

    /// The composer whose hold is in flight, nil while none is. There is one
    /// microphone: a hold belongs to the composer that started it, the other
    /// composer's mic is inert until it ends, and only the owner (or
    /// something that ends every hold: a layout change, a panic) can end it.
    @Published private(set) var holdOwner: ComposerSlot?

    /// A press between start() and finish()/cancel(): waiting on the
    /// microphone permission prompt, spinning up, recording, or standing by
    /// for the previous note to finalize. Wider than `state.isActive`
    /// because a hold abandoned at the permission prompt would otherwise
    /// start recording once access is granted, and one standing by would
    /// start again from the finger still down.
    var isHoldInFlight: Bool {
        state.isActive || state == .requestingPermission || isStartDeferred
    }

    /// The latest start stood down because the recorder was still
    /// finalizing the previous classic note. `pressChanged` lets that press
    /// start again, unlike one whose hold was ended or cancelled.
    private(set) var isStartDeferred = false {
        didSet { releaseHoldOwnerIfOver() }
    }

    /// The composers whose current mic press has had its one chance to
    /// start a hold: set at the press's first movement, whether or not the
    /// mic was free, and cleared only when that press is over (lifted,
    /// cancelled, or its mic gone). A press that began while another
    /// composer held the mic stays inert, so the microphone never opens
    /// under a finger that didn't touch down on a free mic.
    private var latchedPresses: Set<ComposerSlot> = []

    /// Supplies the capture backend for a start that brings none of its
    /// own. Composers that know their conversation pass `session:` instead,
    /// so a hold streams live only to the conversation it belongs to.
    var sessionProvider: () -> VoiceCaptureSession = { VoiceNoteCaptureSession() }
    private var activeSession: VoiceCaptureSession?
    /// Monotonic press identity. A slow permission/start/finalize task from an
    /// older hold may still deliver its file, but it must never mutate the UI
    /// state of a newer hold.
    private var holdGeneration: UInt64 = 0
    /// Bumped only by a panic. A note released before one must never be
    /// delivered after it; a newer hold is no reason to drop it.
    private var panicEpoch: UInt64 = 0
    /// Times a hold for the minimum-length check; tests inject one so a
    /// valid note doesn't take a second of real time.
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func formattedDuration(for date: Date) -> String {
        let clamped = max(0, state.duration(for: date))
        let totalMilliseconds = Int(clamped * 1000)
        let minutes = totalMilliseconds / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1_000
        let centiseconds = (totalMilliseconds % 1_000) / 10
        return String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
    }

    /// Whether the hold in flight, if any, belongs to `owner`'s composer:
    /// the one that shows the recording HUD and the red mic.
    func isHolding(_ owner: ComposerSlot) -> Bool {
        holdOwner == owner
    }

    // MARK: - The mic press
    //
    // The composer's press-and-hold forwards its events here, so one press
    // starting at most one hold is decided in one place. The VoiceOver
    // toggle has no press and calls start/finish directly. Every call names
    // the composer it comes from (`owner`); the `.primary` defaults serve
    // callers that name none, which are now only tests.

    /// The press moved, its touch-down included. One press, one hold: when
    /// something ends the hold under a finger still down (a conversation or
    /// layout change, the HUD's cancel, a panic), the next movement must not
    /// start another aimed at whatever is selected now. A start that only
    /// stood down while the previous note finalizes may try again.
    /// `session` makes the capture backend for the owner's conversation.
    func pressChanged(
        shouldShow: Bool,
        owner: ComposerSlot = .primary,
        session makeSession: (() -> VoiceCaptureSession)? = nil
    ) {
        let mayRetryDeferredStart = isStartDeferred && holdOwner == owner
        guard !latchedPresses.contains(owner) || mayRetryDeferredStart else { return }
        latchedPresses.insert(owner)
        start(shouldShow: shouldShow, owner: owner, session: makeSession)
    }

    /// The finger lifted. Make `completion` at the release, so the note goes
    /// where it was recorded even if the person leaves before the file is
    /// finalized. Ends only `owner`'s own hold.
    func pressEnded(owner: ComposerSlot = .primary, completion: ((URL) -> Void)?) {
        latchedPresses.remove(owner)
        finish(owner: owner, completion: completion)
    }

    /// The press is over, lifted or cancelled. A cancelled touch never
    /// reaches `pressEnded`, so the composer still ends a hold it leaves in
    /// flight.
    func pressReleased(owner: ComposerSlot = .primary) {
        latchedPresses.remove(owner)
    }

    /// The mic left the screen. A hold must not outlive its control, and the
    /// end of the press and the toggle that would end it went away with it.
    /// The finger still down can't move a removed control, so the next press
    /// needs a fresh touch-down and may start a hold again. Another
    /// composer's hold is not this mic's to end.
    func controlRemoved(owner: ComposerSlot = .primary) {
        latchedPresses.remove(owner)
        guard isHoldInFlight else { return }
        cancel(owner: owner)
    }

    /// Starts a hold for `owner`'s composer, unless the mic is busy: another
    /// composer's hold is in flight, or an alert is up. `session` makes the
    /// capture backend; without one, `sessionProvider` does.
    func start(
        shouldShow: Bool,
        owner: ComposerSlot = .primary,
        session makeSession: (() -> VoiceCaptureSession)? = nil
    ) {
        guard shouldShow, state == .idle, holdOwner == nil || holdOwner == owner else { return }
        isStartDeferred = false
        holdOwner = owner
        holdGeneration &+= 1
        let generation = holdGeneration
        let session = makeSession?() ?? sessionProvider()
        SecureLogger.info("PTT: mic hold began (backend: \(session.isLive ? "live" : "classic"))", category: .session)
        activeSession = session
        state = .requestingPermission
        Task {
            let granted = await session.requestPermission()
            guard generation == holdGeneration,
                  state == .requestingPermission,
                  activeSession === session
            else { return }
            guard granted else {
                state = .permissionDenied
                activeSession = nil
                return
            }
            state = .preparing
            do {
                try await session.start()
                guard generation == holdGeneration,
                      state == .preparing,
                      activeSession === session
                else {
                    await session.cancel()
                    return
                }
                state = .recording(startDate: now())
                isLiveStreaming = session.isLive
            } catch VoiceRecorder.RecorderError.recordingInProgress {
                // The previous classic hold may still be in its intentional
                // finalize-padding window. This press owns no recorder, so
                // its owner-scoped cancel is harmless; return to idle instead
                // of surfacing a false capture failure while the prior note
                // finishes and delivers normally.
                SecureLogger.info("Voice recording start deferred while the previous hold finalizes", category: .session)
                await session.cancel()
                guard generation == holdGeneration,
                      state == .preparing,
                      activeSession === session
                else { return }
                activeSession = nil
                isStartDeferred = true
                state = .idle
            } catch {
                SecureLogger.error("Voice recording failed to start: \(error)", category: .session)
                await session.cancel()
                guard generation == holdGeneration,
                      state == .preparing,
                      activeSession === session
                else { return }
                // The live engine and the classic recorder are separate
                // capture stacks: when the live one hits an audio-route
                // glitch, fall back within the same hold so the user still
                // gets a voice note instead of an error.
                if session.isLive {
                    let fallback = VoiceNoteCaptureSession()
                    activeSession = fallback
                    do {
                        try await fallback.start()
                        guard generation == holdGeneration,
                              state == .preparing,
                              activeSession === fallback
                        else {
                            await fallback.cancel()
                            return
                        }
                        SecureLogger.warning("PTT: live capture failed — fell back to classic voice note", category: .session)
                        state = .recording(startDate: now())
                        isLiveStreaming = false
                        return
                    } catch {
                        SecureLogger.error("Voice recording fallback failed to start: \(error)", category: .session)
                        await fallback.cancel()
                        guard generation == holdGeneration, state == .preparing else { return }
                    }
                }
                activeSession = nil
                state = .error(message: String(localized: "voice.error.start_failed", defaultValue: "could not start recording.", comment: "Alert message when the recorder fails to start"))
            }
        }
    }

    /// Ends `owner`'s hold. Make `completion` at the release: it carries the
    /// note's destination. Another composer's hold is left alone.
    func finish(owner: ComposerSlot = .primary, completion: ((URL) -> Void)?) {
        guard holdOwner == owner else { return }
        endHold(completion: completion)
    }

    /// Cancels `owner`'s hold: its composer went away, its conversation
    /// changed under it, or its touch was cancelled.
    func cancel(owner: ComposerSlot) {
        finish(owner: owner, completion: nil)
    }

    /// Cancels whichever hold is in flight: the layout changed, so every
    /// composer changes host or goes.
    func cancelAnyHold() {
        guard holdOwner != nil else { return }
        endHold(completion: nil)
    }

    private func endHold(completion: ((URL) -> Void)?) {
        let previousState = state

        switch previousState {
        case .permissionDenied, .error:
            return
        case .idle, .requestingPermission, .preparing, .recording:
            break
        }

        state = .idle
        isLiveStreaming = false
        isStartDeferred = false
        let session = activeSession
        let generation = holdGeneration
        let epoch = panicEpoch
        activeSession = nil

        guard case .recording(let startDate) = previousState, let completion, let session else {
            // A quick press releases before the recorder spins up; that has
            // always been a silent no-op for voice notes — log it so field
            // tests can tell "tapped" apart from "capture broke".
            SecureLogger.info("PTT: mic released before recording started (state was \(previousState)) — hold longer to record", category: .session)
            Task { await session?.cancel() }
            return
        }

        Task {
            let finalDuration = now().timeIntervalSince(startDate)
            if let url = await session.finish() {
                // Only a panic withholds a released note: nothing recorded
                // before one may leave after it. A newer hold, even a tap
                // during this finalize padding, is no reason to. The
                // completion was made at the release and carries its
                // destination, so dropping the note would only lose it.
                guard epoch == panicEpoch else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                guard isValidRecording(
                    at: url,
                    duration: finalDuration
                ) else {
                    // The alert is this hold's to raise. Over a newer press
                    // it would also block that press's retry, since start()
                    // needs idle.
                    guard generation == holdGeneration, state == .idle else { return }
                    state = .error(
                        message: finalDuration < VoiceRecorder.minRecordingDuration
                        ? String(localized: "voice.error.too_short", defaultValue: "recording is too short.", comment: "Alert message when a voice note is released too quickly to save")
                        : String(localized: "voice.error.save_failed", defaultValue: "recording failed to save.", comment: "Alert message when a finished voice note cannot be saved")
                    )
                    return
                }
                completion(url)
            } else {
                guard generation == holdGeneration, state == .idle else { return }
                state = .error(
                    message: finalDuration < VoiceRecorder.minRecordingDuration
                    ? String(localized: "voice.error.too_short", defaultValue: "recording is too short.", comment: "Alert message when a voice note is released too quickly to save")
                    : String(localized: "voice.error.save_failed", defaultValue: "recording failed to save.", comment: "Alert message when a finished voice note cannot be saved")
                )
            }
        }
    }

    /// Invalidates in-flight permission/start/finalize callbacks and tears
    /// down an active microphone before the panic transaction continues.
    /// A press still down stays latched: the panic ended its hold, and its
    /// next movement must not open the microphone again after the wipe.
    func panicWipe() {
        holdGeneration &+= 1
        panicEpoch &+= 1
        let session = activeSession
        activeSession = nil
        state = .idle
        isLiveStreaming = false
        isStartDeferred = false
        session?.panicCancelSynchronously()
    }

    /// Keeps `holdOwner` set exactly while a hold is in flight. Every way a
    /// hold ends (finish, cancel, a refused permission, a failed start, a
    /// panic) lands here through `state` or `isStartDeferred`.
    private func releaseHoldOwnerIfOver() {
        if holdOwner != nil, !isHoldInFlight {
            holdOwner = nil
        }
    }

    private func isValidRecording(at url: URL, duration: TimeInterval) -> Bool {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attributes[.size] as? NSNumber,
           fileSize.intValue > 0,
           duration >= VoiceRecorder.minRecordingDuration {
            return true
        }
        try? FileManager.default.removeItem(at: url)
        return false
    }
}
