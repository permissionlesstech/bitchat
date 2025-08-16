//
// LegacyTestProtocolTypes.swift
// bitchatTests
//
// Minimal legacy protocol types used only by tests to simulate old flows.
// These are not part of production code anymore.

import Foundation

struct ProtocolNack {
    let originalPacketID: String
    let nackID: String
    let senderID: String
    let receiverID: String
    let packetType: UInt8
    let reason: String
    let errorCode: UInt8
    
    enum ErrorCode: UInt8 {
        case unknown = 0
        case decryptionFailed = 2
    }
    
    init(originalPacketID: String, senderID: String, receiverID: String, packetType: UInt8, reason: String, errorCode: ErrorCode = .unknown) {
        self.originalPacketID = originalPacketID
        self.nackID = UUID().uuidString
        self.senderID = senderID
        self.receiverID = receiverID
        self.packetType = packetType
        self.reason = reason
        self.errorCode = errorCode.rawValue
    }
    
    func toBinaryData() -> Data {
        // Tests don't parse the payload; return a compact encoding for completeness
        var data = Data()
        data.appendUUID(originalPacketID)
        data.appendUUID(nackID)
        data.append(UInt8(packetType))
        data.append(UInt8(errorCode))
        data.appendString(reason)
        return data
    }
}

