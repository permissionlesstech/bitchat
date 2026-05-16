import SwiftUI

struct WaveformView: View {
    let samples: [Float]
    let playbackProgress: Double
    let sendProgress: Double?
    let onSeek: ((Double) -> Void)?
    let isInteractive: Bool

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
                            color = Color.green
                        } else if let send = clampedSend, binPosition <= send {
                            color = Color.blue
                        } else {
                            color = Color.gray.opacity(0.35)
                        }
                        context.fill(Path(rect), with: .color(color))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)

                if isInteractive, let onSeek = onSeek {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    guard geometry.size.width > 0 else { return }
                                    let fraction = max(0, min(1, value.location.x / geometry.size.width))
                                    onSeek(fraction)
                                }
                        )
                }
            }
        }
        .frame(height: 48)
    }
}
