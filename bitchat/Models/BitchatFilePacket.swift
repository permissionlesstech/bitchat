import Foundation

// Cross-platform TLV file packet matching Android PR #440
// TLVs:
//  - 0x01: filename (UTF-8) with 2-byte length (UInt16 BE)
//  - 0x02: file size (UInt32) with 2-byte TLV length value = 4, then 4 bytes BE
//  - 0x03: mime type (UTF-8) with 2-byte length (UInt16 BE)
//  - 0x04: content (bytes) SPECIAL: 4-byte length (UInt32 BE) immediately after type (no 2-byte TLV length)
// Decoder tolerates multiple CONTENT TLVs (concatenates)
// Size limit is enforced via NoiseSecurityConstants.maxMessageSize

struct BitchatFilePacket {
    let fileName: String
    let fileSize: UInt64
    let mimeType: String
    let content: Data

    enum TLV: UInt8 {
        case fileName = 0x01
        case fileSize = 0x02
        case mimeType = 0x03
        case content = 0x04
    }
}

extension BitchatFilePacket {
    enum EncodeError: Error { case oversize, invalidFields }
    enum DecodeError: Error { case malformed, oversize }

    func encode() throws -> Data {
        // Enforce overall size limit (by content size primarily)
        if content.count > NoiseSecurityConstants.maxMessageSize {
            throw EncodeError.oversize
        }
        // Prepare TLV fields
        guard let nameData = fileName.data(using: .utf8),
              let mimeData = mimeType.data(using: .utf8) else {
            throw EncodeError.invalidFields
        }
        var out = Data()
        // FILE_NAME (0x01) + len(2) + bytes
        out.append(TLV.fileName.rawValue)
        var nameLen = UInt16(min(nameData.count, 0xFFFF)).bigEndian
        withUnsafeBytes(of: &nameLen) { out.append($0.bindMemory(to: UInt8.self)) }
        out.append(nameData.prefix(Int(UInt16(bigEndian: nameLen))))
        // FILE_SIZE (0x02) + len(2)=4 + 4 bytes BE
        out.append(TLV.fileSize.rawValue)
        var sizeFieldLen = UInt16(4).bigEndian
        withUnsafeBytes(of: &sizeFieldLen) { out.append($0.bindMemory(to: UInt8.self)) }
        let size32 = UInt32(truncatingIfNeeded: fileSize)
        var beSize32 = size32.bigEndian
        withUnsafeBytes(of: &beSize32) { out.append($0.bindMemory(to: UInt8.self)) }
        // MIME_TYPE (0x03) + len(2) + bytes
        out.append(TLV.mimeType.rawValue)
        var mimeLen = UInt16(min(mimeData.count, 0xFFFF)).bigEndian
        withUnsafeBytes(of: &mimeLen) { out.append($0.bindMemory(to: UInt8.self)) }
        out.append(mimeData.prefix(Int(UInt16(bigEndian: mimeLen))))
        // CONTENT (0x04) + len(4) + bytes [SPECIAL]
        out.append(TLV.content.rawValue)
        var cLen = UInt32(content.count).bigEndian
        withUnsafeBytes(of: &cLen) { out.append($0.bindMemory(to: UInt8.self)) }
        out.append(content)
        return out
    }

    static func decode(_ data: Data) throws -> BitchatFilePacket {
        var offset = 0
        func require(_ n: Int) -> Bool { offset + n <= data.count }
        func read8() -> UInt8? { guard require(1) else { return nil }; defer { offset += 1 }; return data[offset] }
        func read16() -> UInt16? {
            guard require(2) else { return nil }
            let v = (UInt16(data[offset]) << 8) | UInt16(data[offset+1])
            offset += 2
            return v
        }
        func read32() -> UInt32? {
            guard require(4) else { return nil }
            let v = (UInt32(data[offset]) << 24) | (UInt32(data[offset+1]) << 16) | (UInt32(data[offset+2]) << 8) | UInt32(data[offset+3])
            offset += 4
            return v
        }
        func readData(_ n: Int) -> Data? { guard require(n) else { return nil }; defer { offset += n }; return data.subdata(in: offset..<(offset+n)) }

        var name: String?
        var mime: String?
        var size: UInt64?
        var content = Data()

        while offset < data.count {
            guard let tByte = read8(), let t = TLV(rawValue: tByte) else { throw DecodeError.malformed }
            switch t {
            case .fileName:
                guard let l = read16(), let v = readData(Int(l)) else { throw DecodeError.malformed }
                name = String(data: v, encoding: .utf8) ?? ""
            case .fileSize:
                guard let l = read16(), l == 4, let sz = read32() else { throw DecodeError.malformed }
                size = UInt64(sz)
            case .mimeType:
                guard let l = read16(), let v = readData(Int(l)) else { throw DecodeError.malformed }
                mime = String(data: v, encoding: .utf8) ?? "application/octet-stream"
            case .content:
                // SPECIAL: 4-byte length immediately
                // Tolerate legacy variant with 2-byte length if encountered
                let next2IsLen: Bool = {
                    if !require(2) { return false }
                    let test = (UInt16(data[offset]) << 8) | UInt16(data[offset+1])
                    // Heuristic: if after those 2 bytes there is exactly that many bytes available, accept; else use 4-byte path
                    return require(2 + Int(test))
                }()
                if next2IsLen {
                    // Legacy tolerant path
                    guard let l = read16(), let v = readData(Int(l)) else { throw DecodeError.malformed }
                    content.append(v)
                } else {
                    guard let l32 = read32(), let v = readData(Int(l32)) else { throw DecodeError.malformed }
                    content.append(v)
                }
            }
        }
        if content.count > NoiseSecurityConstants.maxMessageSize { throw DecodeError.oversize }
        let resolvedName = name ?? "file"
        let resolvedMime = mime ?? "application/octet-stream"
        let resolvedSize = size ?? UInt64(content.count)
        return BitchatFilePacket(fileName: resolvedName, fileSize: resolvedSize, mimeType: resolvedMime, content: content)
    }
}
