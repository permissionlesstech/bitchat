import BitFoundation
import Foundation

/// One finalized private file transfer carried inside a single Noise payload.
/// The complete `BitchatFilePacket` is encrypted as one unit, while
/// `fileSHA256` lets the receiver verify byte-identical content before saving.
struct PrivateFileTransferPacket {
    static let version: UInt8 = 2
    static let sha256Length = 32

    let transferID: String
    let fileSHA256: Data
    let filePacket: BitchatFilePacket

    func encode() -> Data? {
        guard fileSHA256.count == Self.sha256Length,
              let transferIDData = transferID.data(using: .utf8),
              transferIDData.count > 0,
              transferIDData.count <= Int(UInt8.max),
              let encodedFilePacket = filePacket.encode(),
              encodedFilePacket.count <= Int(UInt32.max) else {
            return nil
        }

        var encoded = Data()
        encoded.append(Self.version)
        encoded.append(UInt8(transferIDData.count))
        encoded.append(transferIDData)
        encoded.append(fileSHA256)
        appendUInt32(UInt32(encodedFilePacket.count), into: &encoded)
        encoded.append(encodedFilePacket)
        return encoded
    }

    static func decode(_ data: Data) -> PrivateFileTransferPacket? {
        var offset = data.startIndex
        guard readUInt8(from: data, offset: &offset) == version,
              let transferIDLength = readUInt8(from: data, offset: &offset),
              let transferIDData = readData(from: data, offset: &offset, count: Int(transferIDLength)),
              let transferID = String(data: transferIDData, encoding: .utf8),
              !transferID.isEmpty,
              let fileSHA256 = readData(from: data, offset: &offset, count: sha256Length),
              let filePacketLength = readUInt32(from: data, offset: &offset),
              let encodedFilePacket = readData(from: data, offset: &offset, count: Int(filePacketLength)),
              let filePacket = BitchatFilePacket.decode(encodedFilePacket),
              offset == data.endIndex else {
            return nil
        }

        guard !filePacket.content.isEmpty,
              filePacket.content.count <= FileTransferLimits.maxImageBytes,
              filePacket.content.sha256Hash() == fileSHA256 else {
            return nil
        }

        return PrivateFileTransferPacket(
            transferID: transferID,
            fileSHA256: fileSHA256,
            filePacket: filePacket
        )
    }
}

private func appendUInt32(_ value: UInt32, into data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

private func readUInt8(from data: Data, offset: inout Data.Index) -> UInt8? {
    guard offset < data.endIndex else { return nil }
    defer { offset = data.index(after: offset) }
    return data[offset]
}

private func readUInt32(from data: Data, offset: inout Data.Index) -> UInt32? {
    guard data.distance(from: offset, to: data.endIndex) >= 4 else { return nil }
    var value: UInt32 = 0
    for _ in 0..<4 {
        value = (value << 8) | UInt32(data[offset])
        offset = data.index(after: offset)
    }
    return value
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
