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
    @Published var alertMessage = ""
    @Published var showAlert = false
    @Published var isRecording = false
    @Published var isPreparing = false
    @Published var duration: TimeInterval = 0

    private var timer: Timer?
    private var startDate: Date?
    private let minimumDuration: TimeInterval = 1

    var isActive: Bool {
        isPreparing || isRecording
    }

    var formattedDuration: String {
        let clamped = max(0, duration)
        let totalMilliseconds = Int((clamped * 1000).rounded())
        let minutes = totalMilliseconds / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1_000
        let centiseconds = (totalMilliseconds % 1_000) / 10
        return String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
    }

    func start(shouldShow: Bool) {
        guard shouldShow && !isRecording && !isPreparing else { return }
        isPreparing = true
        Task { @MainActor in
            let granted = await VoiceRecorder.shared.requestPermission()
            guard granted else {
                isPreparing = false
                alertMessage = "Microphone access is required to record voice notes."
                showAlert = true
                return
            }
            do {
                _ = try VoiceRecorder.shared.startRecording()
                duration = 0
                startDate = Date()
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        if let start = self.startDate {
                            self.duration = Date().timeIntervalSince(start)
                        }
                    }
                }
                if let timer {
                    RunLoop.main.add(timer, forMode: .common)
                }
                isPreparing = false
                isRecording = true
            } catch {
                SecureLogger.error("Voice recording failed to start: \(error)", category: .session)
                alertMessage = "Could not start recording."
                showAlert = true
                VoiceRecorder.shared.cancelRecording()
                isPreparing = false
                isRecording = false
                startDate = nil
            }
        }
    }

    func finishAndSend(using closure: @escaping (URL) -> Void) {
        stop()
        let capturedDuration = duration
        VoiceRecorder.shared.stopRecording { [weak self] url in
            DispatchQueue.main.async {
                guard let self else { return }
                guard
                    let url,
                    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                    let fileSize = attributes[.size] as? NSNumber,
                    fileSize.intValue > 0,
                    capturedDuration >= self.minimumDuration
                else {
                    if let url {
                        try? FileManager.default.removeItem(at: url)
                    }
                    self.alertMessage = capturedDuration < self.minimumDuration
                        ? "Recording is too short."
                        : "Recording failed to save."
                    self.showAlert = true
                    return
                }
                closure(url)
            }
        }
    }

    func cancel() {
        if isActive {
            stop()
            VoiceRecorder.shared.cancelRecording()
        }
    }

    private func stop() {
        if isPreparing {
            isPreparing = false
            VoiceRecorder.shared.cancelRecording()
            return
        }
        guard isRecording else { return }
        isRecording = false
        timer?.invalidate()
        timer = nil
        if let startDate {
            duration = Date().timeIntervalSince(startDate)
        }
        startDate = nil
    }
}
