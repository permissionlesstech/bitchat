//
// BoardPackets.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import Foundation

// MARK: - Board wire format (MessageType.boardPost payloads)
//
// TLV layout (type u8, length u16 big-endian, value), matching REQUEST_SYNC:
//  - 0x01: kind (u8) — 0x01 post, 0x02 tombstone
//  - 0x02: postID (16B random)
//  - 0x03: geohash (UTF-8, empty = mesh-local board, max 12 chars)
//  - 0x04: content (UTF-8, 1...512 bytes) [post]
//  - 0x05: authorSigningKey (32B Ed25519 public key)
//  - 0x06: authorNickname (UTF-8, max 64 bytes)
//  - 0x07: createdAt (u64 big-endian, ms) [post]
//  - 0x08: expiresAt (u64 big-endian, ms, max 7 days after createdAt) [post]
//  - 0x09: flags (u8, bit0 = urgent) [post]
//  - 0x0A: signature (64B Ed25519)
//  - 0x0B: deletedAt (u64 big-endian, ms) [tombstone]
// Unknown TLVs are skipped for forward compatibility.

enum BoardWireConstants {
    static let postIDLength = 16
    static let signingKeyLength = 32
    static let signatureLength = 64
    static let contentMaxBytes = 512
    static let nicknameMaxBytes = 64
    static let geohashMaxLength = 12
    /// Posts may live at most 7 days past their creation timestamp.
    static let maxLifetimeMs: UInt64 = 7 * 24 * 60 * 60 * 1000
    static let postSigningContext = "bitchat-board-v1"
    static let tombstoneSigningContext = "bitchat-board-del-v1"
    static let geohashAlphabet = Set("0123456789bcdefghjkmnpqrstuvwxyz")
}

private enum BoardTLVType: UInt8 {
    case kind = 0x01
    case postID = 0x02
    case geohash = 0x03
    case content = 0x04
    case authorSigningKey = 0x05
    case authorNickname = 0x06
    case createdAt = 0x07
    case expiresAt = 0x08
    case flags = 0x09
    case signature = 0x0A
    case deletedAt = 0x0B
}

private enum BoardWireKind: UInt8 {
    case post = 0x01
    case tombstone = 0x02
}

/// A signed, persistent bulletin-board notice.
struct BoardPostPacket: Equatable {
    let postID: Data
    /// Empty string scopes the post to the mesh-local board.
    let geohash: String
    let content: String
    let authorSigningKey: Data
    let authorNickname: String
    let createdAt: UInt64
    let expiresAt: UInt64
    let flags: UInt8
    let signature: Data

    static let urgentFlag: UInt8 = 0x01

    var isUrgent: Bool { flags & Self.urgentFlag != 0 }

    /// Canonical bytes covered by the Ed25519 signature. Variable-length
    /// fields are length-prefixed so no two field combinations can collide.
    static func signingBytes(
        postID: Data,
        geohash: String,
        content: String,
        authorSigningKey: Data,
        authorNickname: String,
        createdAt: UInt64,
        expiresAt: UInt64,
        flags: UInt8
    ) -> Data {
        var out = Data()
        BoardWireEncoding.appendContext(BoardWireConstants.postSigningContext, to: &out)
        out.append(postID)
        BoardWireEncoding.appendLengthPrefixed(Data(geohash.utf8), to: &out)
        BoardWireEncoding.appendLengthPrefixed(Data(content.utf8), to: &out)
        out.append(authorSigningKey)
        BoardWireEncoding.appendLengthPrefixed(Data(authorNickname.utf8), to: &out)
        BoardWireEncoding.appendUInt64(createdAt, to: &out)
        BoardWireEncoding.appendUInt64(expiresAt, to: &out)
        out.append(flags)
        return out
    }

    var signingBytes: Data {
        Self.signingBytes(
            postID: postID,
            geohash: geohash,
            content: content,
            authorSigningKey: authorSigningKey,
            authorNickname: authorNickname,
            createdAt: createdAt,
            expiresAt: expiresAt,
            flags: flags
        )
    }

    func verifySignature() -> Bool {
        BoardWireEncoding.verify(signature: signature, over: signingBytes, publicKey: authorSigningKey)
    }
}

/// A signed deletion marker. Only the author's key can produce one; receivers
/// keep it until the post's original expiry so the delete outruns the post.
struct BoardTombstonePacket: Equatable {
    let postID: Data
    let authorSigningKey: Data
    let deletedAt: UInt64
    let signature: Data

    static func signingBytes(postID: Data, deletedAt: UInt64) -> Data {
        var out = Data()
        BoardWireEncoding.appendContext(BoardWireConstants.tombstoneSigningContext, to: &out)
        out.append(postID)
        BoardWireEncoding.appendUInt64(deletedAt, to: &out)
        return out
    }

    var signingBytes: Data {
        Self.signingBytes(postID: postID, deletedAt: deletedAt)
    }

    func verifySignature() -> Bool {
        BoardWireEncoding.verify(signature: signature, over: signingBytes, publicKey: authorSigningKey)
    }
}

/// Decoded board payload: either a live post or a tombstone.
enum BoardWire: Equatable {
    case post(BoardPostPacket)
    case tombstone(BoardTombstonePacket)

    func encode() -> Data {
        var out = Data()
        func putTLV(_ t: BoardTLVType, _ v: Data) {
            out.append(t.rawValue)
            let len = UInt16(v.count)
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
            out.append(v)
        }
        switch self {
        case .post(let post):
            putTLV(.kind, Data([BoardWireKind.post.rawValue]))
            putTLV(.postID, post.postID)
            putTLV(.geohash, Data(post.geohash.utf8))
            putTLV(.content, Data(post.content.utf8))
            putTLV(.authorSigningKey, post.authorSigningKey)
            putTLV(.authorNickname, Data(post.authorNickname.utf8))
            putTLV(.createdAt, BoardWireEncoding.uint64Data(post.createdAt))
            putTLV(.expiresAt, BoardWireEncoding.uint64Data(post.expiresAt))
            putTLV(.flags, Data([post.flags]))
            putTLV(.signature, post.signature)
        case .tombstone(let tombstone):
            putTLV(.kind, Data([BoardWireKind.tombstone.rawValue]))
            putTLV(.postID, tombstone.postID)
            putTLV(.authorSigningKey, tombstone.authorSigningKey)
            putTLV(.deletedAt, BoardWireEncoding.uint64Data(tombstone.deletedAt))
            putTLV(.signature, tombstone.signature)
        }
        return out
    }

    /// Structural decode; the caller must still verify the signature before
    /// ingesting (`verifySignature()`).
    static func decode(from data: Data) -> BoardWire? {
        var off = data.startIndex
        var kind: BoardWireKind?
        var postID: Data?
        var geohash: String?
        var content: String?
        var contentBytes = 0
        var authorSigningKey: Data?
        var authorNickname: String?
        var nicknameBytes = 0
        var createdAt: UInt64?
        var expiresAt: UInt64?
        var flags: UInt8?
        var signature: Data?
        var deletedAt: UInt64?

        while off + 3 <= data.endIndex {
            let t = data[off]; off += 1
            let len = (Int(data[off]) << 8) | Int(data[off + 1]); off += 2
            guard off + len <= data.endIndex else { return nil }
            let v = data.subdata(in: off..<(off + len)); off += len
            switch BoardTLVType(rawValue: t) {
            case .kind:
                guard v.count == 1 else { return nil }
                kind = BoardWireKind(rawValue: v[v.startIndex])
            case .postID:
                guard v.count == BoardWireConstants.postIDLength else { return nil }
                postID = v
            case .geohash:
                guard v.count <= BoardWireConstants.geohashMaxLength else { return nil }
                geohash = String(data: v, encoding: .utf8)
            case .content:
                guard v.count <= BoardWireConstants.contentMaxBytes else { return nil }
                contentBytes = v.count
                content = String(data: v, encoding: .utf8)
            case .authorSigningKey:
                guard v.count == BoardWireConstants.signingKeyLength else { return nil }
                authorSigningKey = v
            case .authorNickname:
                guard v.count <= BoardWireConstants.nicknameMaxBytes else { return nil }
                nicknameBytes = v.count
                authorNickname = String(data: v, encoding: .utf8)
            case .createdAt:
                createdAt = BoardWireEncoding.uint64(from: v)
            case .expiresAt:
                expiresAt = BoardWireEncoding.uint64(from: v)
            case .flags:
                guard v.count == 1 else { return nil }
                flags = v[v.startIndex]
            case .signature:
                guard v.count == BoardWireConstants.signatureLength else { return nil }
                signature = v
            case .deletedAt:
                deletedAt = BoardWireEncoding.uint64(from: v)
            case nil:
                continue // forward compatible; ignore unknown TLVs
            }
        }

        guard let postID, let authorSigningKey, let signature else { return nil }

        switch kind {
        case .post:
            guard let geohash, let content, let authorNickname,
                  let createdAt, let expiresAt, let flags,
                  contentBytes >= 1,
                  nicknameBytes <= BoardWireConstants.nicknameMaxBytes,
                  isValidGeohashField(geohash),
                  expiresAt > createdAt,
                  expiresAt - createdAt <= BoardWireConstants.maxLifetimeMs else {
                return nil
            }
            return .post(BoardPostPacket(
                postID: postID,
                geohash: geohash,
                content: content,
                authorSigningKey: authorSigningKey,
                authorNickname: authorNickname,
                createdAt: createdAt,
                expiresAt: expiresAt,
                flags: flags,
                signature: signature
            ))
        case .tombstone:
            guard let deletedAt else { return nil }
            return .tombstone(BoardTombstonePacket(
                postID: postID,
                authorSigningKey: authorSigningKey,
                deletedAt: deletedAt,
                signature: signature
            ))
        case nil:
            return nil
        }
    }

    func verifySignature() -> Bool {
        switch self {
        case .post(let post): return post.verifySignature()
        case .tombstone(let tombstone): return tombstone.verifySignature()
        }
    }

    /// Cheap TLV peek for relay policy: is this payload an urgent post?
    /// Avoids a full decode on the hot relay path.
    static func urgentFlag(in data: Data) -> Bool {
        var off = data.startIndex
        while off + 3 <= data.endIndex {
            let t = data[off]; off += 1
            let len = (Int(data[off]) << 8) | Int(data[off + 1]); off += 2
            guard off + len <= data.endIndex else { return false }
            if t == BoardTLVType.flags.rawValue, len == 1 {
                return data[off] & BoardPostPacket.urgentFlag != 0
            }
            off += len
        }
        return false
    }

    /// Empty geohash = mesh-local board; otherwise 1-12 chars of the geohash
    /// base32 alphabet.
    private static func isValidGeohashField(_ geohash: String) -> Bool {
        geohash.isEmpty || geohash.allSatisfy { BoardWireConstants.geohashAlphabet.contains($0) }
    }
}

enum BoardWireEncoding {
    static func appendContext(_ context: String, to out: inout Data) {
        let bytes = Data(context.utf8)
        out.append(UInt8(min(bytes.count, 255)))
        out.append(bytes.prefix(255))
    }

    static func appendLengthPrefixed(_ value: Data, to out: inout Data) {
        let len = UInt16(min(value.count, Int(UInt16.max)))
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(value.prefix(Int(UInt16.max)))
    }

    static func appendUInt64(_ value: UInt64, to out: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
    }

    static func uint64Data(_ value: UInt64) -> Data {
        var out = Data()
        appendUInt64(value, to: &out)
        return out
    }

    static func uint64(from data: Data) -> UInt64? {
        guard data.count == 8 else { return nil }
        var value: UInt64 = 0
        for byte in data { value = (value << 8) | UInt64(byte) }
        return value
    }

    static func verify(signature: Data, over message: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: message)
    }
}
