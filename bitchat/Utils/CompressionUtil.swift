//
// CompressionUtil.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Compression

struct CompressionUtil {
    // Compression threshold - don't compress if data is smaller than this
    static let compressionThreshold = 100 // bytes
    
    // Compress data using LZ4 algorithm (fast compression/decompression)
    static func compress(_ data: Data) -> Data? {
        // Skip compression for small data
        guard data.count >= compressionThreshold else { return nil }
        
        let maxCompressedSize = data.count + (data.count / 255) + 16
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxCompressedSize)
        defer { destinationBuffer.deallocate() }
        
        let compressedSize = data.withUnsafeBytes { sourceBuffer in
            guard let sourcePtr = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                destinationBuffer, data.count,
                sourcePtr, data.count,
                nil, COMPRESSION_LZ4
            )
        }
        
        guard compressedSize > 0 && compressedSize < data.count else { return nil }
        
        return Data(bytes: destinationBuffer, count: compressedSize)
    }
    
    // Decompress LZ4 compressed data
    static func decompress(_ compressedData: Data, originalSize: Int) -> Data? {
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: originalSize)
        defer { destinationBuffer.deallocate() }
        
        let decompressedSize = compressedData.withUnsafeBytes { sourceBuffer in
            guard let sourcePtr = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer, originalSize,
                sourcePtr, compressedData.count,
                nil, COMPRESSION_LZ4
            )
        }
        
        guard decompressedSize > 0 else { return nil }
        
        return Data(bytes: destinationBuffer, count: decompressedSize)
    }
    
    // Helper to check if compression is worth it
    static func shouldCompress(_ data: Data) -> Bool {
        // Don't compress if:
        // 1. Data is too small
        // 2. Data appears to be already compressed (high entropy)
        guard data.count >= compressionThreshold else { return false }
        
        // Simple entropy check - count unique bytes
        var byteFrequency = [UInt8: Int]()
        for byte in data {
            byteFrequency[byte, default: 0] += 1
        }
        
        // If we have very high byte diversity, data is likely already compressed
        let uniqueByteRatio = Double(byteFrequency.count) / Double(min(data.count, 256))
        return uniqueByteRatio < 0.9 // Compress if less than 90% unique bytes
    }
}