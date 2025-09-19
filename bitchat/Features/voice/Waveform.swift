import Foundation
import AVFoundation
import Accelerate

struct WaveformCache {
    static var shared = WaveformCache()
    private var cache: [String: [Float]] = [:]
    mutating func set(_ bins: [Float], for path: String) { cache[path] = bins }
    func get(_ path: String) -> [Float]? { cache[path] }
}

enum WaveformExtractor {
    static func extractBins(url: URL, binCount: Int = 120) -> [Float] {
        if let cached = WaveformCache.shared.get(url.path) { return cached }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { return [] }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { return [] }
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        if reader.canAdd(output) { reader.add(output) } else { return [] }
        guard reader.startReading() else { return [] }

        var samples: [Float] = []
        while reader.status == .reading {
            guard let buffer = output.copyNextSampleBuffer() else { break }
            if let block = CMSampleBufferGetDataBuffer(buffer) {
                var length = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
                   let base = dataPointer {
                    // 16-bit signed little endian
                    let count = length / 2
                    var floats = [Float](repeating: 0, count: count)
                    base.withMemoryRebound(to: Int16.self, capacity: count) { ptr in
                        vDSP.convertElements(of: UnsafeBufferPointer(start: ptr, count: count), to: &floats)
                    }
                    // Normalize to [-1,1]
                    var maxVal: Float = 32768.0
                    vDSP.divide(floats, maxVal, result: &floats)
                    samples += floats
                }
            }
            CMSampleBufferInvalidate(buffer)
        }

        guard !samples.isEmpty, reader.status == .completed || reader.status == .reading else { return [] }
        // Reduce to bins by RMS per window
        let window = max(1, samples.count / binCount)
        var bins: [Float] = []
        bins.reserveCapacity(binCount)
        var i = 0
        while i < samples.count && bins.count < binCount {
            let end = min(i + window, samples.count)
            let slice = samples[i..<end]
            var sum: Float = 0
            vDSP_svesq(slice.map { $0 }, 1, &sum, vDSP_Length(slice.count))
            let rms = sqrtf(sum / Float(slice.count))
            bins.append(min(1.0, rms))
            i = end
        }
        if bins.count < binCount {
            bins += Array(repeating: 0, count: binCount - bins.count)
        }
        WaveformCache.shared.set(bins, for: url.path)
        return bins
    }
}

