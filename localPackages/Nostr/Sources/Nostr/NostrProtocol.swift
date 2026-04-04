import BitFoundation
import BitLogger
import Foundation
import CryptoKit
import P256K
import Security

/// NIP-17 Protocol Implementation for Private Direct Messages
public struct NostrProtocol {

    /// Nostr event kinds
    public enum EventKind: Int, Sendable {
        case metadata = 0
        case textNote = 1
        case dm = 14 // NIP-17 DM rumor kind
        case seal = 13 // NIP-17 sealed event
        case giftWrap = 1059 // NIP-59 gift wrap
        case ephemeralEvent = 20000
        case geohashPresence = 20001
    }

    /// Create a NIP-17 private message
    public static func createPrivateMessage(
        content: String,
        recipientPubkey: String,
        senderIdentity: NostrIdentity
    ) throws -> NostrEvent {
        let rumor = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: Date(),
            kind: .dm,
            tags: [],
            content: content
        )

        let ephemeralKey = try P256K.Schnorr.PrivateKey()

        let sealedEvent = try createSeal(
            rumor: rumor,
            recipientPubkey: recipientPubkey,
            senderKey: ephemeralKey
        )

        let giftWrap = try createGiftWrap(
            seal: sealedEvent,
            recipientPubkey: recipientPubkey,
            senderKey: ephemeralKey
        )

        return giftWrap
    }

    /// Decrypt a received NIP-17 message
    /// Returns the content, sender pubkey, and the actual message timestamp (not the randomized gift wrap timestamp)
    public static func decryptPrivateMessage(
        giftWrap: NostrEvent,
        recipientIdentity: NostrIdentity
    ) throws -> (content: String, senderPubkey: String, timestamp: Int) {
        let seal: NostrEvent
        do {
            seal = try unwrapGiftWrap(
                giftWrap: giftWrap,
                recipientKey: recipientIdentity.schnorrSigningKey()
            )
        } catch {
            SecureLogger.error("❌ Failed to unwrap gift wrap: \(error)", category: .session)
            throw error
        }

        let rumor: NostrEvent
        do {
            rumor = try openSeal(
                seal: seal,
                recipientKey: recipientIdentity.schnorrSigningKey()
            )
        } catch {
            SecureLogger.error("❌ Failed to open seal: \(error)", category: .session)
            throw error
        }

        return (content: rumor.content, senderPubkey: rumor.pubkey, timestamp: rumor.created_at)
    }

    /// Create a geohash-scoped ephemeral public message (kind 20000)
    public static func createEphemeralGeohashEvent(
        content: String,
        geohash: String,
        senderIdentity: NostrIdentity,
        nickname: String? = nil,
        teleported: Bool = false
    ) throws -> NostrEvent {
        var tags = [["g", geohash]]
        if let nickname = nickname?.trimmedOrNilIfEmpty {
            tags.append(["n", nickname])
        }
        if teleported {
            tags.append(["t", "teleport"])
        }
        let event = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: Date(),
            kind: .ephemeralEvent,
            tags: tags,
            content: content
        )
        let schnorrKey = try senderIdentity.schnorrSigningKey()
        return try event.sign(with: schnorrKey)
    }

    /// Create a geohash presence heartbeat (kind 20001)
    /// Must contain empty content and NO nickname tag
    public static func createGeohashPresenceEvent(
        geohash: String,
        senderIdentity: NostrIdentity
    ) throws -> NostrEvent {
        let tags = [["g", geohash]]
        let event = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: Date(),
            kind: .geohashPresence,
            tags: tags,
            content: ""
        )
        let schnorrKey = try senderIdentity.schnorrSigningKey()
        return try event.sign(with: schnorrKey)
    }

    /// Create a persistent location note (kind 1: text note) tagged to a street-level geohash.
    public static func createGeohashTextNote(
        content: String,
        geohash: String,
        senderIdentity: NostrIdentity,
        nickname: String? = nil
    ) throws -> NostrEvent {
        var tags = [["g", geohash]]
        if let nickname = nickname?.trimmedOrNilIfEmpty {
            tags.append(["n", nickname])
        }
        let event = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: Date(),
            kind: .textNote,
            tags: tags,
            content: content
        )
        let schnorrKey = try senderIdentity.schnorrSigningKey()
        return try event.sign(with: schnorrKey)
    }

    // MARK: - Private Methods

    private static func createSeal(
        rumor: NostrEvent,
        recipientPubkey: String,
        senderKey: P256K.Schnorr.PrivateKey
    ) throws -> NostrEvent {
        let rumorJSON = try rumor.jsonString()
        let encrypted = try encrypt(
            plaintext: rumorJSON,
            recipientPubkey: recipientPubkey,
            senderKey: senderKey
        )

        let seal = NostrEvent(
            pubkey: Data(senderKey.xonly.bytes).hexEncodedString(),
            createdAt: randomizedTimestamp(),
            kind: .seal,
            tags: [],
            content: encrypted
        )

        return try seal.sign(with: senderKey)
    }

    private static func createGiftWrap(
        seal: NostrEvent,
        recipientPubkey: String,
        senderKey: P256K.Schnorr.PrivateKey
    ) throws -> NostrEvent {
        let sealJSON = try seal.jsonString()
        let wrapKey = try P256K.Schnorr.PrivateKey()

        let encrypted = try encrypt(
            plaintext: sealJSON,
            recipientPubkey: recipientPubkey,
            senderKey: wrapKey
        )

        let giftWrap = NostrEvent(
            pubkey: Data(wrapKey.xonly.bytes).hexEncodedString(),
            createdAt: randomizedTimestamp(),
            kind: .giftWrap,
            tags: [["p", recipientPubkey]],
            content: encrypted
        )

        return try giftWrap.sign(with: wrapKey)
    }

    private static func unwrapGiftWrap(
        giftWrap: NostrEvent,
        recipientKey: P256K.Schnorr.PrivateKey
    ) throws -> NostrEvent {
        let decrypted = try decrypt(
            ciphertext: giftWrap.content,
            senderPubkey: giftWrap.pubkey,
            recipientKey: recipientKey
        )

        guard let data = decrypted.data(using: .utf8),
              let sealDict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NostrError.invalidEvent
        }

        return try NostrEvent(from: sealDict)
    }

    private static func openSeal(
        seal: NostrEvent,
        recipientKey: P256K.Schnorr.PrivateKey
    ) throws -> NostrEvent {
        let decrypted = try decrypt(
            ciphertext: seal.content,
            senderPubkey: seal.pubkey,
            recipientKey: recipientKey
        )

        guard let data = decrypted.data(using: .utf8),
              let rumorDict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NostrError.invalidEvent
        }

        return try NostrEvent(from: rumorDict)
    }

    // MARK: - Encryption (NIP-44 v2)

    private static func encrypt(
        plaintext: String,
        recipientPubkey: String,
        senderKey: P256K.Schnorr.PrivateKey
    ) throws -> String {
        guard let recipientPubkeyData = Data(hexString: recipientPubkey) else {
            throw NostrError.invalidPublicKey
        }

        let sharedSecret = try deriveSharedSecret(
            privateKey: senderKey,
            publicKey: recipientPubkeyData
        )
        let key = try deriveNIP44V2Key(from: sharedSecret)

        var nonce24 = Data(count: 24)
        _ = nonce24.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 24, ptr.baseAddress!)
        }

        let pt = Data(plaintext.utf8)
        let sealed = try XChaCha20Poly1305Compat.seal(plaintext: pt, key: key, nonce24: nonce24)

        var combined = Data()
        combined.append(nonce24)
        combined.append(sealed.ciphertext)
        combined.append(sealed.tag)
        return "v2:" + base64URLEncode(combined)
    }

    private static func decrypt(
        ciphertext: String,
        senderPubkey: String,
        recipientKey: P256K.Schnorr.PrivateKey
    ) throws -> String {
        guard ciphertext.hasPrefix("v2:") else { throw NostrError.invalidCiphertext }
        let encoded = String(ciphertext.dropFirst(3))
        guard let data = base64URLDecode(encoded),
              data.count > (24 + 16),
              let senderPubkeyData = Data(hexString: senderPubkey) else {
            throw NostrError.invalidCiphertext
        }

        let nonce24 = data.prefix(24)
        let rest = data.dropFirst(24)
        let tag = rest.suffix(16)
        let ct = rest.dropLast(16)

        func attemptDecrypt(using pubKeyData: Data) throws -> Data {
            let ss = try deriveSharedSecret(privateKey: recipientKey, publicKey: pubKeyData)
            let key = try deriveNIP44V2Key(from: ss)
            return try XChaCha20Poly1305Compat.open(
                ciphertext: Data(ct),
                tag: Data(tag),
                key: key,
                nonce24: Data(nonce24)
            )
        }

        if senderPubkeyData.count == 32 {
            let even = Data([0x02]) + senderPubkeyData
            if let pt = try? attemptDecrypt(using: even) {
                return String(data: pt, encoding: .utf8) ?? ""
            }
            let odd = Data([0x03]) + senderPubkeyData
            let pt = try attemptDecrypt(using: odd)
            return String(data: pt, encoding: .utf8) ?? ""
        } else {
            let pt = try attemptDecrypt(using: senderPubkeyData)
            return String(data: pt, encoding: .utf8) ?? ""
        }
    }

    private static func deriveSharedSecret(
        privateKey: P256K.Schnorr.PrivateKey,
        publicKey: Data
    ) throws -> Data {
        let keyAgreementPrivateKey = try P256K.KeyAgreement.PrivateKey(
            dataRepresentation: privateKey.dataRepresentation
        )

        var fullPublicKey = Data()
        if publicKey.count == 32 {
            fullPublicKey.append(0x02)
            fullPublicKey.append(publicKey)
        } else {
            fullPublicKey = publicKey
        }

        let keyAgreementPublicKey: P256K.KeyAgreement.PublicKey
        do {
            keyAgreementPublicKey = try P256K.KeyAgreement.PublicKey(
                dataRepresentation: fullPublicKey,
                format: .compressed
            )
        } catch {
            if publicKey.count == 32 {
                fullPublicKey = Data()
                fullPublicKey.append(0x03)
                fullPublicKey.append(publicKey)
                keyAgreementPublicKey = try P256K.KeyAgreement.PublicKey(
                    dataRepresentation: fullPublicKey,
                    format: .compressed
                )
            } else {
                throw error
            }
        }

        let sharedSecret = try keyAgreementPrivateKey.sharedSecretFromKeyAgreement(
            with: keyAgreementPublicKey,
            format: .compressed
        )

        return sharedSecret.withUnsafeBytes { Data($0) }
    }

    private static func randomizedTimestamp() -> Date {
        let offset = TimeInterval.random(in: -900...900)
        return Date().addingTimeInterval(offset)
    }
}

/// Nostr Event structure
public struct NostrEvent: Codable, Sendable {
    public var id: String
    public let pubkey: String
    public let created_at: Int
    public let kind: Int
    public let tags: [[String]]
    public let content: String
    public var sig: String?

    public init(
        pubkey: String,
        createdAt: Date,
        kind: NostrProtocol.EventKind,
        tags: [[String]],
        content: String
    ) {
        self.pubkey = pubkey
        self.created_at = Int(createdAt.timeIntervalSince1970)
        self.kind = kind.rawValue
        self.tags = tags
        self.content = content
        self.sig = nil
        self.id = ""
    }

    public init(from dict: [String: Any]) throws {
        guard let pubkey = dict["pubkey"] as? String,
              let createdAt = dict["created_at"] as? Int,
              let kind = dict["kind"] as? Int,
              let tags = dict["tags"] as? [[String]],
              let content = dict["content"] as? String else {
            throw NostrError.invalidEvent
        }

        self.id = dict["id"] as? String ?? ""
        self.pubkey = pubkey
        self.created_at = createdAt
        self.kind = kind
        self.tags = tags
        self.content = content
        self.sig = dict["sig"] as? String
    }

    public func sign(with key: P256K.Schnorr.PrivateKey) throws -> NostrEvent {
        let (eventId, eventIdHash) = try calculateEventId()

        var messageBytes = [UInt8](eventIdHash)
        var auxRand = [UInt8](repeating: 0, count: 32)
        _ = auxRand.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        let schnorrSignature = try key.signature(message: &messageBytes, auxiliaryRand: &auxRand)

        let signatureHex = schnorrSignature.dataRepresentation.hexEncodedString()

        var signed = self
        signed.id = eventId
        signed.sig = signatureHex
        return signed
    }

    /// Validate that the event ID and Schnorr signature match the content and pubkey.
    /// Returns false when the signature is missing, malformed, or does not verify.
    public func isValidSignature() -> Bool {
        guard let sig = sig,
              let sigData = Data(hexString: sig),
              let pubData = Data(hexString: pubkey),
              sigData.count == 64,
              pubData.count == 32,
              let signature = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: sigData),
              let (expectedId, eventHash) = try? calculateEventId(),
              expectedId == id
        else {
            return false
        }

        var messageBytes = [UInt8](eventHash)
        let xonly = P256K.Schnorr.XonlyKey(dataRepresentation: pubData)
        return xonly.isValid(signature, for: &messageBytes)
    }

    private func calculateEventId() throws -> (String, Data) {
        let serialized = [
            0,
            pubkey,
            created_at,
            kind,
            tags,
            content
        ] as [Any]

        let data = try JSONSerialization.data(withJSONObject: serialized, options: [.withoutEscapingSlashes])
        return (data.sha256Fingerprint(), data.sha256Hash())
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public enum NostrError: Error, Sendable {
    case invalidPublicKey
    case invalidPrivateKey
    case invalidEvent
    case invalidCiphertext
    case signingFailed
    case encryptionFailed
}

// MARK: - NIP-44 v2 helpers (XChaCha20-Poly1305 + base64url)

private extension NostrProtocol {
    static func base64URLEncode(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var str = s
        let pad = (4 - (str.count % 4)) % 4
        if pad > 0 { str += String(repeating: "=", count: pad) }
        str = str.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: str)
    }

    static func deriveNIP44V2Key(from sharedSecretData: Data) throws -> Data {
        let derivedKey = HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecretData),
            salt: Data(),
            info: "nip44-v2".data(using: .utf8)!,
            outputByteCount: 32
        )
        return derivedKey.withUnsafeBytes { Data($0) }
    }
}
