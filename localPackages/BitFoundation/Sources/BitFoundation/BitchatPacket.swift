//
// BitchatPacket.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import struct Foundation.Data

// Within retained wire metadata, a nil compressed body represents an uncompressed payload.
struct PacketWirePayload: Codable {
    let compressedBytes: Data?
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
    // Retained by wire decoding or restored from Codable metadata.
    // Changes to TTL, route, and RSR do not change the immutable payload.
    var wirePayload: PacketWirePayload?

    /// Payload buffers retained by this packet, excluding headers and signatures.
    public var retainedPayloadBytes: Int {
        payload.count + (wirePayload?.compressedBytes?.count ?? 0)
    }

    private enum CodingKeys: String, CodingKey {
        case version, type, senderID, recipientID, timestamp, payload, signature, ttl, route, isRSR, wirePayload
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try values.decode(UInt8.self, forKey: .type),
            senderID: try values.decode(Data.self, forKey: .senderID),
            recipientID: try values.decodeIfPresent(Data.self, forKey: .recipientID),
            timestamp: try values.decode(UInt64.self, forKey: .timestamp),
            payload: try values.decode(Data.self, forKey: .payload),
            signature: try values.decodeIfPresent(Data.self, forKey: .signature),
            ttl: try values.decode(UInt8.self, forKey: .ttl),
            version: try values.decode(UInt8.self, forKey: .version),
            route: try values.decodeIfPresent([Data].self, forKey: .route),
            isRSR: try values.decode(Bool.self, forKey: .isRSR)
        )
        let stored = try values.decodeIfPresent(PacketWirePayload.self, forKey: .wirePayload)
        if let compressed = stored?.compressedBytes {
            // Check that retained compressed bytes expand to the decoded payload,
            // subject to the payload-size and inflation-ratio limits below.
            guard !compressed.isEmpty,
                  compressed.count <= FileTransferLimits.maxFramedFileBytes,
                  payload.count <= PacketPayloadLimits.maxPayloadBytes(forType: type),
                  payload.count <= compressed.count * PacketPayloadLimits.maxDeflateRatio,
                  CompressionUtil.decompress(compressed, originalSize: payload.count) == payload else {
                throw DecodingError.dataCorruptedError(
                    forKey: .wirePayload, in: values,
                    debugDescription: "Stored wire payload does not match decoded payload"
                )
            }
        }
        wirePayload = stored
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
    
    /// Encode signing bytes with the signature omitted and TTL and RSR set to zero.
    public func toBinaryDataForSigning() -> Data? {
        // Keep the retained payload encoding in the unsigned copy.
        var unsignedPacket = self
        unsignedPacket.signature = nil
        unsignedPacket.ttl = 0
        unsignedPacket.isRSR = false
        return BinaryProtocol.encode(unsignedPacket)
    }
    
    public static func from(_ data: Data) -> BitchatPacket? {
        BinaryProtocol.decode(data)
    }
}
