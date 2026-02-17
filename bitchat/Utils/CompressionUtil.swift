//
// CompressionUtil.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Compression

/// LZ4 compression utilities for reducing BLE packet payload sizes.
///
/// Used by ``BinaryProtocol`` to transparently compress payloads that exceed
/// ``compressionThreshold`` bytes and have low enough entropy to benefit.
struct CompressionUtil {
    /// Minimum payload size (in bytes) below which compression is skipped.
    static let compressionThreshold = 100

    /// Compresses `data` using LZ4.
    ///
    /// Returns `nil` if the data is smaller than ``compressionThreshold`` or
    /// if the compressed output is not smaller than the original.
    static func compress(_ data: Data) -> Data? {
        // Skip compression for small data
        guard data.count >= compressionThreshold else { return nil }
        
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
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
    
    /// Decompresses LZ4-compressed data back to its original form.
    ///
    /// - Parameters:
    ///   - compressedData: The LZ4-compressed bytes.
    ///   - originalSize: The expected decompressed size (stored alongside the compressed data in the wire format).
    /// - Returns: The decompressed data, or `nil` on failure.
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
    
    /// Heuristic check for whether `data` is likely to benefit from LZ4 compression.
    ///
    /// Returns `false` for data below ``compressionThreshold`` or data with very high
    /// byte diversity (≥ 90 % unique bytes), which suggests it is already compressed or encrypted.
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