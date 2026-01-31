//
// BitchatPacket.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// The core packet structure for all BitChat protocol messages.
/// Encapsulates all data needed for routing through the mesh network,
/// including TTL for hop limiting and optional encryption.
/// - Note: Packets larger than BLE MTU (512 bytes) are automatically fragmented
struct BitchatPacket: Codable {
    let version: UInt8
    let type: UInt8
    let senderID: Data
    let recipientID: Data?
    let timestamp: UInt64
    let payload: Data
    var signature: Data?
    var ttl: UInt8
    var route: [Data]?
    var isRSR: Bool
    
    init(type: UInt8, senderID: Data, recipientID: Data?, timestamp: UInt64, payload: Data, signature: Data?, ttl: UInt8, version: UInt8 = 1, route: [Data]? = nil, isRSR: Bool = false) {
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
    
    // Convenience initializer for new binary format
    init(type: UInt8, ttl: UInt8, senderID: PeerID, payload: Data, isRSR: Bool = false) {
        self.version = 1
        self.type = type
        // Convert hex string peer ID to binary data (8 bytes)
        var senderData = Data()
        var tempID = senderID.id
        while tempID.count >= 2 {
            let hexByte = String(tempID.prefix(2))
            if let byte = UInt8(hexByte, radix: 16) {
                senderData.append(byte)
            }
            tempID = String(tempID.dropFirst(2))
        }
        self.senderID = senderData
        self.recipientID = nil
        self.timestamp = UInt64(Date().timeIntervalSince1970 * 1000) // milliseconds
        self.payload = payload
        self.signature = nil
        self.ttl = ttl
        self.route = nil
        self.isRSR = isRSR
    }
    
    var data: Data? {
        BinaryProtocol.encode(self)
    }
    
    func toBinaryData(padding: Bool = true) -> Data? {
        BinaryProtocol.encode(self, padding: padding)
    }

    // Backward-compatible helper (defaults to padded encoding)
    func toBinaryData() -> Data? {
        toBinaryData(padding: true)
    }
    
    /// Create binary representation for signing (without signature and TTL fields)
    /// TTL is excluded because it changes during packet relay operations
    func toBinaryDataForSigning() -> Data? {
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
            isRSR: false // RSR flag is mutable and not part of the signature
        )
        return BinaryProtocol.encode(unsignedPacket)
    }
    
    static func from(_ data: Data) -> BitchatPacket? {
        BinaryProtocol.decode(data)
    }
}
