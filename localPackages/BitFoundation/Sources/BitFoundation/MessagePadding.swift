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
        // PKCS#7: All pad bytes are equal to the pad length
        padded.append(contentsOf: Array(repeating: UInt8(paddingNeeded), count: paddingNeeded))
        return padded
    }
    
    // Remove padding from data
    static func unpad(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        let last = data.last!
        let paddingLength = Int(last)
        // Must have at least 1 pad byte and not exceed data length
        guard paddingLength > 0 && paddingLength <= data.count else { return data }
        // Verify PKCS#7: all last N bytes equal to pad length
        let start = data.count - paddingLength
        let tail = data[start...]
        for b in tail { if b != last { return data } }
        return Data(data[..<start])
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
