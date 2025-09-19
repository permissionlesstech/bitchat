//
// BitchatFilePacket.swift
// bitchat
//
// TLV encoder/decoder for file transfer payloads (images, audio, and generic files)
// v2 Spec: 0x01 FILE_NAME (utf8), 0x02 FILE_SIZE (4 bytes, BE), 0x03 MIME_TYPE (utf8), 0x04 CONTENT (4-byte len)
//

import Foundation
import CryptoKit

struct BitchatFilePacket {
    enum TLVType: UInt8 {
        case fileName  = 0x01
        case fileSize  = 0x02
        case mimeType  = 0x03
        case content   = 0x04
    }

    let fileName: String
    let fileSize: UInt32
    let mimeType: String
    let content: Data

    func encode() -> Data? {
        var out = Data()
        
        // Standard TLV helper for FILE_NAME and MIME_TYPE (2-byte length)
        func appendStandardTLV(_ type: TLVType, _ value: Data) {
            out.append(type.rawValue)
            let len = UInt16(min(value.count, 0xFFFF))
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
            out.append(value.prefix(Int(len)))
        }
        
        // FILE_NAME
        if let nameData = fileName.data(using: .utf8) { 
            appendStandardTLV(.fileName, nameData) 
        }
        
        // FILE_SIZE (4 bytes, UInt32 BE) - v2 spec
        out.append(TLVType.fileSize.rawValue)
        out.append(UInt8(0)) // Length high byte = 0
        out.append(UInt8(4)) // Length low byte = 4
        let size32 = UInt32(min(fileSize, UInt32.max))
        out.append(UInt8((size32 >> 24) & 0xFF))
        out.append(UInt8((size32 >> 16) & 0xFF))
        out.append(UInt8((size32 >> 8) & 0xFF))
        out.append(UInt8(size32 & 0xFF))
        
        // MIME_TYPE
        if let mimeData = mimeType.data(using: .utf8) { 
            appendStandardTLV(.mimeType, mimeData) 
        }
        
        // CONTENT (4-byte length) - v2 spec
        out.append(TLVType.content.rawValue)
        let contentLen = UInt32(content.count)
        out.append(UInt8((contentLen >> 24) & 0xFF))
        out.append(UInt8((contentLen >> 16) & 0xFF))
        out.append(UInt8((contentLen >> 8) & 0xFF))
        out.append(UInt8(contentLen & 0xFF))
        out.append(content)
        
        return out
    }

    static func decode(from data: Data) -> BitchatFilePacket? {
        var idx = 0
        func read(_ n: Int) -> Data? {
            guard idx + n <= data.count else { return nil }
            defer { idx += n }
            return data.subdata(in: idx..<(idx+n))
        }
        func read8() -> UInt8? { read(1)?.first }
        func read16() -> UInt16? {
            guard let d = read(2) else { return nil }
            return (UInt16(d[0]) << 8) | UInt16(d[1])
        }
        func read32() -> UInt32? {
            guard let d = read(4) else { return nil }
            return (UInt32(d[0]) << 24) | (UInt32(d[1]) << 16) | (UInt32(d[2]) << 8) | UInt32(d[3])
        }

        var name: String?
        var size: UInt32?
        var mime: String?
        var contentData = Data()

        while idx < data.count {
            guard let t = read8(), let tlvType = TLVType(rawValue: t) else { return nil }
            
            // CONTENT uses 4-byte length; others use 2-byte length
            let len: Int
            if tlvType == .content {
                guard let len32 = read32() else { return nil }
                len = Int(len32)
            } else {
                guard let len16 = read16() else { return nil }
                len = Int(len16)
            }
            
            guard len >= 0, idx + len <= data.count else { return nil }
            let val = data.subdata(in: idx..<(idx+len))
            idx += len
            
            switch tlvType {
            case .fileName:
                name = String(data: val, encoding: .utf8)
            case .fileSize:
                guard len == 4 else { return nil } // v2 spec: 4 bytes
                var s: UInt32 = 0
                for b in val { s = (s << 8) | UInt32(b) }
                size = s
            case .mimeType:
                mime = String(data: val, encoding: .utf8)
            case .content:
                // Expect single CONTENT TLV; if multiple, concatenate defensively
                contentData.append(val)
            }
        }

        // Validate
        guard !contentData.isEmpty else { return nil }
        let finalSize = size ?? UInt32(contentData.count)
        let finalName = name ?? "file"
        let finalMime = mime ?? "application/octet-stream"
        return BitchatFilePacket(fileName: finalName, fileSize: finalSize, mimeType: finalMime, content: contentData)
    }
}

extension Data { func sha256Hex() -> String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() } }
