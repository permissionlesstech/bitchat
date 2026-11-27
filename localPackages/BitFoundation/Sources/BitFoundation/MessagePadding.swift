//
// MessagePadding.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import struct Foundation.Data

/// Provides privacy-preserving message padding to obscure actual content length.
///
/// PKCS#7-style: every pad byte equals the pad length (1...255), which is what
/// `unpad` verifies. The bytes are not random.
///
/// Using a 256-byte bucket stride up to 2048 bytes guarantees that every frame
/// in 1...2048 bytes requires 0...255 bytes of padding, eliminating the gaps
/// where single-byte PKCS#7 previously emitted frames unpadded.
struct MessagePadding {
    // 256-byte stride keeps required padding strictly within 0...255 bytes
    // (single-byte PKCS#7 wire format, 100% compatible with existing unpad).
    static let blockSizes = [256, 512, 768, 1024, 1280, 1536, 1792, 2048]
    
    // Add PKCS#7-style padding to reach target size
    static func pad(_ data: Data, toSize targetSize: Int) -> Data {
        guard data.count < targetSize else { return data }
        
        let paddingNeeded = targetSize - data.count
        // Constrain to 255 to fit a single-byte pad length marker
        guard paddingNeeded > 0 && paddingNeeded <= 255 else { return data }
        
        var padded = data
        let oldCount = padded.count
        padded.count = targetSize
        // PKCS#7: fill tail directly via memset-equivalent without temp Array allocation.
        padded.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            base.advanced(by: oldCount).initializeMemory(as: UInt8.self, repeating: UInt8(paddingNeeded), count: paddingNeeded)
        }
        return padded
    }
    
    // Remove padding from data
    static func unpad(_ data: Data) -> Data {
        let count = data.count
        guard count > 0 else { return data }
        let start = data.withUnsafeBytes { raw -> Int? in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let last = bytes[count &- 1]
            let paddingLength = Int(last)
            guard paddingLength > 0 && paddingLength <= count else { return nil }
            let startIdx = count &- paddingLength
            var i = startIdx
            while i < count {
                if bytes[i] != last { return nil }
                i &+= 1
            }
            return startIdx
        }
        guard let start else { return data }
        return Data(data[data.startIndex..<(data.startIndex + start)])
    }
    
    // Find optimal block size for data
    static func optimalBlockSize(for dataSize: Int) -> Int {
        // Find smallest 256-byte multiple >= dataSize. Because `blockSizes`
        // uses a 256-byte stride, `blockSize - dataSize` is always in 0...255,
        // so every frame <= 2048 bytes emits at an exact bucket boundary.
        for blockSize in blockSizes {
            if dataSize <= blockSize {
                return blockSize
            }
        }
        
        // For very large messages, just use the original size
        // (will be fragmented anyway)
        return dataSize
    }
}
