import SwiftUI
import Combine

/// Real-time scrolling waveform for live recording.
/// Provide a normalized amplitude [0,1]. The view maintains a sliding window of bars.
struct RealtimeScrollingWaveform: View {
    var amplitudeNorm: CGFloat
    var bars: Int = 240
    var barColor: Color = Color(red: 0, green: 1, blue: 0.5) // neon-ish green

    @State private var samples: [CGFloat] = []
    @State private var ticker = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                guard w > 0 && h > 0 else { return }
                let n = samples.count
                guard n > 0 else { return }
                let stepX = w / CGFloat(n)
                let midY = h / 2
                let stroke: CGFloat = 1.2

                for i in 0..<n {
                    let amp = max(0, min(1, samples[i]))
                    // Amplify only higher amplitudes so quiet parts stay subtle
                    let t: CGFloat = 0.6
                    let k: CGFloat = 0.7
                    let boosted = amp <= t ? amp : min(1, amp + k * (amp - t))
                    let lineH = max(1, boosted * (h * 0.95))
                    let x = CGFloat(i) * stepX + stepX / 2
                    let yTop = midY - lineH / 2
                    let yBot = midY + lineH / 2
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: yTop))
                    path.addLine(to: CGPoint(x: x, y: yBot))
                    ctx.stroke(path, with: .color(barColor), lineWidth: stroke)
                }
            }
            .onAppear {
                if samples.isEmpty { samples = Array(repeating: 0, count: bars) }
            }
            .onChange(of: bars) { newVal in
                let clamped = max(8, newVal)
                samples = Array(samples.suffix(clamped))
                if samples.count < clamped {
                    samples.insert(contentsOf: Array(repeating: 0, count: clamped - samples.count), at: 0)
                }
            }
            .onReceive(ticker) { _ in
                let v = max(0, min(1, amplitudeNorm))
                samples.append(v)
                let overflow = samples.count - bars
                if overflow > 0 { samples.removeFirst(overflow) }
            }
        }
    }
}
