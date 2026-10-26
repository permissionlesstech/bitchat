//
// BitchatPacket.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import struct Foundation.Data

/// The payload bytes exactly as they arrived on the wire, kept beside the
/// decoded payload so a re-encode (relay TTL decrement, signature
/// verification) reproduces the originator's bytes instead of running our own
/// DEFLATE encoder over the payload.
///
/// DEFLATE output is encoder-specific: Apple's `Compression` framework,
/// `java.util.zip` (bitchat-android) and Rust miniz (Sonar) all emit different
/// streams for the same input, and a sender may also have chosen NOT to
/// compress a payload we would compress. Either way, rebuilding the signature
/// preimage with our encoder rejects every valid signed packet whose payload is
/// compressible (>= `Constants.compressionThresholdBytes`). Mirrors
/// bitchat-android #863 ("preserve wire payload").
///
/// `payloadSHA256` ties the bytes to the payload they decode to: change the
/// payload and the encoder compresses afresh.
public struct WirePayload: Equatable, Sendable {
    /// Compressed stream when `compressed`, else the raw payload.
    public let bytes: Data
    /// Whether `bytes` is a DEFLATE stream.
    public let compressed: Bool
    /// SHA-256 of the decoded payload these bytes belong to.
    public let payloadSHA256: Data

    public init(bytes: Data, compressed: Bool, forPayload payload: Data) {
        self.bytes = bytes
        self.compressed = compressed
        self.payloadSHA256 = payload.sha256Hash()
    }

    /// Do these wire bytes still describe `payload`?
    public func matches(_ payload: Data) -> Bool {
        payloadSHA256 == payload.sha256Hash()
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
    /// Payload bytes as received; `nil` for a locally built packet. Not part of
    /// the coded form: two packets with the same fields are the same packet
    /// whether or not one remembers its wire bytes.
    public var wirePayload: WirePayload? = nil

    /// What a store holding this packet keeps alive: the decoded payload, or
    /// the received wire bytes when those are larger. A valid DEFLATE stream
    /// may be far larger than what it inflates to (stored blocks, or many empty
    /// blocks before a one-byte final block), so a byte budget charged by
    /// `payload.count` alone would let a few-byte message pin a frame-sized
    /// stream. For every frame a reference encoder emits, compressed bytes are
    /// smaller than the payload and this equals `payload.count`.
    public var retainedPayloadBytes: Int {
        max(payload.count, wirePayload?.bytes.count ?? 0)
    }

    private enum CodingKeys: String, CodingKey {
        case version, type, senderID, recipientID, timestamp, payload, signature, ttl, route, isRSR
    }

    public init(type: UInt8, senderID: Data, recipientID: Data?, timestamp: UInt64, payload: Data, signature: Data?, ttl: UInt8, version: UInt8 = 1, route: [Data]? = nil, isRSR: Bool = false) {
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
        var unsignedPacket = BitchatPacket(
            type: type,
            senderID: senderID,
            recipientID: recipientID,
            timestamp: timestamp,
            payload: payload,
            signature: nil, // Remove signature for signing
            ttl: 0, // Use fixed TTL=0 for signing to ensure relay compatibility
            version: version,
            route: route,
            isRSR: false // RSR flag is mutable and not part of the signature
        )
        // A verifier must rebuild the preimage from the bytes the ORIGINATOR
        // put on the wire, never from a re-compression of the payload (see
        // `WirePayload`). For a locally built packet this is nil and the
        // encoder decides compression exactly as before.
        unsignedPacket.wirePayload = wirePayload
        return BinaryProtocol.encode(unsignedPacket)
    }
    
    public static func from(_ data: Data) -> BitchatPacket? {
        BinaryProtocol.decode(data)
    }
}
