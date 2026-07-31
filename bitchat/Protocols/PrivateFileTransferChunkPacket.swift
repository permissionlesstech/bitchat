import BitFoundation
import Foundation

/// One app-layer chunk of a private file transfer carried inside a Noise
/// payload. Chunks stay below Noise's 64 KiB message guard; BLE fragmentation
/// may still split the encrypted chunk at the transport layer.
struct PrivateFileTransferChunkPacket: Equatable {
    static let version: UInt8 = 1
    static let sha256Length = 32

    let transferID: String
    let index: Int
    let total: Int
    let fileName: String?
    let mimeType: String?
    let fileSize: UInt64
    let fileSHA256: Data
    let content: Data

    func encode() -> Data? {
        guard index >= 0, index <= Int(UInt16.max),
              total > 0, total <= Int(UInt16.max),
              index < total,
              fileSHA256.count == Self.sha256Length,
              content.count <= Int(UInt16.max),
              let transferIDData = transferID.data(using: .utf8),
              transferIDData.count > 0,
              transferIDData.count <= Int(UInt8.max) else {
            return nil
        }

        let fileNameData = fileName?.data(using: .utf8) ?? Data()
        let mimeTypeData = mimeType?.data(using: .utf8) ?? Data()
        guard fileNameData.count <= Int(UInt16.max),
              mimeTypeData.count <= Int(UInt16.max) else {
            return nil
        }

        var encoded = Data()
        encoded.append(Self.version)
        encoded.append(UInt8(transferIDData.count))
        encoded.append(transferIDData)
        appendUInt16(UInt16(index), into: &encoded)
        appendUInt16(UInt16(total), into: &encoded)
        appendUInt64(fileSize, into: &encoded)
        encoded.append(fileSHA256)
        appendLengthPrefixed(fileNameData, into: &encoded)
        appendLengthPrefixed(mimeTypeData, into: &encoded)
        appendLengthPrefixed(content, into: &encoded)
        return encoded
    }

    static func decode(_ data: Data) -> PrivateFileTransferChunkPacket? {
        var offset = data.startIndex
        guard readUInt8(from: data, offset: &offset) == version,
              let transferIDLength = readUInt8(from: data, offset: &offset),
              let transferIDData = readData(from: data, offset: &offset, count: Int(transferIDLength)),
              let transferID = String(data: transferIDData, encoding: .utf8),
              !transferID.isEmpty,
              let index = readUInt16(from: data, offset: &offset),
              let total = readUInt16(from: data, offset: &offset),
              let fileSize = readUInt64(from: data, offset: &offset),
              let fileSHA256 = readData(from: data, offset: &offset, count: sha256Length),
              let fileNameData = readLengthPrefixedData(from: data, offset: &offset),
              let mimeTypeData = readLengthPrefixedData(from: data, offset: &offset),
              let content = readLengthPrefixedData(from: data, offset: &offset),
              offset == data.endIndex else {
            return nil
        }

        let indexValue = Int(index)
        let totalValue = Int(total)
        guard totalValue > 0,
              indexValue < totalValue,
              fileSize <= UInt64(FileTransferLimits.maxPayloadBytes),
              !content.isEmpty else {
            return nil
        }

        return PrivateFileTransferChunkPacket(
            transferID: transferID,
            index: indexValue,
            total: totalValue,
            fileName: fileNameData.isEmpty ? nil : String(data: fileNameData, encoding: .utf8),
            mimeType: mimeTypeData.isEmpty ? nil : String(data: mimeTypeData, encoding: .utf8),
            fileSize: fileSize,
            fileSHA256: fileSHA256,
            content: content
        )
    }
}

private func appendLengthPrefixed(_ data: Data, into encoded: inout Data) {
    appendUInt16(UInt16(data.count), into: &encoded)
    encoded.append(data)
}

private func appendUInt16(_ value: UInt16, into data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

private func appendUInt64(_ value: UInt64, into data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

private func readUInt8(from data: Data, offset: inout Data.Index) -> UInt8? {
    guard offset < data.endIndex else { return nil }
    defer { offset = data.index(after: offset) }
    return data[offset]
}

private func readUInt16(from data: Data, offset: inout Data.Index) -> UInt16? {
    guard data.distance(from: offset, to: data.endIndex) >= 2 else { return nil }
    var value: UInt16 = 0
    for _ in 0..<2 {
        value = (value << 8) | UInt16(data[offset])
        offset = data.index(after: offset)
    }
    return value
}

private func readUInt64(from data: Data, offset: inout Data.Index) -> UInt64? {
    guard data.distance(from: offset, to: data.endIndex) >= 8 else { return nil }
    var value: UInt64 = 0
    for _ in 0..<8 {
        value = (value << 8) | UInt64(data[offset])
        offset = data.index(after: offset)
    }
    return value
}

private func readLengthPrefixedData(from data: Data, offset: inout Data.Index) -> Data? {
    guard let length = readUInt16(from: data, offset: &offset) else { return nil }
    return readData(from: data, offset: &offset, count: Int(length))
}

private func readData(from data: Data, offset: inout Data.Index, count: Int) -> Data? {
    guard count >= 0,
          data.distance(from: offset, to: data.endIndex) >= count else {
        return nil
    }
    let start = offset
    offset = data.index(offset, offsetBy: count)
    return Data(data[start..<offset])
}
