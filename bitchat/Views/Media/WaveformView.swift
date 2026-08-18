import SwiftUI

struct WaveformView: View {
    let samples: [Float]
    let playbackProgress: Double
    let sendProgress: Double?
    let onSeek: ((Double) -> Void)?
    let isInteractive: Bool
    @ThemedPalette private var palette

    /// Converts a tap location into a bounded playback fraction.
    ///
    /// Keep this separate from the gesture so the coordinate contract can be
    /// tested without mounting SwiftUI. A zero-sized geometry can occur while
    /// a row is being laid out and must not result in a bogus seek.
    static func seekFraction(forX x: CGFloat, inWidth width: CGFloat) -> Double? {
        guard width > 0 else { return nil }
        return max(0, min(1, Double(x / width)))
    }

    private var clampedPlayback: Double {
        max(0, min(1, playbackProgress))
    }

    private var clampedSend: Double? {
        guard let sendProgress = sendProgress else { return nil }
        return max(0, min(1, sendProgress))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, size in
                    guard !samples.isEmpty else { return }
                    let width = max(size.width, 1)
                    let height = max(size.height, 1)
                    let barWidth = max(width / CGFloat(samples.count), 1)
                    for (index, sample) in samples.enumerated() {
                        let normalized = max(0, min(sample, 1))
                        let barHeight = CGFloat(normalized) * height
                        let originX = CGFloat(index) * barWidth
                        let rect = CGRect(
                            x: originX,
                            y: (height - barHeight) / 2,
                            width: max(barWidth * 0.7, 1),
                            height: barHeight
                        )
                        let binPosition = Double(index) / Double(samples.count)
                        let color: Color
                        if binPosition <= clampedPlayback {
                            color = palette.accent
                        } else if let send = clampedSend, binPosition <= send {
                            color = palette.accentBlue
                        } else {
                            color = palette.secondary.opacity(0.35)
                        }
                        context.fill(Path(rect), with: .color(color))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)

                if isInteractive, let onSeek = onSeek {
                    Color.clear
                        .contentShape(Rectangle())
                        // The private conversation owns a high-priority
                        // swipe-to-leave drag on the message list. A drag here
                        // is therefore interpreted as navigation instead of
                        // seeking and can close the conversation. Seeking is
                        // intentionally a tap: it preserves the swipe gesture
                        // while keeping the waveform's direct-manipulation
                        // affordance deterministic.
                        .gesture(
                            SpatialTapGesture(count: 1, coordinateSpace: .local)
                                .onEnded { value in
                                    guard let fraction = Self.seekFraction(
                                        forX: value.location.x,
                                        inWidth: geometry.size.width
                                    ) else { return }
                                    onSeek(fraction)
                                }
                        )
                }
            }
        }
        .frame(height: 48)
    }
}
