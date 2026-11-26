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
/// PKCS#7-style: every pad byte equals the pad length, which is what `unpad`
/// verifies. The bytes are not random.
///
/// Two limits are worth knowing before relying on this for traffic analysis
/// resistance. Only Noise frames are padded at all (see the outbound packet
/// policy); everything else travels at its natural length. And because the pad
/// length has to fit in one byte, `pad` declines any request needing more than
/// 255 bytes — so a frame far below its target bucket is emitted unpadded
/// rather than padded to a smaller bucket.
struct MessagePadding {
    // Standard block sizes for padding
    static let blockSizes = [256, 512, 1024, 2048]
    
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
        // Account for encryption overhead (~16 bytes for AES-GCM tag)
        let totalSize = dataSize + 16
        
        // Find smallest block that fits
        for blockSize in blockSizes {
            if totalSize <= blockSize {
                return blockSize
            }
        }
        
        // For very large messages, just use the original size
        // (will be fragmented anyway)
        return dataSize
    }
}
