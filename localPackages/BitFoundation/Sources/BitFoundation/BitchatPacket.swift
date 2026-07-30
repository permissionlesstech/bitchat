//
// BitchatPacket.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import struct Foundation.Data

/// Payload as it arrived on the wire, set by `BinaryProtocol.decode`.
///
/// Signatures cover a re-encoding of the packet, and verification re-encodes too.
/// DEFLATE output is not canonical and clients use different encoders (Apple's
/// `compression_encode_buffer` here, `java.util.zip.Deflater` on Android), so
/// re-compressing can change the preimage and reject a valid packet. Reusing these
/// bytes also stops a relay, which re-encodes on TTL decrement, from substituting
/// its own encoding.
///
/// `forPayload` ties the bytes to the payload they decode to: replace the payload
/// and the encoder compresses instead.
public struct WirePayload {
    public let bytes: Data
    public let compressed: Bool
    public let forPayload: Data

    public init(bytes: Data, compressed: Bool, forPayload: Data) {
        self.bytes = bytes
        self.compressed = compressed
        self.forPayload = forPayload
    }
}

/// The core packet structure for all BitChat protocol messages.
/// Encapsulates all data needed for routing through the mesh network,
/// including TTL for hop limiting and optional encryption.
/// - Note: Packets larger than BLE MTU (512 bytes) are automatically fragmented
public struct BitchatPacket: Codable {
    public let version: UInt8
    public let type: UInt8
    public let senderID: Data
    public let recipientID: Data?
    public let timestamp: UInt64
    public let payload: Data
    public var signature: Data?
    public var ttl: UInt8
    public var route: [Data]?
    public var isRSR: Bool
    /// Set by `BinaryProtocol.decode`. Not part of the encoded form, so it is left
    /// out of `CodingKeys`; the default lets the synthesized `Decodable` init skip
    /// it. Losing it only costs a re-compression.
    public var wirePayload: WirePayload? = nil

    /// Explicit so `wirePayload` stays out of the encoded form.
    private enum CodingKeys: String, CodingKey {
        case version, type, senderID, recipientID, timestamp, payload, signature, ttl, route, isRSR
    }

    public init(type: UInt8, senderID: Data, recipientID: Data?, timestamp: UInt64, payload: Data, signature: Data?, ttl: UInt8, version: UInt8 = 1, route: [Data]? = nil, isRSR: Bool = false, wirePayload: WirePayload? = nil) {
        self.version = version
        self.type = type
        self.senderID = senderID
        self.recipientID = recipientID
        self.timestamp = timestamp
        self.payload = payload
        self.signature = signature
        self.ttl = ttl
        self.route = route
        self.isRSR = isRSR
        self.wirePayload = wirePayload
    }

    public func toBinaryData(padding: Bool = true) -> Data? {
        BinaryProtocol.encode(self, padding: padding)
    }

    // Backward-compatible helper (defaults to padded encoding)
    public func toBinaryData() -> Data? {
        toBinaryData(padding: true)
    }
    
    /// Create binary representation for signing (without signature and TTL fields)
    /// TTL is excluded because it changes during packet relay operations
    public func toBinaryDataForSigning() -> Data? {
        // Create a copy without signature and with fixed TTL for signing
        // TTL must be excluded because it changes during relay
        let unsignedPacket = BitchatPacket(
            type: type,
            senderID: senderID,
            recipientID: recipientID,
            timestamp: timestamp,
            payload: payload,
            signature: nil, // Remove signature for signing
            ttl: 0, // Use fixed TTL=0 for signing to ensure relay compatibility
            version: version,
            route: route,
            isRSR: false, // RSR flag is mutable and not part of the signature
            wirePayload: wirePayload // preimage must use the originator's bytes
        )
        return BinaryProtocol.encode(unsignedPacket)
    }
    
    public static func from(_ data: Data) -> BitchatPacket? {
        BinaryProtocol.decode(data)
    }
}
