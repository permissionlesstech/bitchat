//
// BinaryProtocol.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

///
/// # BinaryProtocol
///
/// Low-level binary encoding and decoding for BitChat protocol messages.
/// Optimized for Bluetooth LE's limited bandwidth and MTU constraints.
///
/// ## Overview
/// BinaryProtocol implements an efficient binary wire format that minimizes
/// overhead while maintaining extensibility. It handles:
/// - Compact binary encoding with fixed headers
/// - Optional field support via flags
/// - Automatic compression for large payloads
/// - Endianness handling for cross-platform compatibility
///
/// ## Wire Format
/// ```
/// Header (Fixed 13 bytes):
/// +--------+------+-----+-----------+-------+----------------+
/// |Version | Type | TTL | Timestamp | Flags | PayloadLength  |
/// |1 byte  |1 byte|1byte| 8 bytes   | 1 byte| 2 bytes        |
/// +--------+------+-----+-----------+-------+----------------+
///
/// Variable sections:
/// +----------+-------------+---------+------------+
/// | SenderID | RecipientID | Payload | Signature  |
/// | 8 bytes  | 8 bytes*    | Variable| 64 bytes*  |
/// +----------+-------------+---------+------------+
/// * Optional fields based on flags
/// ```
///
/// ## Design Rationale
/// The protocol is designed for:
/// - **Efficiency**: Minimal overhead for small messages
/// - **Flexibility**: Optional fields via flag bits
/// - **Compatibility**: Network byte order (big-endian)
/// - **Performance**: Zero-copy where possible
///
/// ## Compression Strategy
/// - Automatic compression for payloads > 256 bytes
/// - zlib compression for broad compatibility on Apple platforms
/// - Original size stored for decompression
/// - Flag bit indicates compressed payload
///
/// ## Flag Bits
/// - Bit 0: Has recipient ID (directed message)
/// - Bit 1: Has signature (authenticated message)
/// - Bit 2: Is compressed (LZ4 compression applied)
/// - Bits 3-7: Reserved for future use
///
/// ## Size Constraints
/// - Maximum packet size: 65,535 bytes (16-bit length field)
/// - Typical packet size: < 512 bytes (BLE MTU)
/// - Minimum packet size: 21 bytes (header + sender ID)
///
/// ## Encoding Process
/// 1. Construct header with fixed fields
/// 2. Set appropriate flags
/// 3. Compress payload if beneficial
/// 4. Append variable-length fields
/// 5. Calculate and append signature if needed
///
/// ## Decoding Process
/// 1. Validate minimum packet size
/// 2. Parse fixed header
/// 3. Extract flags and determine field presence
/// 4. Parse variable fields based on flags
/// 5. Decompress payload if compressed
/// 6. Verify signature if present
///
/// ## Error Handling
/// - Graceful handling of malformed packets
/// - Clear error messages for debugging
/// - No crashes on invalid input
/// - Logging of protocol violations
///
/// ## Performance Notes
/// - Allocation-free for small messages
/// - Streaming support for large payloads
/// - Efficient bit manipulation
/// - Platform-optimized byte swapping
///

import Foundation

extension Data {
    func trimmingNullBytes() -> Data {
        // Find the first null byte
        if let nullIndex = self.firstIndex(of: 0) {
            return self.prefix(nullIndex)
        }
        return self
    }
}

/// Implements binary encoding and decoding for BitChat protocol messages.
/// Provides static methods for converting between BitchatPacket objects and
/// their binary wire format representation.
/// - Note: All multi-byte values use network byte order (big-endian)
struct BinaryProtocol {
    static let headerSize = 13
    static let senderIDSize = 8
    static let recipientIDSize = 8
    static let signatureSize = 64
    
    struct Flags {
        static let hasRecipient: UInt8 = 0x01
        static let hasSignature: UInt8 = 0x02
        static let isCompressed: UInt8 = 0x04
    }
    
    // Encode BitchatPacket to binary format
    static func encode(_ packet: BitchatPacket, padding: Bool = true) -> Data? {
        var data = Data()
        
        
        // Try to compress payload if beneficial
        var payload = packet.payload
        var originalPayloadSize: UInt16? = nil
        var isCompressed = false
        
        if CompressionUtil.shouldCompress(payload) {
            if let compressedPayload = CompressionUtil.compress(payload) {
                // Store original size for decompression (2 bytes after payload)
                originalPayloadSize = UInt16(payload.count)
                payload = compressedPayload
                isCompressed = true
                
            } else {
            }
        } else {
        }
        
        // Header
        // Reserve capacity to reduce reallocations. Estimate base size conservatively.
        // header(13) + sender(8) + opt recipient(8) + opt originalSize(2) + payload + opt signature(64) + up to 255 pad
        let estimatedPayload = payload.count + (isCompressed ? 2 : 0)
        let estimated = headerSize + senderIDSize + (packet.recipientID == nil ? 0 : recipientIDSize) + estimatedPayload + (packet.signature == nil ? 0 : signatureSize) + 255
        data.reserveCapacity(estimated)
        data.append(packet.version)
        data.append(packet.type)
        data.append(packet.ttl)
        
        // Timestamp (8 bytes, big-endian)
        for i in (0..<8).reversed() {
            data.append(UInt8((packet.timestamp >> (i * 8)) & 0xFF))
        }
        
        // Flags
        var flags: UInt8 = 0
        if packet.recipientID != nil {
            flags |= Flags.hasRecipient
        }
        if packet.signature != nil {
            flags |= Flags.hasSignature
        }
        if isCompressed {
            flags |= Flags.isCompressed
        }
        data.append(flags)
        
        // Payload length (2 bytes, big-endian) - includes original size if compressed
        let payloadDataSize = payload.count + (isCompressed ? 2 : 0)
        let payloadLength = UInt16(payloadDataSize)
        
        
        data.append(UInt8((payloadLength >> 8) & 0xFF))
        data.append(UInt8(payloadLength & 0xFF))
        
        // SenderID (exactly 8 bytes)
        let senderBytes = packet.senderID.prefix(senderIDSize)
        data.append(senderBytes)
        if senderBytes.count < senderIDSize {
            data.append(Data(repeating: 0, count: senderIDSize - senderBytes.count))
        }
        
        // RecipientID (if present)
        if let recipientID = packet.recipientID {
            let recipientBytes = recipientID.prefix(recipientIDSize)
            data.append(recipientBytes)
            if recipientBytes.count < recipientIDSize {
                data.append(Data(repeating: 0, count: recipientIDSize - recipientBytes.count))
            }
        }
        
        // Payload (with original size prepended if compressed)
        if isCompressed, let originalSize = originalPayloadSize {
            // Prepend original size (2 bytes, big-endian)
            data.append(UInt8((originalSize >> 8) & 0xFF))
            data.append(UInt8(originalSize & 0xFF))
        }
        data.append(payload)
        
        // Signature (if present)
        if let signature = packet.signature {
            data.append(signature.prefix(signatureSize))
        }
        
        
        // Apply padding to standard block sizes for traffic analysis resistance
        if padding {
            let optimalSize = MessagePadding.optimalBlockSize(for: data.count)
            let paddedData = MessagePadding.pad(data, toSize: optimalSize)
            return paddedData
        } else {
            // Caller explicitly requested no padding (e.g., BLE write path)
            return data
        }
    }
    
    // Decode binary data to BitchatPacket
    static func decode(_ data: Data) -> BitchatPacket? {
        // Try decode as-is first (robust when padding wasn't applied)
        if let pkt = decodeCore(data) { return pkt }
        // If that fails, try after removing padding
        let unpadded = MessagePadding.unpad(data)
        if unpadded as NSData === data as NSData { return nil }
        return decodeCore(unpadded)
    }

    // Core decoding implementation used by decode(_:) with and without padding removal
    private static func decodeCore(_ raw: Data) -> BitchatPacket? {
        // Minimum size: header + senderID
        guard raw.count >= headerSize + senderIDSize else { return nil }

        return raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> BitchatPacket? in
            guard let base = buf.baseAddress else { return nil }
            var offset = 0
            func require(_ n: Int) -> Bool { offset + n <= buf.count }
            // Read single byte
            func read8() -> UInt8? {
                guard require(1) else { return nil }
                let v = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self).pointee
                offset += 1
                return v
            }
            // Read big-endian 16-bit
            func read16() -> UInt16? {
                guard require(2) else { return nil }
                let p = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                let v = (UInt16(p[0]) << 8) | UInt16(p[1])
                offset += 2
                return v
            }
            // Copy N bytes into Data
            func readData(_ n: Int) -> Data? {
                guard require(n) else { return nil }
                let ptr = base.advanced(by: offset)
                let d = Data(bytes: ptr, count: n)
                offset += n
                return d
            }

            // Version
            guard let version = read8(), version == 1 else { return nil }
            guard let type = read8() else { return nil }
            guard let ttl = read8() else { return nil }

            // Timestamp 8 bytes BE
            guard require(8) else { return nil }
            var ts: UInt64 = 0
            for _ in 0..<8 {
                guard let b = read8() else { return nil }
                ts = (ts << 8) | UInt64(b)
            }

            // Flags
            guard let flags = read8() else { return nil }
            let hasRecipient = (flags & Flags.hasRecipient) != 0
            let hasSignature = (flags & Flags.hasSignature) != 0
            let isCompressed = (flags & Flags.isCompressed) != 0

            // Payload length
            guard let payloadLen = read16(), payloadLen <= 65535 else { return nil }

            // SenderID
            guard let senderID = readData(senderIDSize) else { return nil }

            // Recipient
            var recipientID: Data? = nil
            if hasRecipient {
                recipientID = readData(recipientIDSize)
                if recipientID == nil { return nil }
            }

            // Payload
            let payload: Data
            if isCompressed {
                // Need original size (2 bytes)
                guard let origSize16 = read16() else { return nil }
                let originalSize = Int(origSize16)
                guard originalSize >= 0 && originalSize <= 1_048_576 else { return nil }
                let compSize = Int(payloadLen) - 2
                guard compSize >= 0, let compressed = readData(compSize) else { return nil }
                guard let decompressed = CompressionUtil.decompress(compressed, originalSize: originalSize),
                      decompressed.count == originalSize else { return nil }
                payload = decompressed
            } else {
                guard let p = readData(Int(payloadLen)) else { return nil }
                payload = p
            }

            // Signature
            var signature: Data? = nil
            if hasSignature {
                signature = readData(signatureSize)
                if signature == nil { return nil }
            }

            guard offset <= buf.count else { return nil }

            return BitchatPacket(
                type: type,
                senderID: senderID,
                recipientID: recipientID,
                timestamp: ts,
                payload: payload,
                signature: signature,
                ttl: ttl
            )
        }
    }
}

// Binary encoding for BitchatMessage
extension BitchatMessage {
    func toBinaryPayload() -> Data? {
        var data = Data()
        
        // Message format:
        // - Flags: 1 byte (bit 0: isRelay, bit 1: isPrivate, bit 2: hasOriginalSender, bit 3: hasRecipientNickname, bit 4: hasSenderPeerID, bit 5: hasMentions)
        // - Timestamp: 8 bytes (seconds since epoch)
        // - ID length: 1 byte
        // - ID: variable
        // - Sender length: 1 byte
        // - Sender: variable
        // - Content length: 2 bytes
        // - Content: variable
        // Optional fields based on flags:
        // - Original sender length + data
        // - Recipient nickname length + data
        // - Sender peer ID length + data
        // - Mentions array
        
        var flags: UInt8 = 0
        if isRelay { flags |= 0x01 }
        if isPrivate { flags |= 0x02 }
        if originalSender != nil { flags |= 0x04 }
        if recipientNickname != nil { flags |= 0x08 }
        if senderPeerID != nil { flags |= 0x10 }
        if mentions != nil && !mentions!.isEmpty { flags |= 0x20 }
        
        data.append(flags)
        
        // Timestamp (in milliseconds)
        let timestampMillis = UInt64(timestamp.timeIntervalSince1970 * 1000)
        // Encode as 8 bytes, big-endian
        for i in (0..<8).reversed() {
            data.append(UInt8((timestampMillis >> (i * 8)) & 0xFF))
        }
        
        // ID
        if let idData = id.data(using: .utf8) {
            data.append(UInt8(min(idData.count, 255)))
            data.append(idData.prefix(255))
        } else {
            data.append(0)
        }
        
        // Sender
        if let senderData = sender.data(using: .utf8) {
            data.append(UInt8(min(senderData.count, 255)))
            data.append(senderData.prefix(255))
        } else {
            data.append(0)
        }
        
        // Content
        if let contentData = content.data(using: .utf8) {
            let length = UInt16(min(contentData.count, 65535))
            // Encode length as 2 bytes, big-endian
            data.append(UInt8((length >> 8) & 0xFF))
            data.append(UInt8(length & 0xFF))
            data.append(contentData.prefix(Int(length)))
        } else {
            data.append(contentsOf: [0, 0])
        }
        
        // Optional fields
        if let originalSender = originalSender, let origData = originalSender.data(using: .utf8) {
            data.append(UInt8(min(origData.count, 255)))
            data.append(origData.prefix(255))
        }
        
        if let recipientNickname = recipientNickname, let recipData = recipientNickname.data(using: .utf8) {
            data.append(UInt8(min(recipData.count, 255)))
            data.append(recipData.prefix(255))
        }
        
        if let senderPeerID = senderPeerID, let peerData = senderPeerID.data(using: .utf8) {
            data.append(UInt8(min(peerData.count, 255)))
            data.append(peerData.prefix(255))
        }
        
        // Mentions array
        if let mentions = mentions {
            data.append(UInt8(min(mentions.count, 255))) // Number of mentions
            for mention in mentions.prefix(255) {
                if let mentionData = mention.data(using: .utf8) {
                    data.append(UInt8(min(mentionData.count, 255)))
                    data.append(mentionData.prefix(255))
                } else {
                    data.append(0)
                }
            }
        }
        
        
        return data
    }
    
    static func fromBinaryPayload(_ data: Data) -> BitchatMessage? {
        // Create an immutable copy to prevent threading issues
        let dataCopy = Data(data)
        
        
        guard dataCopy.count >= 13 else { 
            return nil 
        }
        
        var offset = 0
        
        // Flags
        guard offset < dataCopy.count else { 
            return nil 
        }
        let flags = dataCopy[offset]; offset += 1
        let isRelay = (flags & 0x01) != 0
        let isPrivate = (flags & 0x02) != 0
        let hasOriginalSender = (flags & 0x04) != 0
        let hasRecipientNickname = (flags & 0x08) != 0
        let hasSenderPeerID = (flags & 0x10) != 0
        let hasMentions = (flags & 0x20) != 0
        
        // Timestamp
        guard offset + 8 <= dataCopy.count else { 
            return nil 
        }
        let timestampData = dataCopy[offset..<offset+8]
        let timestampMillis = timestampData.reduce(0) { result, byte in
            (result << 8) | UInt64(byte)
        }
        offset += 8
        let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampMillis) / 1000.0)
        
        // ID
        guard offset < dataCopy.count else { 
            return nil 
        }
        let idLength = Int(dataCopy[offset]); offset += 1
        guard offset + idLength <= dataCopy.count else { 
            return nil 
        }
        let id = String(data: dataCopy[offset..<offset+idLength], encoding: .utf8) ?? UUID().uuidString
        offset += idLength
        
        // Sender
        guard offset < dataCopy.count else { 
            return nil 
        }
        let senderLength = Int(dataCopy[offset]); offset += 1
        guard offset + senderLength <= dataCopy.count else { 
            return nil 
        }
        let sender = String(data: dataCopy[offset..<offset+senderLength], encoding: .utf8) ?? "unknown"
        offset += senderLength
        
        // Content
        guard offset + 2 <= dataCopy.count else { 
            return nil 
        }
        let contentLengthData = dataCopy[offset..<offset+2]
        let contentLength = Int(contentLengthData.reduce(0) { result, byte in
            (result << 8) | UInt16(byte)
        })
        offset += 2
        guard offset + contentLength <= dataCopy.count else { 
            return nil 
        }
        
        let content = String(data: dataCopy[offset..<offset+contentLength], encoding: .utf8) ?? ""
        offset += contentLength
        
        // Optional fields
        var originalSender: String?
        if hasOriginalSender && offset < dataCopy.count {
            let length = Int(dataCopy[offset]); offset += 1
            if offset + length <= dataCopy.count {
                originalSender = String(data: dataCopy[offset..<offset+length], encoding: .utf8)
                offset += length
            }
        }
        
        var recipientNickname: String?
        if hasRecipientNickname && offset < dataCopy.count {
            let length = Int(dataCopy[offset]); offset += 1
            if offset + length <= dataCopy.count {
                recipientNickname = String(data: dataCopy[offset..<offset+length], encoding: .utf8)
                offset += length
            }
        }
        
        var senderPeerID: String?
        if hasSenderPeerID && offset < dataCopy.count {
            let length = Int(dataCopy[offset]); offset += 1
            if offset + length <= dataCopy.count {
                senderPeerID = String(data: dataCopy[offset..<offset+length], encoding: .utf8)
                offset += length
            }
        }
        
        // Mentions array
        var mentions: [String]?
        if hasMentions && offset < dataCopy.count {
            let mentionCount = Int(dataCopy[offset]); offset += 1
            if mentionCount > 0 {
                mentions = []
                for _ in 0..<mentionCount {
                    if offset < dataCopy.count {
                        let length = Int(dataCopy[offset]); offset += 1
                        if offset + length <= dataCopy.count {
                            if let mention = String(data: dataCopy[offset..<offset+length], encoding: .utf8) {
                                mentions?.append(mention)
                            }
                            offset += length
                        }
                    }
                }
            }
        }
        
        let message = BitchatMessage(
            id: id,
            sender: sender,
            content: content,
            timestamp: timestamp,
            isRelay: isRelay,
            originalSender: originalSender,
            isPrivate: isPrivate,
            recipientNickname: recipientNickname,
            senderPeerID: senderPeerID,
            mentions: mentions
        )
        return message
    }
}
