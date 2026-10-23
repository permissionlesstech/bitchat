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

    @Published private(set) var state = State.idle
    /// True while the active session streams audio live (push-to-talk); the
    /// composer switches its recording HUD to the LIVE treatment.
    @Published private(set) var isLiveStreaming = false

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
    private(set) var isStartDeferred = false

    /// Set once the current mic press has started its hold. Cleared only
    /// when that press is over: lifted, cancelled, or its mic gone.
    private var pressStartedHold = false

    /// Supplies the capture backend per press. `ChatViewModel` swaps in a
    /// live push-to-talk session when the current DM peer can hear it now.
    var sessionProvider: () -> VoiceCaptureSession = { VoiceNoteCaptureSession() }
    private var activeSession: VoiceCaptureSession?
    /// Monotonic press identity. A slow permission/start/finalize task from an
    /// older hold may still deliver its file, but it must never mutate the UI
    /// state of a newer hold.
    private var holdGeneration: UInt64 = 0

    func formattedDuration(for date: Date) -> String {
        let clamped = max(0, state.duration(for: date))
        let totalMilliseconds = Int(clamped * 1000)
        let minutes = totalMilliseconds / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1_000
        let centiseconds = (totalMilliseconds % 1_000) / 10
        return String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
    }

    // MARK: - The mic press
    //
    // The composer's press-and-hold forwards its events here, so one press
    // starting at most one hold is decided in one place. The VoiceOver
    // toggle has no press and calls start/finish directly.

    /// The press moved, its touch-down included. One press, one hold: when
    /// something ends the hold under a finger still down (a conversation or
    /// layout change, the HUD's cancel, a panic), the next movement must not
    /// start another aimed at whatever is selected now. A start that only
    /// stood down while the previous note finalizes may try again.
    func pressChanged(shouldShow: Bool) {
        guard !pressStartedHold || isStartDeferred else { return }
        pressStartedHold = true
        start(shouldShow: shouldShow)
    }

    /// The finger lifted. Make `completion` at the release, so the note goes
    /// where it was recorded even if the person leaves before the file is
    /// finalized.
    func pressEnded(completion: ((URL) -> Void)?) {
        pressStartedHold = false
        finish(completion: completion)
    }

    /// The press is over, lifted or cancelled. A cancelled touch never
    /// reaches `pressEnded`, so the composer still ends a hold it leaves in
    /// flight.
    func pressReleased() {
        pressStartedHold = false
    }

    /// The mic left the screen. A hold must not outlive its control, and the
    /// end of the press and the toggle that would end it went away with it.
    /// The finger still down can't move a removed control, so the next press
    /// needs a fresh touch-down and may start a hold again.
    func controlRemoved() {
        pressStartedHold = false
        guard isHoldInFlight else { return }
        cancel()
    }

    func start(shouldShow: Bool) {
        guard shouldShow, state == .idle else { return }
        isStartDeferred = false
        holdGeneration &+= 1
        let generation = holdGeneration
        let session = sessionProvider()
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
                state = .recording(startDate: Date())
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
                        state = .recording(startDate: Date())
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

    func finish(completion: ((URL) -> Void)?) {
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
            let finalDuration = Date().timeIntervalSince(startDate)
            if let url = await session.finish() {
                // Panic and a newer hold both invalidate this completion.
                // Never route an old recording using a post-panic target.
                guard generation == holdGeneration else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                guard isValidRecording(
                    at: url,
                    duration: finalDuration
                ) else {
                    guard state == .idle else { return }
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

    func cancel() {
        finish(completion: nil)
    }

    /// Invalidates in-flight permission/start/finalize callbacks and tears
    /// down an active microphone before the panic transaction continues.
    /// A press still down stays latched: the panic ended its hold, and its
    /// next movement must not open the microphone again after the wipe.
    func panicWipe() {
        holdGeneration &+= 1
        let session = activeSession
        activeSession = nil
        state = .idle
        isLiveStreaming = false
        isStartDeferred = false
        session?.panicCancelSynchronously()
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
