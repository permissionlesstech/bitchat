import SwiftUI
import AVFoundation

struct VoiceNoteView: View {
    private let url: URL
    private let isSending: Bool
    private let sendProgress: Double?
    private let isLive: Bool
    private let onCancel: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @ThemedPalette private var palette
    @StateObject private var playback: VoiceNotePlaybackController
    @State private var waveform: [Float] = []

    init(url: URL, isSending: Bool, sendProgress: Double?, isLive: Bool = false, onCancel: (() -> Void)?) {
        self.url = url
        self.isSending = isSending
        self.sendProgress = sendProgress
        self.isLive = isLive
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
        // Palette-based and slightly translucent so the card doesn't sit as
        // an opaque white/black box over the glass gradient.
        palette.background.opacity(colorScheme == .dark ? 0.6 : 0.7)
    }

    private var borderColor: Color {
        colorScheme == .dark ? palette.accent.opacity(0.3) : palette.accent.opacity(0.2)
    }

    private var playbackLabel: String {
        guard playback.duration.isFinite else { return "--:--" }
        let seconds = playback.isPlaying ? playback.remainingSeconds : playback.roundedDuration
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: playback.togglePlayback) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(palette.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                playback.isPlaying
                ? String(localized: "media.voice.accessibility.pause", comment: "Accessibility label for pausing voice note playback")
                : String(localized: "media.voice.accessibility.play", comment: "Accessibility label for playing a voice note")
            )
            .accessibilityValue(playbackLabel)

            WaveformView(
                samples: samples,
                playbackProgress: playback.progress,
                sendProgress: sendProgress,
                onSeek: { fraction in
                    playback.seek(to: fraction)
                },
                isInteractive: playback.isPlaying
            )

            if isLive {
                LiveVoiceBadge()
            } else {
                Text(playbackLabel)
                    .bitchatFont(size: 13)
                    .foregroundColor(palette.secondary)
            }

            if let onCancel = onCancel, isSending {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.bitchatSystem(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.red.opacity(0.9)))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(localized: "media.accessibility.cancel_send", comment: "Accessibility label for the cancel button on an in-flight media send")
                )
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
