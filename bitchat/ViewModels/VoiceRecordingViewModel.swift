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
        case preparing
        case recording(startDate: Date)
        case error(message: String)
        case permissionRequired

        var isActive: Bool {
            switch self {
            case .preparing, .recording: true
            case .idle, .error, .permissionRequired: false
            }
        }

        var alertMessage: String {
            switch self {
            case .error(let message): message
            case .permissionRequired: "Microphone access is required to record voice notes."
            case .idle, .preparing, .recording: ""
            }
        }

        fileprivate func duration(for date: Date) -> TimeInterval {
            switch self {
            case .idle, .error, .preparing, .permissionRequired: 0
            case .recording(let startDate): date.timeIntervalSince(startDate)
            }
        }
    }

    var showAlert: Bool {
        get {
            switch state {
            case .error, .permissionRequired:   true
            case .idle, .preparing, .recording: false
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
        Task {
            let granted = await VoiceRecorder.shared.requestPermission()
            guard granted else {
                state = .permissionRequired
                return
            }
            state = .preparing
            do {
                try await VoiceRecorder.shared.startRecording()
                guard state == .preparing else { return }
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
        switch state {
        case .idle, .error, .permissionRequired:
            return
        case .preparing:
            state = .idle
            Task { await VoiceRecorder.shared.cancelRecording() }
        case .recording(let startDate):
            state = .idle

            guard let completion else { return }

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
