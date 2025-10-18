//
// BinaryTransfer.swift
// bitchat
//
// Defines binary transfer metadata and chunk representations used for
// sending large payloads such as images or audio clips over the mesh
// network. These helpers focus purely on the wire format so higher level
// components can assemble and persist transfers however they choose.
//

import Foundation

/// Binary transfer payload categories supported by the protocol.
enum BinaryTransferKind: UInt8, CaseIterable {
    case image = 0x01
    case audio = 0x02

    var description: String {
        switch self {
        case .image: "image"
        case .audio: "audio"
        }
    }
}

/// Metadata describing a binary transfer before the chunk stream starts.
///
/// The metadata frame is small enough to fit within a single BLE packet and
/// provides enough information for receivers to decide whether they want to
/// accept the transfer and how to assemble subsequent chunks.
struct BinaryTransferMetadata: Equatable {
    // MARK: Format constants

    static let formatVersion: UInt8 = 1
    static let maxFilenameLength: Int = 120
    static let maxMimeTypeLength: Int = 64
    static let maxChecksumLength: Int = 32
    static let maxTotalSize: UInt32 = 2_000_000 // ~2 MB cap for initial rollout
    static let minChunkSize: UInt16 = 128
    static let maxChunkSize: UInt16 = 4_096

    struct Flags {
        static let hasFilename: UInt8 = 0x01
        static let hasChecksum: UInt8 = 0x02
    }

    let transferID: UUID
    let kind: BinaryTransferKind
    let mimeType: String
    let totalSize: UInt32
    let chunkSize: UInt16
    let chunkCount: UInt16
    let filename: String?
    let checksum: Data?

    /// Public convenience initializer that computes `chunkCount` from the
    /// provided size parameters.
    init?(
        transferID: UUID = UUID(),
        kind: BinaryTransferKind,
        mimeType: String,
        totalSize: Int,
        chunkSize: Int,
        filename: String? = nil,
        checksum: Data? = nil
    ) {
        guard totalSize > 0, totalSize <= Int(Self.maxTotalSize) else { return nil }
        guard chunkSize >= Int(Self.minChunkSize), chunkSize <= Int(Self.maxChunkSize) else { return nil }
        let count = (totalSize + (chunkSize - 1)) / chunkSize
        guard count > 0, count <= Int(UInt16.max) else { return nil }

        let chunkCount = UInt16(count)
        self.init(
            transferID: transferID,
            kind: kind,
            mimeType: mimeType,
            totalSize: UInt32(totalSize),
            chunkSize: UInt16(chunkSize),
            chunkCount: chunkCount,
            filename: filename ?? transferID.uuidString,
            checksum: checksum
        )
    }

    /// Designated initializer with fully specified fields. Performs strict
    /// validation to keep malformed metadata off the wire.
    init?(
        transferID: UUID,
        kind: BinaryTransferKind,
        mimeType: String,
        totalSize: UInt32,
        chunkSize: UInt16,
        chunkCount: UInt16,
        filename: String?,
        checksum: Data?
    ) {
        guard totalSize > 0, totalSize <= Self.maxTotalSize else { return nil }
        guard chunkSize >= Self.minChunkSize, chunkSize <= Self.maxChunkSize else { return nil }
        guard chunkCount > 0 else { return nil }

        let expectedCount = UInt32((Int(totalSize) + Int(chunkSize) - 1) / Int(chunkSize))
        guard UInt32(chunkCount) == expectedCount else { return nil }

        guard let sanitizedMimeType = Self.sanitizeMimeType(mimeType) else { return nil }
        guard let sanitizedFilename = Self.sanitizeFilename(filename) else { return nil }

        if let checksum = checksum {
            guard checksum.count > 0, checksum.count <= Self.maxChecksumLength else { return nil }
        }

        self.transferID = transferID
        self.kind = kind
        self.mimeType = sanitizedMimeType
        self.totalSize = totalSize
        self.chunkSize = chunkSize
        self.chunkCount = chunkCount
        self.filename = sanitizedFilename
        self.checksum = checksum
    }

    init?(data: Data) {
        let dataCopy = Data(data)
        guard dataCopy.count >= 1 + 1 + 1 + 16 + 4 + 2 + 2 else { return nil }
        var offset = 0

        guard let version = dataCopy.readUInt8(at: &offset), version == Self.formatVersion else { return nil }
        guard let kindRaw = dataCopy.readUInt8(at: &offset), let kind = BinaryTransferKind(rawValue: kindRaw) else { return nil }
        guard let flags = dataCopy.readUInt8(at: &offset) else { return nil }
        guard let transferUUIDString = dataCopy.readUUID(at: &offset), let transferID = UUID(uuidString: transferUUIDString) else {
            return nil
        }
        guard let totalSize = dataCopy.readUInt32(at: &offset) else { return nil }
        guard let chunkSize = dataCopy.readUInt16(at: &offset) else { return nil }
        guard let chunkCount = dataCopy.readUInt16(at: &offset) else { return nil }
        guard let mimeType = dataCopy.readString(at: &offset, maxLength: Self.maxMimeTypeLength) else { return nil }

        var filename: String?
        if (flags & Flags.hasFilename) != 0 {
            guard let value = dataCopy.readString(at: &offset, maxLength: Self.maxFilenameLength) else { return nil }
            filename = value
        }

        var checksum: Data?
        if (flags & Flags.hasChecksum) != 0 {
            guard let length = dataCopy.readUInt8(at: &offset), length > 0, length <= Self.maxChecksumLength else { return nil }
            guard let value = dataCopy.readFixedBytes(at: &offset, count: Int(length)) else { return nil }
            checksum = Data(value)
        }

        self.init(
            transferID: transferID,
            kind: kind,
            mimeType: mimeType,
            totalSize: totalSize,
            chunkSize: chunkSize,
            chunkCount: chunkCount,
            filename: filename,
            checksum: checksum
        )
    }

    func toBinaryData() -> Data {
        var data = Data()
        data.append(Self.formatVersion)
        data.append(kind.rawValue)
        var flags: UInt8 = 0
        if filename != nil { flags |= Flags.hasFilename }
        if checksum != nil { flags |= Flags.hasChecksum }
        data.append(flags)
        data.appendUUID(transferID.uuidString.uppercased())
        data.appendUInt32(totalSize)
        data.appendUInt16(chunkSize)
        data.appendUInt16(chunkCount)
        data.appendString(mimeType, maxLength: Self.maxMimeTypeLength)
        if let filename = filename {
            data.appendString(filename, maxLength: Self.maxFilenameLength)
        }
        if let checksum = checksum {
            data.appendUInt8(UInt8(checksum.count))
            data.append(checksum)
        }
        return data
    }

    private static func sanitizeMimeType(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxMimeTypeLength else { return nil }
        guard trimmed.contains("/") else { return nil }
        if trimmed.rangeOfCharacter(from: .controlCharacters) != nil { return nil }
        return trimmed
    }

    private static func sanitizeFilename(_ value: String?) -> String? {
        guard let value = value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxFilenameLength else { return nil }
        if trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:\n\r")) != nil { return nil }
        if trimmed.rangeOfCharacter(from: .controlCharacters) != nil { return nil }
        return trimmed
    }
}

/// A single binary transfer chunk. Each chunk carries a slice of the payload
/// identified by `sequenceNumber`.
struct BinaryTransferChunk: Equatable {
    static let formatVersion: UInt8 = 1

    let transferID: UUID
    let sequenceNumber: UInt16
    let totalChunks: UInt16
    let payload: Data

    init?(
        transferID: UUID,
        sequenceNumber: UInt16,
        totalChunks: UInt16,
        payload: Data
    ) {
        guard totalChunks > 0, sequenceNumber < totalChunks else { return nil }
        guard !payload.isEmpty else { return nil }
        guard payload.count <= Int(BinaryTransferMetadata.maxChunkSize) else { return nil }

        self.transferID = transferID
        self.sequenceNumber = sequenceNumber
        self.totalChunks = totalChunks
        self.payload = payload
    }

    init?(data: Data) {
        let dataCopy = Data(data)
        guard dataCopy.count >= 1 + 16 + 2 + 2 + 2 else { return nil }
        var offset = 0
        guard let version = dataCopy.readUInt8(at: &offset), version == Self.formatVersion else { return nil }
        guard let transferUUIDString = dataCopy.readUUID(at: &offset), let transferID = UUID(uuidString: transferUUIDString) else {
            return nil
        }
        guard let sequenceNumber = dataCopy.readUInt16(at: &offset) else { return nil }
        guard let totalChunks = dataCopy.readUInt16(at: &offset) else { return nil }
        guard let payloadLength = dataCopy.readUInt16(at: &offset) else { return nil }
        guard payloadLength > 0, payloadLength <= BinaryTransferMetadata.maxChunkSize else { return nil }
        guard let payload = dataCopy.readFixedBytes(at: &offset, count: Int(payloadLength)) else { return nil }

        self.init(
            transferID: transferID,
            sequenceNumber: sequenceNumber,
            totalChunks: totalChunks,
            payload: Data(payload)
        )
    }

    func toBinaryData() -> Data {
        var data = Data()
        data.append(Self.formatVersion)
        data.appendUUID(transferID.uuidString.uppercased())
        data.appendUInt16(sequenceNumber)
        data.appendUInt16(totalChunks)
        data.appendUInt16(UInt16(payload.count))
        data.append(payload)
        return data
    }
}
