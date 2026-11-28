//
// VoiceRecordingViewModel.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import Foundation

/// Destination captured when a voice-note hold begins so leaving or switching
/// chats while the recording finalizes can never re-route a private voice note
/// onto the public mesh (or into a different DM).
enum VoiceNoteTarget: Equatable {
    case publicMesh
    case privateChat(PeerID)
}

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
    /// Live normalized microphone level (`0...1`) while transmitting, used by
    /// the walkie-talkie deck's pulsing halo ring.
    @Published private(set) var audioLevel: Float = 0
    /// True when the user slid up in the walkie-talkie deck to latch hands-free.
    @Published private(set) var isLockedRecording = false
    /// Brief non-modal hint shown above the composer on a quick tap (e.g., "Hold to talk").
    @Published private(set) var briefHint: String? = nil

    /// Supplies the capture backend per press. `ChatViewModel` swaps in a
    /// live push-to-talk session when the current DM peer can hear it now.
    var sessionProvider: () -> VoiceCaptureSession = { VoiceNoteCaptureSession() }
    private var activeSession: VoiceCaptureSession?
    /// Conversation captured at hold-start for the active recording.
    private var capturedTarget: VoiceNoteTarget?
    /// Monotonic press identity. A slow permission/start/finalize task from an
    /// older hold may still deliver its file, but it must never mutate the UI
    /// state of a newer hold.
    private var holdGeneration: UInt64 = 0
    private var hintDismissTask: Task<Void, Never>?

    func formattedDuration(for date: Date) -> String {
        let clamped = max(0, state.duration(for: date))
        let totalMilliseconds = Int(clamped * 1000)
        let minutes = totalMilliseconds / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1_000
        let centiseconds = (totalMilliseconds % 1_000) / 10
        return String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
    }

    func start(shouldShow: Bool, target: VoiceNoteTarget? = nil) {
        guard shouldShow, state == .idle else { return }
        clearBriefHint()
        holdGeneration &+= 1
        let generation = holdGeneration
        let session = sessionProvider()
        session.onAudioLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self,
                      self.holdGeneration == generation,
                      self.state.isActive else { return }
                self.audioLevel = level
            }
        }
        SecureLogger.info("PTT: mic hold began (backend: \(session.isLive ? "live" : "classic"))", category: .session)
        activeSession = session
        capturedTarget = target
        isLockedRecording = false
        audioLevel = 0
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
                WalkieFeedback.micArmed(isLive: session.isLive)
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
                        WalkieFeedback.micArmed(isLive: false)
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

    func lockRecording() {
        guard state.isActive, !isLockedRecording else { return }
        isLockedRecording = true
        WalkieFeedback.detent()
    }

    func stopLockedRecording(completion: ((URL, VoiceNoteTarget?) -> Void)?) {
        isLockedRecording = false
        finish(completion: completion)
    }

    func finish(completion: ((URL, VoiceNoteTarget?) -> Void)?) {
        let previousState = state
        let wasLive = isLiveStreaming

        switch previousState {
        case .permissionDenied, .error:
            return
        case .idle, .requestingPermission, .preparing, .recording:
            break
        }

        state = .idle
        isLiveStreaming = false
        isLockedRecording = false
        audioLevel = 0
        let session = activeSession
        let target = capturedTarget
        let generation = holdGeneration
        activeSession = nil
        capturedTarget = nil

        guard case .recording(let startDate) = previousState, let completion, let session else {
            // A quick press releases before the recorder spins up; show a subtle
            // non-modal hint instead of failing silently so users know to hold.
            SecureLogger.info("PTT: mic released before recording started (state was \(previousState)) — hold longer to record", category: .session)
            if completion != nil, previousState == .requestingPermission || previousState == .preparing {
                showBriefHint(
                    session?.isLive == true
                    ? String(localized: "walkie.hint.hold_live", defaultValue: "Hold to talk live", comment: "Brief hint shown when the user taps instead of holding the mic while live voice is armed")
                    : String(localized: "walkie.hint.hold_to_talk", defaultValue: "Hold to talk", comment: "Brief hint shown when the user taps instead of holding the mic button")
                )
            } else if completion == nil, case .recording = previousState {
                WalkieFeedback.canceled()
            }
            Task { await session?.cancel() }
            return
        }

        WalkieFeedback.micReleased(isLive: wasLive)

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
                completion(url, target)
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
    func panicWipe() {
        holdGeneration &+= 1
        clearBriefHint()
        let session = activeSession
        activeSession = nil
        capturedTarget = nil
        state = .idle
        isLiveStreaming = false
        isLockedRecording = false
        audioLevel = 0
        session?.panicCancelSynchronously()
    }

    private func showBriefHint(_ message: String) {
        hintDismissTask?.cancel()
        briefHint = message
        hintDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.briefHint = nil
        }
    }

    private func clearBriefHint() {
        hintDismissTask?.cancel()
        hintDismissTask = nil
        if briefHint != nil {
            briefHint = nil
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
