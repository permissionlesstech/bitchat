import SwiftUI
import AVFoundation

struct VoiceMessageRow: View {
    let fileURL: URL
    var sendProgress: Double? = nil // 0..1 filling during send
    @State private var bins: [Float] = []
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var duration: TimeInterval = 0
    @State private var player: AVAudioPlayer?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Play / Pause control (fixed size similar to Android's 28dp)
            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
            }
            .buttonStyle(.plain)

            // Waveform takes remaining width, fixed height, vertically centered
            GeometryReader { geo in
                let barWidth: CGFloat = 2
                let barSpacing: CGFloat = 2
                let step = barWidth + barSpacing
                let maxBars = max(0, Int(floor(geo.size.width / step)))
                let displayCount = min(maxBars, bins.count)

                ZStack(alignment: .leading) {
                    // Base waveform (gray)
                    HStack(spacing: barSpacing) {
                        ForEach(0..<displayCount, id: \.self) { i in
                            let v = bins[i]
                            let normalizedV = v <= 0 ? 0 : min(1.0, log(1.0 + v * 9.0) / log(10.0))
                            let h = max(2, CGFloat(normalizedV) * geo.size.height)
                            VStack { Spacer(minLength: 0); Capsule().fill(Color.gray.opacity(0.4)).frame(width: barWidth, height: h); Spacer(minLength: 0) }
                        }
                    }

                    // Filled progress (blue) or send progress if provided
                    let activeProgress = sendProgress ?? progress
                    let filledBars = Int(Double(displayCount) * activeProgress)
                    HStack(spacing: barSpacing) {
                        ForEach(0..<max(0, min(displayCount, filledBars)), id: \.self) { i in
                            let v = bins[i]
                            let normalizedV = v <= 0 ? 0 : min(1.0, log(1.0 + v * 9.0) / log(10.0))
                            let h = max(2, CGFloat(normalizedV) * geo.size.height)
                            VStack { Spacer(minLength: 0); Capsule().fill(Color.blue).frame(width: barWidth, height: h); Spacer(minLength: 0) }
                        }
                    }
                }
                .clipped() // prevent overflow beyond available width/height
            }
            .frame(height: 36)

            // Reserve width for duration to avoid being pushed out by waveform
            Text(formattedDuration)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .onAppear(perform: load)
        .onDisappear { player?.stop(); isPlaying = false }
    }

    private var formattedDuration: String {
        let total = duration
        let mins = Int(total) / 60
        let secs = Int(total) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func load() {
        bins = WaveformExtractor.extractBins(url: fileURL, binCount: 120)
        do {
            player = try AVAudioPlayer(contentsOf: fileURL)
            duration = player?.duration ?? 0
            player?.prepareToPlay()
            startProgressTimer()
        } catch {
            // Ignore
        }
    }

    private func togglePlay() {
        guard let p = player else { return }
        if isPlaying { p.pause(); isPlaying = false }
        else { p.play(); isPlaying = true; startProgressTimer() }
    }

    private func startProgressTimer() {
        guard let p = player else { return }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            if !isPlaying || p.duration == 0 { t.invalidate(); return }
            progress = min(1.0, p.currentTime / p.duration)
            if progress >= 1.0 { isPlaying = false; t.invalidate() }
        }
    }
}
