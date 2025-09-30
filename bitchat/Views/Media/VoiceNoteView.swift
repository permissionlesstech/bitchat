import SwiftUI
import AVFoundation

struct VoiceNoteView: View {
    private let url: URL
    private let isSending: Bool
    private let sendProgress: Double?
    private let onCancel: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var playback: VoiceNotePlaybackController
    @State private var waveform: [Float] = []

    init(url: URL, isSending: Bool, sendProgress: Double?, onCancel: (() -> Void)?) {
        self.url = url
        self.isSending = isSending
        self.sendProgress = sendProgress
        self.onCancel = onCancel
        _playback = StateObject(wrappedValue: VoiceNotePlaybackController(url: url))
    }

    private var samples: [Float] {
        if waveform.isEmpty {
            return Array(repeating: 0.25, count: 64)
        }
        return waveform
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.6) : Color.white
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.3) : Color.green.opacity(0.2)
    }

    private var durationText: String {
        let duration = playback.duration
        guard duration.isFinite, duration > 0 else { return "--:--" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var currentText: String {
        let current = playback.currentTime
        guard current.isFinite, current > 0 else { return "00:00" }
        let minutes = Int(current) / 60
        let seconds = Int(current) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var playbackLabel: String {
        playback.isPlaying ? currentText + "/" + durationText : durationText
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: playback.togglePlayback) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.green))
            }
            .buttonStyle(.plain)

            WaveformView(
                samples: samples,
                playbackProgress: playback.progress,
                sendProgress: sendProgress,
                onSeek: { fraction in
                    playback.seek(to: fraction)
                },
                isInteractive: playback.isPlaying
            )

            Text(playbackLabel)
                .font(.bitchatSystem(size: 13, design: .monospaced))
                .foregroundColor(Color.secondary)

            if let onCancel = onCancel, isSending {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.bitchatSystem(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.red.opacity(0.9)))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(backgroundColor)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 6, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(borderColor, lineWidth: 1)
        )
        .task {
            // Defer loading to let UI settle after view appears
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            playback.loadDuration()
            await withCheckedContinuation { continuation in
                WaveformCache.shared.waveform(for: url, completion: { bins in
                    waveform = bins
                    continuation.resume()
                })
            }
        }
        .onChange(of: url) { newValue in
            WaveformCache.shared.waveform(for: newValue, completion: { bins in
                self.waveform = bins
            })
            playback.replaceURL(newValue)
        }
        .onDisappear {
            playback.stop()
        }
    }
}
