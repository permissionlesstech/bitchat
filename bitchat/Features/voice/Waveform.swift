import AVFoundation
import Foundation
import BitLogger

/// Generates and caches downsampled waveforms for audio files so UI rendering is cheap.
final class WaveformCache {
    static let shared = WaveformCache()

    /// Hard bounds on decoded waveform work so a crafted audio header cannot
    /// overflow `AVAudioFrameCount` or allocate an unbounded PCM buffer.
    static let maxWaveformDurationSeconds: TimeInterval = 600
    static let maxWaveformFrames: Int64 = 30_000_000
    private static let chunkFrameCapacity: AVAudioFrameCount = 8_192

    private let queue = DispatchQueue(label: "com.bitchat.waveform-cache", attributes: .concurrent)
    private var cache: [URL: (waveform: [Float], lastAccess: Date)] = [:]
    private var wipeGeneration: UInt64 = 0
    private let maxCacheSize = 20  // Limit cache to prevent unbounded memory growth

    private init() {}

    func cachedWaveform(for url: URL) -> [Float]? {
        queue.sync {
            guard let entry = cache[url] else { return nil }
            return entry.waveform
        }
    }

    func waveform(for url: URL, bins: Int = 120, completion: @escaping ([Float]) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let generation = self.wipeGeneration

            // Check cache (read-only, no update needed on cache hit for performance)
            if let entry = self.cache[url] {
                DispatchQueue.main.async { completion(entry.waveform) }
                return
            }

            guard let computed = Self.computeWaveform(url: url, bins: bins) else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            self.queue.async(flags: .barrier) { [weak self] in
                guard let self = self else { return }
                guard self.wipeGeneration == generation else {
                    DispatchQueue.main.async { completion([]) }
                    return
                }

                // Evict oldest entry if cache is full
                if self.cache.count >= self.maxCacheSize {
                    if let oldest = self.cache.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
                        self.cache.removeValue(forKey: oldest.key)
                    }
                }

                self.cache[url] = (computed, Date())
                DispatchQueue.main.async { completion(computed) }
            }
        }
    }

    func purge(url: URL) {
        queue.async(flags: .barrier) { [weak self] in
            self?.cache.removeValue(forKey: url)
        }
    }

    func resetForPanic() {
        queue.sync(flags: .barrier) {
            wipeGeneration &+= 1
            cache.removeAll(keepingCapacity: false)
        }
    }

    static func computeWaveform(url: URL, bins: Int) -> [Float]? {
        guard bins > 0 else { return nil }
        // Use autoreleasepool to manage memory from audio buffer allocations
        return autoreleasepool {
            do {
                let audioFile = try AVAudioFile(forReading: url)
                let format = audioFile.processingFormat
                let channelCount = Int(format.channelCount)
                let sampleRate = format.sampleRate
                guard channelCount > 0, sampleRate.isFinite, sampleRate > 0 else {
                    return nil
                }

                let rawLength = audioFile.length
                guard rawLength > 0,
                      rawLength <= maxWaveformFrames,
                      Double(rawLength) / sampleRate <= maxWaveformDurationSeconds,
                      let totalFrames = AVAudioFrameCount(exactly: rawLength) else {
                    SecureLogger.warning(
                        "Waveform rejected audio with out-of-range length (\(rawLength) frames at \(sampleRate) Hz) for \(url.lastPathComponent)",
                        category: .security
                    )
                    return nil
                }

                let bufferCapacity = min(totalFrames, chunkFrameCapacity)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferCapacity) else {
                    return nil
                }

                let totalFrameCount = Int(totalFrames)
                let samplesPerBin = max(1, totalFrameCount / bins)
                var binSums = Array(repeating: Double(0), count: bins)
                var binCounts = Array(repeating: 0, count: bins)
                var frameCursor = 0

                while frameCursor < totalFrameCount {
                    let remaining = totalFrameCount - frameCursor
                    let framesToRead = min(chunkFrameCapacity, AVAudioFrameCount(remaining))
                    buffer.frameLength = 0
                    try audioFile.read(into: buffer, frameCount: framesToRead)

                    let readFrames = Int(buffer.frameLength)
                    guard readFrames > 0, let channelData = buffer.floatChannelData else {
                        break
                    }

                    let invChannels = 1.0 / Double(channelCount)
                    for localFrame in 0..<readFrames {
                        let globalFrame = frameCursor + localFrame
                        let bin = min(bins - 1, globalFrame / samplesPerBin)
                        var sampleValue: Float = 0
                        for channel in 0..<channelCount {
                            sampleValue += fabsf(channelData[channel][localFrame])
                        }
                        binSums[bin] += Double(sampleValue) * invChannels
                        binCounts[bin] += 1
                    }

                    frameCursor += readFrames
                }

                guard frameCursor > 0 else { return nil }

                var magnitudes: [Float] = Array(repeating: 0, count: bins)
                for bin in 0..<bins where binCounts[bin] > 0 {
                    magnitudes[bin] = Float(binSums[bin] / Double(binCounts[bin]))
                }

                if let maxMagnitude = magnitudes.max(), maxMagnitude > 0 {
                    magnitudes = magnitudes.map { min($0 / maxMagnitude, 1.0) }
                }
                return magnitudes
            } catch {
                SecureLogger.error("Waveform extraction failed for \(url.lastPathComponent): \(error)", category: .session)
                return nil
            }
        }
    }
}
