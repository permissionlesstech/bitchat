//
// GroupProtocol.swift
// bitchat
//
// Wire formats and crypto for private groups: creator-signed group state
// (invites and key updates over Noise) and ChaCha20-Poly1305 group messages
// broadcast as MessageType.groupMessage (0x25).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import CryptoKit
import Foundation

// MARK: - Models

/// A member of a private group as pinned in the creator-signed roster.
struct GroupMember: Codable, Equatable {
    /// SHA-256 fingerprint (64 hex chars) of the member's Noise static key.
    let fingerprint: String
    /// The member's Ed25519 signing public key (32 bytes, from their announce).
    let signingKey: Data
    /// Nickname at invite time; display fallback when the peer is offline.
    var nickname: String
}

/// Creator-managed encrypted group. Metadata only — the symmetric key lives
/// in the keychain (see `GroupStore`).
struct BitchatGroup: Codable, Equatable {
    static let maxMembers = 16
    static let groupIDLength = 16
    static let keyLength = 32

    /// 16 random bytes; travels in cleartext on group message packets so
    /// relays can dedup/filter without membership.
    let groupID: Data
    var name: String
    /// Bumps on every key rotation; messages are bound to the epoch they
    /// were sealed under.
    var epoch: UInt32
    var members: [GroupMember]
    /// Fingerprint of the creator — the only identity allowed to sign group
    /// state (invites, key updates) in v1.
    let creatorFingerprint: String

    /// Virtual conversation ID this group's chat is keyed under.
    var peerID: PeerID { PeerID(groupID: groupID) }

    var creator: GroupMember? {
        members.first { $0.fingerprint == creatorFingerprint }
    }

    func isMember(fingerprint: String) -> Bool {
        members.contains { $0.fingerprint == fingerprint }
    }

    func member(withSigningKey signingKey: Data) -> GroupMember? {
        members.first { $0.signingKey == signingKey }
    }
}

// MARK: - TLV helpers

enum GroupTLVError: Error, Equatable {
    /// A TLV value exceeded the 16-bit length field. Encoding fails instead
    /// of silently truncating (which would ship a value the receiver drops).
    case valueTooLong
}

private enum GroupTLV {
    /// Appends a (type, 16-bit length, value) triple. Throws rather than
    /// truncating when `value` does not fit the 16-bit length field, so an
    /// oversize field surfaces a send failure instead of a silently truncated
    /// blob the recipient rejects during decrypt/verify.
    static func put(_ type: UInt8, _ value: Data, into out: inout Data) throws {
        guard value.count <= Int(UInt16.max) else { throw GroupTLVError.valueTooLong }
        out.append(type)
        let length = UInt16(value.count)
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(value)
    }

    /// Iterates (type, value) pairs; returns nil on malformed framing.
    static func parse(_ data: Data) -> [(type: UInt8, value: Data)]? {
        var fields: [(UInt8, Data)] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            guard data.distance(from: offset, to: data.endIndex) >= 3 else { return nil }
            let type = data[offset]
            let high = Int(data[data.index(offset, offsetBy: 1)])
            let low = Int(data[data.index(offset, offsetBy: 2)])
            let length = (high << 8) | low
            let valueStart = data.index(offset, offsetBy: 3)
            guard data.distance(from: valueStart, to: data.endIndex) >= length else { return nil }
            let valueEnd = data.index(valueStart, offsetBy: length)
            fields.append((type, Data(data[valueStart..<valueEnd])))
            offset = valueEnd
        }
        return fields
    }

    static func epochData(_ epoch: UInt32) -> Data {
        var bigEndian = epoch.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    static func epoch(from data: Data) -> UInt32? {
        guard data.count == 4 else { return nil }
        return data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func timestampData(_ timestampMs: UInt64) -> Data {
        var bigEndian = timestampMs.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    static func timestamp(from data: Data) -> UInt64? {
        guard data.count == 8 else { return nil }
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

// MARK: - Roster wire form

enum GroupRosterCoding {
    private static let fingerprintLength = 32
    private static let signingKeyLength = 32
    private static let maxNicknameBytes = 64

    /// Deterministic roster blob: count byte, then per member the raw 32-byte
    /// fingerprint, 32-byte signing key, and length-prefixed UTF-8 nickname.
    /// The creator signature covers the SHA-256 of these exact bytes.
    static func encode(_ members: [GroupMember]) -> Data? {
        guard members.count <= BitchatGroup.maxMembers else { return nil }
        var out = Data([UInt8(members.count)])
        for member in members {
            guard let fingerprintData = Data(hexString: member.fingerprint),
                  fingerprintData.count == fingerprintLength,
                  member.signingKey.count == signingKeyLength else { return nil }
            out.append(fingerprintData)
            out.append(member.signingKey)
            // Truncate on a Character boundary so the byte prefix is always
            // valid UTF-8; a raw byte-prefix could split a multi-byte scalar
            // and make the whole signed roster undecodable on the recipient.
            let nickname = truncatedNicknameBytes(member.nickname)
            out.append(UInt8(nickname.count))
            out.append(nickname)
        }
        return out
    }

    static func decode(_ data: Data) -> [GroupMember]? {
        guard let count = data.first, count <= UInt8(BitchatGroup.maxMembers) else { return nil }
        var members: [GroupMember] = []
        var offset = data.index(after: data.startIndex)
        for _ in 0..<count {
            let fixed = fingerprintLength + signingKeyLength + 1
            guard data.distance(from: offset, to: data.endIndex) >= fixed else { return nil }
            let fingerprintEnd = data.index(offset, offsetBy: fingerprintLength)
            let fingerprint = Data(data[offset..<fingerprintEnd]).hexEncodedString()
            let signingKeyEnd = data.index(fingerprintEnd, offsetBy: signingKeyLength)
            let signingKey = Data(data[fingerprintEnd..<signingKeyEnd])
            let nickLength = Int(data[signingKeyEnd])
            let nickStart = data.index(after: signingKeyEnd)
            guard data.distance(from: nickStart, to: data.endIndex) >= nickLength else { return nil }
            let nickEnd = data.index(nickStart, offsetBy: nickLength)
            guard let nickname = String(data: Data(data[nickStart..<nickEnd]), encoding: .utf8) else { return nil }
            members.append(GroupMember(fingerprint: fingerprint, signingKey: signingKey, nickname: nickname))
            offset = nickEnd
        }
        guard offset == data.endIndex else { return nil }
        return members
    }

    /// UTF-8 bytes of `nickname` trimmed to at most `maxNicknameBytes`,
    /// dropping whole Characters so the result is never split mid-scalar.
    private static func truncatedNicknameBytes(_ nickname: String) -> Data {
        var candidate = nickname
        while Data(candidate.utf8).count > maxNicknameBytes {
            candidate.removeLast()
        }
        return Data(candidate.utf8)
    }
}

// MARK: - Group state payload (groupInvite / groupKeyUpdate over Noise)

/// Creator-signed group state. The same wire form serves invites (0x06) and
/// key updates (0x07); receivers verify the creator signature — computed over
/// "bitchat-group-v1" | groupID | epoch | SHA256(key) | SHA256(roster) —
/// against the creator's signing key pinned in the roster, and require the
/// Noise session peer to BE the creator before accepting any state.
struct GroupStatePayload: Equatable {
    let groupID: Data
    let name: String
    /// Symmetric ChaCha20-Poly1305 group key (32 bytes) for `epoch`.
    let key: Data
    let epoch: UInt32
    let members: [GroupMember]
    let creatorFingerprint: String
    /// Ed25519 signature by the creator.
    let signature: Data

    private enum FieldType: UInt8 {
        case groupID = 0x01
        case name = 0x02
        case key = 0x03
        case epoch = 0x04
        case roster = 0x05
        case creatorFingerprint = 0x06
        case signature = 0x07
    }

    static let signingDomain = Data("bitchat-group-v1".utf8)

    /// The bytes the creator signs. Binding the key, roster, and name by hash
    /// keeps the signed content fixed-size. The name is covered so a relay
    /// that caches/replays a signed state (e.g. store-and-forward) cannot swap
    /// the display name while keeping a valid creator signature.
    static func signingContent(groupID: Data, epoch: UInt32, key: Data, rosterBlob: Data, name: String) -> Data {
        var content = signingDomain
        content.append(groupID)
        content.append(GroupTLV.epochData(epoch))
        content.append(key.sha256Hash())
        content.append(rosterBlob.sha256Hash())
        content.append(Data(name.utf8).sha256Hash())
        return content
    }

    /// Builds a signed state payload. Returns nil when the roster cannot be
    /// encoded (over cap, malformed member) or signing fails.
    static func makeSigned(
        group: BitchatGroup,
        key: Data,
        sign: (Data) -> Data?
    ) -> GroupStatePayload? {
        guard let rosterBlob = GroupRosterCoding.encode(group.members) else { return nil }
        let content = signingContent(groupID: group.groupID, epoch: group.epoch, key: key, rosterBlob: rosterBlob, name: group.name)
        guard let signature = sign(content) else { return nil }
        return GroupStatePayload(
            groupID: group.groupID,
            name: group.name,
            key: key,
            epoch: group.epoch,
            members: group.members,
            creatorFingerprint: group.creatorFingerprint,
            signature: signature
        )
    }

    func encode() -> Data? {
        guard let rosterBlob = GroupRosterCoding.encode(members),
              let fingerprintData = Data(hexString: creatorFingerprint),
              fingerprintData.count == 32 else { return nil }
        var out = Data()
        do {
            try GroupTLV.put(FieldType.groupID.rawValue, groupID, into: &out)
            try GroupTLV.put(FieldType.name.rawValue, Data(name.utf8), into: &out)
            try GroupTLV.put(FieldType.key.rawValue, key, into: &out)
            try GroupTLV.put(FieldType.epoch.rawValue, GroupTLV.epochData(epoch), into: &out)
            try GroupTLV.put(FieldType.roster.rawValue, rosterBlob, into: &out)
            try GroupTLV.put(FieldType.creatorFingerprint.rawValue, fingerprintData, into: &out)
            try GroupTLV.put(FieldType.signature.rawValue, signature, into: &out)
        } catch {
            return nil
        }
        return out
    }

    static func decode(_ data: Data) -> GroupStatePayload? {
        guard let fields = GroupTLV.parse(data) else { return nil }
        var groupID: Data?
        var name: String?
        var key: Data?
        var epoch: UInt32?
        var rosterBlob: Data?
        var members: [GroupMember]?
        var creatorFingerprint: String?
        var signature: Data?

        for (type, value) in fields {
            switch FieldType(rawValue: type) {
            case .groupID where value.count == BitchatGroup.groupIDLength:
                groupID = value
            case .name:
                name = String(data: value, encoding: .utf8)
            case .key where value.count == BitchatGroup.keyLength:
                key = value
            case .epoch:
                epoch = GroupTLV.epoch(from: value)
            case .roster:
                rosterBlob = value
                members = GroupRosterCoding.decode(value)
            case .creatorFingerprint where value.count == 32:
                creatorFingerprint = value.hexEncodedString()
            case .signature where value.count == 64:
                signature = value
            default:
                break // forward compatible; ignore unknown TLVs
            }
        }

        guard let groupID, let name, let key, let epoch,
              rosterBlob != nil, let members, !members.isEmpty,
              let creatorFingerprint, let signature else { return nil }
        return GroupStatePayload(
            groupID: groupID,
            name: name,
            key: key,
            epoch: epoch,
            members: members,
            creatorFingerprint: creatorFingerprint,
            signature: signature
        )
    }

    /// Verifies the creator signature against the creator's signing key
    /// pinned in the roster, and that the creator is actually in the roster.
    func verifyCreatorSignature() -> Bool {
        guard members.count <= BitchatGroup.maxMembers,
              let creator = members.first(where: { $0.fingerprint == creatorFingerprint }),
              let rosterBlob = GroupRosterCoding.encode(members) else { return false }
        let content = GroupStatePayload.signingContent(groupID: groupID, epoch: epoch, key: key, rosterBlob: rosterBlob, name: name)
        return GroupCrypto.verify(signature: signature, for: content, publicKey: creator.signingKey)
    }

    var asGroup: BitchatGroup {
        BitchatGroup(
            groupID: groupID,
            name: name,
            epoch: epoch,
            members: members,
            creatorFingerprint: creatorFingerprint
        )
    }
}

// MARK: - Group message envelope (MessageType 0x25 payload)

/// Cleartext framing of a group message broadcast. Only the group ID, epoch,
/// and nonce are visible to relays; everything about the message — sender,
/// content, timestamps — is inside the ChaCha20-Poly1305 ciphertext.
struct GroupMessageEnvelope: Equatable {
    let groupID: Data
    let epoch: UInt32
    let nonce: Data
    /// ChaChaPoly ciphertext || 16-byte tag.
    let ciphertext: Data

    private enum FieldType: UInt8 {
        case groupID = 0x01
        case epoch = 0x02
        case nonce = 0x03
        case ciphertext = 0x04
    }

    func encode() throws -> Data {
        var out = Data()
        try GroupTLV.put(FieldType.groupID.rawValue, groupID, into: &out)
        try GroupTLV.put(FieldType.epoch.rawValue, GroupTLV.epochData(epoch), into: &out)
        try GroupTLV.put(FieldType.nonce.rawValue, nonce, into: &out)
        try GroupTLV.put(FieldType.ciphertext.rawValue, ciphertext, into: &out)
        return out
    }

    static func decode(_ data: Data) -> GroupMessageEnvelope? {
        guard let fields = GroupTLV.parse(data) else { return nil }
        var groupID: Data?
        var epoch: UInt32?
        var nonce: Data?
        var ciphertext: Data?
        for (type, value) in fields {
            switch FieldType(rawValue: type) {
            case .groupID where value.count == BitchatGroup.groupIDLength:
                groupID = value
            case .epoch:
                epoch = GroupTLV.epoch(from: value)
            case .nonce where value.count == 12:
                nonce = value
            case .ciphertext where !value.isEmpty:
                ciphertext = value
            default:
                break
            }
        }
        guard let groupID, let epoch, let nonce, let ciphertext else { return nil }
        return GroupMessageEnvelope(groupID: groupID, epoch: epoch, nonce: nonce, ciphertext: ciphertext)
    }
}

/// Decrypted, signature-verified inner content of a group message.
struct GroupMessagePlaintext: Equatable {
    let messageID: String
    let senderSigningKey: Data
    let senderNickname: String
    let timestampMs: UInt64
    let content: String
}

// MARK: - Crypto

enum GroupCryptoError: Error, Equatable {
    case malformedPayload
    case signingFailed
    case sealFailed
    case decryptionFailed
    case badSenderSignature
}

enum GroupCrypto {
    static let messageSigningDomain = Data("bitchat-group-msg-v1".utf8)

    private enum InnerField: UInt8 {
        case messageID = 0x01
        case senderSigningKey = 0x02
        case senderNickname = 0x03
        case timestamp = 0x04
        case content = 0x05
        case signature = 0x06
    }

    /// Bytes the sender signs: domain | groupID | epoch | messageID | timestamp | content.
    /// Covering the epoch stops a current member from re-sealing another
    /// member's decrypted inner bytes under a later epoch key (the signature
    /// would no longer verify at the new epoch).
    static func messageSigningContent(groupID: Data, epoch: UInt32, messageID: String, timestampMs: UInt64, content: String) -> Data {
        var data = messageSigningDomain
        data.append(groupID)
        data.append(GroupTLV.epochData(epoch))
        data.append(Data(messageID.utf8))
        data.append(GroupTLV.timestampData(timestampMs))
        data.append(Data(content.utf8))
        return data
    }

    static func verify(signature: Data, for data: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    /// Seals a group message: builds the signed inner TLV and encrypts it with
    /// the epoch key. The cleartext group ID and epoch are bound into the AEAD
    /// as additional data so ciphertext cannot be replayed across groups or
    /// epochs. Returns the encoded 0x25 packet payload.
    static func sealMessage(
        content: String,
        messageID: String,
        senderNickname: String,
        senderSigningKey: Data,
        timestampMs: UInt64,
        groupID: Data,
        epoch: UInt32,
        key: Data,
        sign: (Data) -> Data?
    ) throws -> Data {
        let signingContent = messageSigningContent(
            groupID: groupID,
            epoch: epoch,
            messageID: messageID,
            timestampMs: timestampMs,
            content: content
        )
        guard let signature = sign(signingContent), signature.count == 64 else {
            throw GroupCryptoError.signingFailed
        }

        var inner = Data()
        try GroupTLV.put(InnerField.messageID.rawValue, Data(messageID.utf8), into: &inner)
        try GroupTLV.put(InnerField.senderSigningKey.rawValue, senderSigningKey, into: &inner)
        try GroupTLV.put(InnerField.senderNickname.rawValue, Data(senderNickname.utf8), into: &inner)
        try GroupTLV.put(InnerField.timestamp.rawValue, GroupTLV.timestampData(timestampMs), into: &inner)
        try GroupTLV.put(InnerField.content.rawValue, Data(content.utf8), into: &inner)
        try GroupTLV.put(InnerField.signature.rawValue, signature, into: &inner)

        do {
            let symmetricKey = SymmetricKey(data: key)
            var aad = groupID
            aad.append(GroupTLV.epochData(epoch))
            let sealed = try ChaChaPoly.seal(inner, using: symmetricKey, authenticating: aad)
            var ciphertext = sealed.ciphertext
            ciphertext.append(sealed.tag)
            let envelope = GroupMessageEnvelope(
                groupID: groupID,
                epoch: epoch,
                nonce: Data(sealed.nonce),
                ciphertext: ciphertext
            )
            return try envelope.encode()
        } catch {
            throw GroupCryptoError.sealFailed
        }
    }

    /// Opens a group message envelope with the epoch key: decrypts, parses the
    /// inner TLV, and verifies the sender's Ed25519 signature. Roster
    /// membership of the sender is the CALLER's check — this function only
    /// proves the payload was authored by `senderSigningKey`.
    static func openMessage(_ envelope: GroupMessageEnvelope, key: Data) throws -> GroupMessagePlaintext {
        let inner: Data
        do {
            let symmetricKey = SymmetricKey(data: key)
            var aad = envelope.groupID
            aad.append(GroupTLV.epochData(envelope.epoch))
            let nonce = try ChaChaPoly.Nonce(data: envelope.nonce)
            guard envelope.ciphertext.count > 16 else { throw GroupCryptoError.decryptionFailed }
            let tag = envelope.ciphertext.suffix(16)
            let body = envelope.ciphertext.prefix(envelope.ciphertext.count - 16)
            let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: body, tag: tag)
            inner = try ChaChaPoly.open(sealedBox, using: symmetricKey, authenticating: aad)
        } catch {
            throw GroupCryptoError.decryptionFailed
        }

        guard let fields = GroupTLV.parse(inner) else { throw GroupCryptoError.malformedPayload }
        var messageID: String?
        var senderSigningKey: Data?
        var senderNickname: String?
        var timestampMs: UInt64?
        var content: String?
        var signature: Data?
        for (type, value) in fields {
            switch InnerField(rawValue: type) {
            case .messageID:
                messageID = String(data: value, encoding: .utf8)
            case .senderSigningKey where value.count == 32:
                senderSigningKey = value
            case .senderNickname:
                senderNickname = String(data: value, encoding: .utf8)
            case .timestamp:
                timestampMs = GroupTLV.timestamp(from: value)
            case .content:
                content = String(data: value, encoding: .utf8)
            case .signature where value.count == 64:
                signature = value
            default:
                break
            }
        }
        guard let messageID, !messageID.isEmpty,
              let senderSigningKey,
              let senderNickname,
              let timestampMs,
              let content,
              let signature else { throw GroupCryptoError.malformedPayload }

        let signingContent = messageSigningContent(
            groupID: envelope.groupID,
            epoch: envelope.epoch,
            messageID: messageID,
            timestampMs: timestampMs,
            content: content
        )
        guard verify(signature: signature, for: signingContent, publicKey: senderSigningKey) else {
            throw GroupCryptoError.badSenderSignature
        }

        return GroupMessagePlaintext(
            messageID: messageID,
            senderSigningKey: senderSigningKey,
            senderNickname: senderNickname,
            timestampMs: timestampMs,
            content: content
        )
    }
}
