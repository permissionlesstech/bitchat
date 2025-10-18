import AVFoundation
import Foundation
import BitLogger

/// Generates and caches downsampled waveforms for audio files so UI rendering is cheap.
final class WaveformCache {
    static let shared = WaveformCache()

    private let queue = DispatchQueue(label: "com.bitchat.waveform-cache", attributes: .concurrent)
    private var cache: [URL: (waveform: [Float], lastAccess: Date)] = [:]
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

            // Check cache (read-only, no update needed on cache hit for performance)
            if let entry = self.cache[url] {
                DispatchQueue.main.async { completion(entry.waveform) }
                return
            }

            guard let computed = self.computeWaveform(url: url, bins: bins) else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            self.queue.async(flags: .barrier) { [weak self] in
                guard let self = self else { return }

                // Evict oldest entry if cache is full
                if self.cache.count >= self.maxCacheSize {
                    if let oldest = self.cache.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
                        self.cache.removeValue(forKey: oldest.key)
                    }
                }

                self.cache[url] = (computed, Date())
            }
            DispatchQueue.main.async { completion(computed) }
        }
    }

    func purge(url: URL) {
        queue.async(flags: .barrier) { [weak self] in
            self?.cache.removeValue(forKey: url)
        }
    }

    func purgeAll() {
        queue.async(flags: .barrier) { [weak self] in
            self?.cache.removeAll()
        }
    }

    private func computeWaveform(url: URL, bins: Int) -> [Float]? {
        guard bins > 0 else { return nil }
        // Use autoreleasepool to manage memory from audio buffer allocations
        return autoreleasepool {
            do {
                let audioFile = try AVAudioFile(forReading: url)
                let length = Int(audioFile.length)
                guard length > 0 else { return nil }

                guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(length)) else {
                    return nil
                }
                try audioFile.read(into: buffer, frameCount: AVAudioFrameCount(length))
                guard let channelData = buffer.floatChannelData else { return nil }

                let channelCount = Int(audioFile.processingFormat.channelCount)
                let frameLength = Int(buffer.frameLength)
                let samplesPerBin = max(1, frameLength / bins)

                var magnitudes: [Float] = Array(repeating: 0, count: bins)
                for bin in 0..<bins {
                    let start = bin * samplesPerBin
                    let end = min(frameLength, start + samplesPerBin)
                    if start >= end { break }

                    var sum: Float = 0
                    var sampleCount = 0
                    for frame in start..<end {
                        var sampleValue: Float = 0
                        for channel in 0..<channelCount {
                            sampleValue += fabsf(channelData[channel][frame])
                        }
                        sum += sampleValue / Float(channelCount)
                        sampleCount += 1
                    }
                    magnitudes[bin] = sampleCount > 0 ? sum / Float(sampleCount) : 0
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
