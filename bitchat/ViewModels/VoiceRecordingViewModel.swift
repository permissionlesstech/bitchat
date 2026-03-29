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
            case .permissionDenied: "Microphone access is required to record voice notes."
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

    func formattedDuration(for date: Date) -> String {
        let clamped = max(0, state.duration(for: date))
        let totalMilliseconds = Int(clamped * 1000)
        let minutes = totalMilliseconds / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1_000
        let centiseconds = (totalMilliseconds % 1_000) / 10
        return String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
    }

    func start(shouldShow: Bool) {
        guard shouldShow, state == .idle else { return }
        state = .requestingPermission
        Task {
            let granted = await VoiceRecorder.shared.requestPermission()
            guard state == .requestingPermission else { return }
            guard granted else {
                state = .permissionDenied
                return
            }
            state = .preparing
            do {
                try await VoiceRecorder.shared.startRecording()
                guard state == .preparing else {
                    cancel()
                    return
                }
                state = .recording(startDate: Date())
            } catch {
                SecureLogger.error("Voice recording failed to start: \(error)", category: .session)
                await VoiceRecorder.shared.cancelRecording()
                guard state == .preparing else { return }
                state = .error(message: "Could not start recording.")
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

        guard case .recording(let startDate) = previousState, let completion else {
            Task { await VoiceRecorder.shared.cancelRecording() }
            return
        }

        Task {
            let finalDuration = Date().timeIntervalSince(startDate)
            if let url = await VoiceRecorder.shared.stopRecording(),
               isValidRecording(at: url, duration: finalDuration) {
                completion(url)
            } else {
                guard state == .idle else { return }
                state = .error(
                    message: finalDuration < VoiceRecorder.minRecordingDuration
                    ? "Recording is too short."
                    : "Recording failed to save."
                )
            }
        }
    }

    func cancel() {
        finish(completion: nil)
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
