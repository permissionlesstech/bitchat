//
// CompressionUtil.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import struct Foundation.Data
private import Compression

struct CompressionUtil {
    // Compression threshold - don't compress if data is smaller than this
    static let compressionThreshold = Constants.compressionThresholdBytes // bytes
    
    // Compress data using zlib algorithm (most compatible)
    static func compress(_ data: Data) -> Data? {
        // Skip compression for small data
        guard data.count >= compressionThreshold else { return nil }

        let srcCount = data.count
        var output = Data(count: srcCount)
        let compressedSize = data.withUnsafeBytes { sourceBuffer -> Int in
            guard let sourcePtr = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return output.withUnsafeMutableBytes { destBuffer -> Int in
                guard let destPtr = destBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    destPtr, srcCount,
                    sourcePtr, srcCount,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard compressedSize > 0 && compressedSize < srcCount else { return nil }

        // Trim without extra copy for typical BLE frames; copy only if we'd retain >4KB of slack.
        if srcCount - compressedSize > 4096 {
            return Data(output.prefix(compressedSize))
        }
        output.count = compressedSize
        return output
    }
    
    // Decompress zlib compressed data
    static func decompress(_ compressedData: Data, originalSize: Int) -> Data? {
        guard originalSize > 0 else { return nil }
        var output = Data(count: originalSize)
        let decompressedSize = compressedData.withUnsafeBytes { sourceBuffer -> Int in
            guard let sourcePtr = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return output.withUnsafeMutableBytes { destBuffer -> Int in
                guard let destPtr = destBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destPtr, originalSize,
                    sourcePtr, compressedData.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard decompressedSize > 0 else { return nil }
        if decompressedSize != originalSize {
            output.count = decompressedSize
        }
        return output
    }
    
    // Helper to check if compression is worth it
    static func shouldCompress(_ data: Data) -> Bool {
        // Don't compress if:
        // 1. Data is too small
        // 2. Data appears to be already compressed (high entropy)
        let count = data.count
        guard count >= compressionThreshold else { return false }

        // Stack-allocated 256-bit presence bitset (branchless per byte, POPCNT
        // at chunk boundaries). Equivalent to Set(data).count / min(count, 256) < 0.9,
        // i.e. uniqueCount * 10 < sampleSize * 9, with zero heap allocation or hashing.
        let sampleSize = count < 256 ? count : 256
        let thresholdScaled = sampleSize &* 9
        return data.withUnsafeBytes { raw in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            var bits: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
            return withUnsafeMutableBytes(of: &bits) { maskRaw in
                let words = maskRaw.baseAddress!.assumingMemoryBound(to: UInt64.self)
                var i = 0
                while i < count {
                    let chunkEnd = (i &+ 256) < count ? (i &+ 256) : count
                    while i < chunkEnd {
                        let v = src[i]
                        words[Int(v &>> 6)] |= UInt64(1) &<< UInt64(v & 63)
                        i &+= 1
                    }
                    let unique = words[0].nonzeroBitCount
                        &+ words[1].nonzeroBitCount
                        &+ words[2].nonzeroBitCount
                        &+ words[3].nonzeroBitCount
                    if unique &* 10 >= thresholdScaled {
                        return false
                    }
                }
                return true
            }
        }
    }
}
