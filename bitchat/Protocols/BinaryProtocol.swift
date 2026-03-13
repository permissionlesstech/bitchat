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
/// Header (Fixed 14 bytes for v1, 16 bytes for v2):
/// +--------+------+-----+-----------+-------+------------------+
/// |Version | Type | TTL | Timestamp | Flags | PayloadLength    |
/// |1 byte  |1 byte|1byte| 8 bytes   | 1 byte| 2 or 4 bytes     |
/// +--------+------+-----+-----------+-------+------------------+
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
/// - Bit 2: Is compressed (zlib compression applied)
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
import BitLogger

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
    static let v1HeaderSize = 14
    static let v2HeaderSize = 16
    static let senderIDSize = 8
    static let recipientIDSize = 8
    static let signatureSize = 64

    // Field offsets within packet header
    struct Offsets {
        static let version = 0
        static let type = 1
        static let ttl = 2
        static let timestamp = 3
        static let flags = 11  // After version(1) + type(1) + ttl(1) + timestamp(8)
    }

    static func headerSize(for version: UInt8) -> Int? {
        switch version {
        case 1: return v1HeaderSize
        case 2: return v2HeaderSize
        default: return nil
        }
    }

    private static func lengthFieldSize(for version: UInt8) -> Int {
        return version == 2 ? 4 : 2
    }
    
    struct Flags {
        static let hasRecipient: UInt8 = 0x01
        static let hasSignature: UInt8 = 0x02
        static let isCompressed: UInt8 = 0x04
        static let hasRoute: UInt8 = 0x08
        static let isRSR: UInt8 = 0x10
    }
    
    // Encode BitchatPacket to binary format
    static func encode(_ packet: BitchatPacket, padding: Bool = true) -> Data? {
        let version = packet.version
        guard version == 1 || version == 2 else { return nil }

        // Try to compress payload when beneficial, keeping original size for later decoding
        var payload = packet.payload
        var isCompressed = false
        var originalPayloadSize: Int?
        if CompressionUtil.shouldCompress(payload) {
            // Only compress when we can represent the original length in the outbound frame
            let maxRepresentable = version == 2 ? Int(UInt32.max) : Int(UInt16.max)
            if payload.count <= maxRepresentable,
               let compressedPayload = CompressionUtil.compress(payload) {
                originalPayloadSize = payload.count
                payload = compressedPayload
                isCompressed = true
            }
        }

        let lengthFieldBytes = lengthFieldSize(for: version)
        
        // Route is only supported for v2+ packets (per SOURCE_ROUTING.md spec)
        let originalRoute = (version >= 2) ? (packet.route ?? []) : []
        if originalRoute.contains(where: { $0.isEmpty }) { return nil }
        let sanitizedRoute: [Data] = originalRoute.map { hop in
            if hop.count == senderIDSize { return hop }
            if hop.count > senderIDSize { return Data(hop.prefix(senderIDSize)) }
            var padded = hop
            padded.append(Data(repeating: 0, count: senderIDSize - hop.count))
            return padded
        }
        guard sanitizedRoute.count <= 255 else { return nil }

        let hasRoute = !sanitizedRoute.isEmpty
        let routeLength = hasRoute ? 1 + sanitizedRoute.count * senderIDSize : 0
        let originalSizeFieldBytes = isCompressed ? lengthFieldBytes : 0
        // payloadLength in header is payload-only (does NOT include route bytes)
        let payloadDataSize = payload.count + originalSizeFieldBytes

        if version == 1 && payloadDataSize > Int(UInt16.max) { return nil }
        if version == 2 && payloadDataSize > Int(UInt32.max) { return nil }

        guard let headerSize = headerSize(for: version) else { return nil }
        let estimatedHeader = headerSize + senderIDSize + (packet.recipientID == nil ? 0 : recipientIDSize) + routeLength
        let estimatedPayload = payloadDataSize
        let estimatedSignature = (packet.signature == nil ? 0 : signatureSize)
        var data = Data()
        data.reserveCapacity(estimatedHeader + estimatedPayload + estimatedSignature + 255)

        data.append(version)
        data.append(packet.type)
        data.append(packet.ttl)

        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((packet.timestamp >> UInt64(shift)) & 0xFF))
        }

        var flags: UInt8 = 0
        if packet.recipientID != nil { flags |= Flags.hasRecipient }
        if packet.signature != nil { flags |= Flags.hasSignature }
        if isCompressed { flags |= Flags.isCompressed }
        // HAS_ROUTE is only valid for v2+ packets
        if hasRoute && version >= 2 { flags |= Flags.hasRoute }
        if packet.isRSR { flags |= Flags.isRSR }
        data.append(flags)
        
        if version == 2 {
            let length = UInt32(payloadDataSize)
            for shift in stride(from: 24, through: 0, by: -8) {
                data.append(UInt8((length >> UInt32(shift)) & 0xFF))
            }
        } else {
            let length = UInt16(payloadDataSize)
            data.append(UInt8((length >> 8) & 0xFF))
            data.append(UInt8(length & 0xFF))
        }

        let senderBytes = packet.senderID.prefix(senderIDSize)
        data.append(senderBytes)
        if senderBytes.count < senderIDSize {
            data.append(Data(repeating: 0, count: senderIDSize - senderBytes.count))
        }

        if let recipientID = packet.recipientID {
            let recipientBytes = recipientID.prefix(recipientIDSize)
            data.append(recipientBytes)
            if recipientBytes.count < recipientIDSize {
                data.append(Data(repeating: 0, count: recipientIDSize - recipientBytes.count))
            }
        }

        if hasRoute {
            data.append(UInt8(sanitizedRoute.count))
            for hop in sanitizedRoute {
                data.append(hop)
            }
        }

        if isCompressed, let originalSize = originalPayloadSize {
            if version == 2 {
                let value = UInt32(originalSize)
                for shift in stride(from: 24, through: 0, by: -8) {
                    data.append(UInt8((value >> UInt32(shift)) & 0xFF))
                }
            } else {
                let value = UInt16(originalSize)
                data.append(UInt8((value >> 8) & 0xFF))
                data.append(UInt8(value & 0xFF))
            }
        }
        data.append(payload)

        if let signature = packet.signature {
            data.append(signature.prefix(signatureSize))
        }

        if padding {
            let optimalSize = MessagePadding.optimalBlockSize(for: data.count)
            return MessagePadding.pad(data, toSize: optimalSize)
        }
        return data
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
        guard raw.count >= v1HeaderSize + senderIDSize else { return nil }

        return raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> BitchatPacket? in
            guard let base = buf.baseAddress else { return nil }
            var offset = 0
            func require(_ n: Int) -> Bool { offset + n <= buf.count }
            func read8() -> UInt8? {
                guard require(1) else { return nil }
                let value = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self).pointee
                offset += 1
                return value
            }
            func read16() -> UInt16? {
                guard require(2) else { return nil }
                let ptr = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                let value = (UInt16(ptr[0]) << 8) | UInt16(ptr[1])
                offset += 2
                return value
            }
            func read32() -> UInt32? {
                guard require(4) else { return nil }
                let ptr = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                let value = (UInt32(ptr[0]) << 24) | (UInt32(ptr[1]) << 16) | (UInt32(ptr[2]) << 8) | UInt32(ptr[3])
                offset += 4
                return value
            }
            func readData(_ n: Int) -> Data? {
                guard require(n) else { return nil }
                let ptr = base.advanced(by: offset)
                let data = Data(bytes: ptr, count: n)
                offset += n
                return data
            }

            guard let version = read8(), version == 1 || version == 2 else { return nil }
            let lengthFieldBytes = lengthFieldSize(for: version)
            guard let headerSize = headerSize(for: version) else { return nil }
            let minimumRequired = headerSize + senderIDSize
            guard raw.count >= minimumRequired else { return nil }

            guard let type = read8(), let ttl = read8() else { return nil }

            var timestamp: UInt64 = 0
            for _ in 0..<8 {
                guard let byte = read8() else { return nil }
                timestamp = (timestamp << 8) | UInt64(byte)
            }

            guard let flags = read8() else { return nil }
            let hasRecipient = (flags & Flags.hasRecipient) != 0
            let hasSignature = (flags & Flags.hasSignature) != 0
            let isCompressed = (flags & Flags.isCompressed) != 0
            // HAS_ROUTE is only valid for v2+ packets; ignore the flag for v1
            let hasRoute = (version >= 2) && (flags & Flags.hasRoute) != 0
            let isRSR = (flags & Flags.isRSR) != 0
            
            let payloadLength: Int
            if version == 2 {
                guard let len = read32() else { return nil }
                payloadLength = Int(len)
            } else {
                guard let len = read16() else { return nil }
                payloadLength = Int(len)
            }

            guard payloadLength >= 0 else { return nil }
            guard payloadLength <= FileTransferLimits.maxFramedFileBytes else { return nil }

            guard let senderID = readData(senderIDSize) else { return nil }

            var recipientID: Data? = nil
            if hasRecipient {
                recipientID = readData(recipientIDSize)
                if recipientID == nil { return nil }
            }

            // Route (optional, v2+ only): route bytes are NOT included in payloadLength
            var route: [Data]? = nil
            if hasRoute {
                guard let routeCount = read8() else { return nil }
                if routeCount > 0 {
                    var hops: [Data] = []
                    for _ in 0..<Int(routeCount) {
                        guard let hop = readData(senderIDSize) else { return nil }
                        hops.append(hop)
                    }
                    route = hops
                }
            }

            // Payload: payloadLength is exactly the payload size (+ compression preamble if compressed)
            let payload: Data
            if isCompressed {
                guard payloadLength >= lengthFieldBytes else { return nil }
                let originalSize: Int
                if version == 2 {
                    guard let rawSize = read32() else { return nil }
                    originalSize = Int(rawSize)
                } else {
                    guard let rawSize = read16() else { return nil }
                    originalSize = Int(rawSize)
                }
                guard originalSize >= 0 && originalSize <= FileTransferLimits.maxFramedFileBytes else { return nil }
                let compressedSize = payloadLength - lengthFieldBytes
                guard compressedSize > 0, let compressed = readData(compressedSize) else { return nil }

                let compressionRatio = Double(originalSize) / Double(compressedSize)
                guard compressionRatio <= 50_000.0 else {
                    SecureLogger.warning("🚫 Suspicious compression ratio: \(String(format: "%.0f", compressionRatio)):1", category: .security)
                    return nil
                }

                guard let decompressed = CompressionUtil.decompress(compressed, originalSize: originalSize),
                      decompressed.count == originalSize else { return nil }
                payload = decompressed
            } else {
                guard let rawPayload = readData(payloadLength) else { return nil }
                payload = rawPayload
            }

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
                timestamp: timestamp,
                payload: payload,
                signature: signature,
                ttl: ttl,
                version: version,
                route: route,
                isRSR: isRSR
            )
        }
    }
}
