//
// BitchatFilePacket.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import BitFoundation
import BitLogger

/// TLV payload for Bluetooth mesh file transfers (voice notes, images, generic files).
/// Mirrors the Android client specification to ensure cross-platform interoperability.
struct BitchatFilePacket {
    var fileName: String?
    var fileSize: UInt64?
    var mimeType: String?
    var content: Data

    /// Canonical TLV tags defined by the Android implementation.
    private enum TLVType: UInt8 {
        case fileName = 0x01
        case fileSize = 0x02
        case mimeType = 0x03
        case content = 0x04
    }

    /// Encodes the packet using v2 canonical TLVs (4-byte FILE_SIZE, 4-byte CONTENT length).
    /// Returns `nil` when fields exceed protocol limits (e.g., content > UInt32.max).
    func encode() -> Data? {
        let resolvedSize = fileSize ?? UInt64(content.count)
        guard resolvedSize <= UInt64(UInt32.max) else { return nil }
        guard resolvedSize <= UInt64(FileTransferLimits.maxPayloadBytes) else { return nil }
        guard content.count <= Int(UInt32.max) else { return nil }
        guard FileTransferLimits.isValidPayload(content.count) else { return nil }

        func appendBE<T: FixedWidthInteger>(_ value: T, into data: inout Data) {
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
        }

        var encoded = Data()

        if let name = fileName, let nameData = name.data(using: .utf8), nameData.count <= Int(UInt16.max) {
            encoded.append(TLVType.fileName.rawValue)
            appendBE(UInt16(nameData.count), into: &encoded)
            encoded.append(nameData)
        }

        encoded.append(TLVType.fileSize.rawValue)
        appendBE(UInt16(4), into: &encoded)
        appendBE(UInt32(resolvedSize), into: &encoded)

        if let mime = mimeType, let mimeData = mime.data(using: .utf8), mimeData.count <= Int(UInt16.max) {
            encoded.append(TLVType.mimeType.rawValue)
            appendBE(UInt16(mimeData.count), into: &encoded)
            encoded.append(mimeData)
        }

        encoded.append(TLVType.content.rawValue)
        appendBE(UInt32(content.count), into: &encoded)
        encoded.append(content)

        return encoded
    }

    /// Decodes TLV payloads, tolerating legacy encodings (FILE_SIZE len=8, CONTENT len=2) when possible.
    static func decode(_ data: Data) -> BitchatFilePacket? {
        var cursor = data.startIndex
        let end = data.endIndex

        var fileName: String?
        var fileSize: UInt64?
        var mimeType: String?
        var content = Data()

        while cursor < end {
            let typeRaw = data[cursor]
            cursor = data.index(after: cursor)

            guard cursor <= end else { return nil }
            let tlvType = TLVType(rawValue: typeRaw)

            func readBigEndianLength(bytes: Int) -> Int? {
                guard data.distance(from: cursor, to: end) >= bytes else { return nil }
                // Use UInt64 to prevent integer overflow during shift operations
                var result: UInt64 = 0
                for _ in 0..<bytes {
                    result = (result << 8) | UInt64(data[cursor])
                    cursor = data.index(after: cursor)
                }
                // Safely convert to Int with overflow check
                guard result <= Int.max else { return nil }
                return Int(result)
            }

            let length: Int?
            if tlvType == .content {
                let snapshot = cursor
                let canonical = readBigEndianLength(bytes: 4)
                if let canonical = canonical,
                   canonical <= data.distance(from: cursor, to: end) {
                    length = canonical
                } else {
                    cursor = snapshot
                    length = readBigEndianLength(bytes: 2)
                }
            } else {
                length = readBigEndianLength(bytes: 2)
            }

            guard let tlvLength = length, tlvLength >= 0 else { return nil }
            guard data.distance(from: cursor, to: end) >= tlvLength else { return nil }

            let valueStart = cursor
            cursor = data.index(cursor, offsetBy: tlvLength)
            let value = data[valueStart..<cursor]

            switch tlvType {
            case .fileName:
                fileName = String(data: Data(value), encoding: .utf8)
            case .fileSize:
                if tlvLength == 4 || tlvLength == 8 {
                    var size: UInt64 = 0
                    for byte in value {
                        size = (size << 8) | UInt64(byte)
                    }
                    if size > UInt64(FileTransferLimits.maxPayloadBytes) {
                        return nil
                    }
                    fileSize = size
                }
            case .mimeType:
                mimeType = String(data: Data(value), encoding: .utf8)
            case .content:
                let proposedSize = content.count + value.count
                if proposedSize > FileTransferLimits.maxPayloadBytes {
                    return nil
                }
                content.append(contentsOf: value)
            case nil:
                continue
            }
        }

        guard !content.isEmpty else { return nil }
        guard FileTransferLimits.isValidPayload(content.count) else { return nil }
        return BitchatFilePacket(
            fileName: fileName,
            fileSize: fileSize ?? UInt64(content.count),
            mimeType: mimeType,
            content: content
        )
    }
}

/// Wire-compatible identity for private media exchanged by clients using the
/// current iOS entropy-bearing filenames, without extending the deployed file
/// TLV. Android clients reject unknown file tags, so eligible senders and
/// receivers derive the receipt key from fields already on the wire.
///
/// Locally-created image and voice-note filenames contain a UUID or live-voice
/// burst ID. Including the normalized direction keeps a reused filename
/// distinct across chats while allowing short and full Noise-key peer IDs to
/// converge. Android and older-iOS timestamp-only names remain ineligible and
/// retain their legacy random local IDs (transfer-compatible, no receipts).
enum PrivateMediaMessageIdentity {
    private static let domain = Data("bitchat-private-media-message-v1".utf8)
    private static let idPrefix = "media-"
    private static let digestHexLength = 32

    static func isStableID(_ candidate: String) -> Bool {
        guard candidate.hasPrefix(idPrefix) else { return false }
        let digest = candidate.dropFirst(idPrefix.count)
        guard digest.utf8.count == digestHexLength else { return false }
        return digest.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    static func stableID(
        senderPeerID: PeerID,
        recipientPeerID: PeerID,
        fileName: String?
    ) -> String? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let leafName = (fileName as NSString).lastPathComponent
        guard leafName == fileName else { return nil }

        let path = leafName as NSString
        let stem = path.deletingPathExtension
        let fileExtension = path.pathExtension.lowercased()
        switch true {
        case stem.hasPrefix("img_"):
            guard fileExtension == "jpg" || fileExtension == "jpeg" else { return nil }
        case stem.hasPrefix("voice_"):
            guard fileExtension == "m4a" else { return nil }
        default:
            return nil
        }
        let entropyToken = stem.split(separator: "_").last.map(String.init)
        let hasUUIDEntropy = entropyToken.flatMap(UUID.init(uuidString:)) != nil
        let voiceBurstID = stem.hasPrefix("voice_")
            ? String(stem.dropFirst("voice_".count))
            : ""
        let hasBurstEntropy = voiceBurstID.count == 16
            && voiceBurstID.allSatisfy(\.isHexDigit)
        guard hasUUIDEntropy || hasBurstEntropy else {
            return nil
        }

        let fields = [
            Data(senderPeerID.toShort().bare.utf8),
            Data(recipientPeerID.toShort().bare.utf8),
            Data(leafName.utf8)
        ]
        var input = domain
        for field in fields {
            guard let length = UInt32(exactly: field.count) else { return nil }
            var bigEndianLength = length.bigEndian
            withUnsafeBytes(of: &bigEndianLength) {
                input.append(contentsOf: $0)
            }
            input.append(field)
        }

        return "\(idPrefix)\(input.sha256Hex().prefix(digestHexLength))"
    }

    static func stableID(
        for packet: BitchatFilePacket,
        senderPeerID: PeerID,
        recipientPeerID: PeerID
    ) -> String? {
        stableID(
            senderPeerID: senderPeerID,
            recipientPeerID: recipientPeerID,
            fileName: packet.fileName
        )
    }
}
