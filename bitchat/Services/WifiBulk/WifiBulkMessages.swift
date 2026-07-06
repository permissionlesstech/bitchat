//
// WifiBulkMessages.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// TLV payloads for negotiating a Wi-Fi bulk transfer inside an established
/// Noise session (`NoisePayloadType.bulkTransferOffer` / `.bulkTransferResponse`).
///
/// Both messages ride the encrypted Noise channel, so every field — including
/// the session tokens and the random Bonjour instance name — is only visible
/// to the two endpoints. TLV format matches `BitchatFilePacket`: 1-byte type,
/// 2-byte big-endian length, value. Unknown TLVs are skipped for forward
/// compatibility.
enum WifiBulkWire {
    static let transferIDLength = 16
    static let tokenLength = 32
    static let hashLength = 32
    /// Bonjour instance names are capped at 63 UTF-8 bytes.
    static let maxServiceNameBytes = 63

    static func appendTLV(_ type: UInt8, value: Data, into data: inout Data) {
        data.append(type)
        var length = UInt16(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }

    /// Iterates well-formed TLVs, handing each (type, value) to `visit`.
    /// Returns false when the buffer is structurally malformed.
    static func parseTLVs(_ data: Data, visit: (UInt8, Data) -> Void) -> Bool {
        var cursor = data.startIndex
        let end = data.endIndex
        while cursor < end {
            let type = data[cursor]
            cursor = data.index(after: cursor)
            guard data.distance(from: cursor, to: end) >= 2 else { return false }
            let length = Int(data[cursor]) << 8 | Int(data[data.index(after: cursor)])
            cursor = data.index(cursor, offsetBy: 2)
            guard data.distance(from: cursor, to: end) >= length else { return false }
            let valueEnd = data.index(cursor, offsetBy: length)
            visit(type, Data(data[cursor..<valueEnd]))
            cursor = valueEnd
        }
        return true
    }
}

/// Sender → receiver: proposal to move an already-encoded file payload over
/// a peer-to-peer Wi-Fi (AWDL) TCP channel instead of BLE fragmentation.
struct WifiBulkOffer: Equatable {
    /// Random per-transfer identifier; also the HKDF salt.
    let transferID: Data
    /// Exact byte count of the payload that will cross the channel.
    let fileSize: UInt64
    /// SHA-256 over the payload bytes as they cross the channel, verified by
    /// the receiver after reassembly.
    let payloadHash: Data
    /// Sender's random half of the channel secret.
    let token: Data
    /// Random Bonjour instance name the sender publishes for this transfer.
    /// Never derived from nickname or peer ID.
    let serviceName: String

    private enum TLVType: UInt8 {
        case transferID = 0x01
        case fileSize = 0x02
        case payloadHash = 0x03
        case token = 0x04
        case serviceName = 0x05
    }

    func encode() -> Data? {
        guard transferID.count == WifiBulkWire.transferIDLength,
              payloadHash.count == WifiBulkWire.hashLength,
              token.count == WifiBulkWire.tokenLength else { return nil }
        let nameData = Data(serviceName.utf8)
        guard !nameData.isEmpty, nameData.count <= WifiBulkWire.maxServiceNameBytes else { return nil }

        var encoded = Data()
        WifiBulkWire.appendTLV(TLVType.transferID.rawValue, value: transferID, into: &encoded)
        var sizeBE = fileSize.bigEndian
        WifiBulkWire.appendTLV(TLVType.fileSize.rawValue, value: withUnsafeBytes(of: &sizeBE) { Data($0) }, into: &encoded)
        WifiBulkWire.appendTLV(TLVType.payloadHash.rawValue, value: payloadHash, into: &encoded)
        WifiBulkWire.appendTLV(TLVType.token.rawValue, value: token, into: &encoded)
        WifiBulkWire.appendTLV(TLVType.serviceName.rawValue, value: nameData, into: &encoded)
        return encoded
    }

    static func decode(_ data: Data) -> WifiBulkOffer? {
        var transferID: Data?
        var fileSize: UInt64?
        var payloadHash: Data?
        var token: Data?
        var serviceName: String?

        let wellFormed = WifiBulkWire.parseTLVs(data) { type, value in
            switch TLVType(rawValue: type) {
            case .transferID where value.count == WifiBulkWire.transferIDLength:
                transferID = value
            case .fileSize where value.count == 8:
                fileSize = value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            case .payloadHash where value.count == WifiBulkWire.hashLength:
                payloadHash = value
            case .token where value.count == WifiBulkWire.tokenLength:
                token = value
            case .serviceName where !value.isEmpty && value.count <= WifiBulkWire.maxServiceNameBytes:
                serviceName = String(data: value, encoding: .utf8)
            default:
                break // Unknown or malformed field: ignore; required checks below.
            }
        }
        guard wellFormed,
              let transferID, let fileSize, let payloadHash, let token, let serviceName else {
            return nil
        }
        return WifiBulkOffer(
            transferID: transferID,
            fileSize: fileSize,
            payloadHash: payloadHash,
            token: token,
            serviceName: serviceName
        )
    }
}

/// Receiver → sender: accept (with the receiver's token half) or decline.
struct WifiBulkResponse: Equatable {
    let transferID: Data
    let accepted: Bool
    /// Receiver's random half of the channel secret; present iff accepted.
    let token: Data?

    private enum TLVType: UInt8 {
        case transferID = 0x01
        case accepted = 0x02
        case token = 0x03
    }

    static func accept(transferID: Data, token: Data) -> WifiBulkResponse {
        WifiBulkResponse(transferID: transferID, accepted: true, token: token)
    }

    static func decline(transferID: Data) -> WifiBulkResponse {
        WifiBulkResponse(transferID: transferID, accepted: false, token: nil)
    }

    func encode() -> Data? {
        guard transferID.count == WifiBulkWire.transferIDLength else { return nil }
        if accepted {
            guard token?.count == WifiBulkWire.tokenLength else { return nil }
        }

        var encoded = Data()
        WifiBulkWire.appendTLV(TLVType.transferID.rawValue, value: transferID, into: &encoded)
        WifiBulkWire.appendTLV(TLVType.accepted.rawValue, value: Data([accepted ? 1 : 0]), into: &encoded)
        if accepted, let token {
            WifiBulkWire.appendTLV(TLVType.token.rawValue, value: token, into: &encoded)
        }
        return encoded
    }

    static func decode(_ data: Data) -> WifiBulkResponse? {
        var transferID: Data?
        var accepted: Bool?
        var token: Data?

        let wellFormed = WifiBulkWire.parseTLVs(data) { type, value in
            switch TLVType(rawValue: type) {
            case .transferID where value.count == WifiBulkWire.transferIDLength:
                transferID = value
            case .accepted where value.count == 1:
                accepted = value.first == 1
            case .token where value.count == WifiBulkWire.tokenLength:
                token = value
            default:
                break
            }
        }
        guard wellFormed, let transferID, let accepted else { return nil }
        if accepted {
            guard let token else { return nil }
            return WifiBulkResponse(transferID: transferID, accepted: true, token: token)
        }
        return WifiBulkResponse(transferID: transferID, accepted: false, token: nil)
    }
}
