import Foundation
import CryptoKit
import P256K

// Note: This file depends on Data extension from BinaryEncodingUtils.swift
// Make sure BinaryEncodingUtils.swift is included in the target

/// NIP-17 Protocol Implementation for Private Direct Messages
struct NostrProtocol {
    
    /// Nostr event kinds
    enum EventKind: Int {
        case metadata = 0
        case textNote = 1
        case seal = 13 // NIP-17 sealed event
        case giftWrap = 1059 // NIP-17 gift wrap
        case ephemeralEvent = 20000
    }
    
    /// Create a NIP-17 private message
    static func createPrivateMessage(
        content: String,
        recipientPubkey: String,
        senderIdentity: NostrIdentity
    ) throws -> NostrEvent {
        
        // 1. Create the rumor (unsigned event)
        let rumor = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: Date(),
            kind: .textNote,
            tags: [],
            content: content
        )
        
        // 2. Create ephemeral key for this message
        let ephemeralKey = try P256K.Signing.PrivateKey()
        
        // 3. Seal the rumor (encrypt to recipient)
        let sealedEvent = try createSeal(
            rumor: rumor,
            recipientPubkey: recipientPubkey,
            senderKey: ephemeralKey
        )
        
        // 4. Gift wrap the sealed event (encrypt to recipient again)
        let giftWrap = try createGiftWrap(
            seal: sealedEvent,
            recipientPubkey: recipientPubkey,
            senderKey: ephemeralKey
        )
        
        return giftWrap
    }
    
    /// Decrypt a received NIP-17 message
    static func decryptPrivateMessage(
        giftWrap: NostrEvent,
        recipientIdentity: NostrIdentity
    ) throws -> (content: String, senderPubkey: String) {
        
        // 1. Unwrap the gift wrap
        let seal = try unwrapGiftWrap(
            giftWrap: giftWrap,
            recipientKey: recipientIdentity.signingKey()
        )
        
        // 2. Open the seal
        let rumor = try openSeal(
            seal: seal,
            recipientKey: recipientIdentity.signingKey()
        )
        
        return (content: rumor.content, senderPubkey: rumor.pubkey)
    }
    
    // MARK: - Private Methods
    
    private static func createSeal(
        rumor: NostrEvent,
        recipientPubkey: String,
        senderKey: P256K.Signing.PrivateKey
    ) throws -> NostrEvent {
        
        let rumorJSON = try rumor.jsonString()
        let encrypted = try encrypt(
            plaintext: rumorJSON,
            recipientPubkey: recipientPubkey,
            senderKey: senderKey
        )
        
        let seal = NostrEvent(
            pubkey: senderKey.publicKey.dataRepresentation.hexEncodedString(),
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
        senderKey: P256K.Signing.PrivateKey
    ) throws -> NostrEvent {
        
        let sealJSON = try seal.jsonString()
        let encrypted = try encrypt(
            plaintext: sealJSON,
            recipientPubkey: recipientPubkey,
            senderKey: senderKey
        )
        
        // Create new ephemeral key for gift wrap
        let wrapKey = try P256K.Signing.PrivateKey()
        
        let giftWrap = NostrEvent(
            pubkey: wrapKey.publicKey.dataRepresentation.hexEncodedString(),
            createdAt: randomizedTimestamp(),
            kind: .giftWrap,
            tags: [["p", recipientPubkey]], // Tag recipient
            content: encrypted,
            expiration: Date().addingTimeInterval(86400 * 30) // 30 days
        )
        
        return try giftWrap.sign(with: wrapKey)
    }
    
    private static func unwrapGiftWrap(
        giftWrap: NostrEvent,
        recipientKey: P256K.Signing.PrivateKey
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
        recipientKey: P256K.Signing.PrivateKey
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
    
    // MARK: - Encryption (NIP-44 style)
    
    private static func encrypt(
        plaintext: String,
        recipientPubkey: String,
        senderKey: P256K.Signing.PrivateKey
    ) throws -> String {
        
        guard let recipientPubkeyData = Data(hexString: recipientPubkey) else {
            throw NostrError.invalidPublicKey
        }
        
        // Derive shared secret
        let sharedSecret = try deriveSharedSecret(
            privateKey: senderKey,
            publicKey: recipientPubkeyData
        )
        
        // Generate nonce
        let nonce = AES.GCM.Nonce()
        
        // Encrypt
        let sealed = try AES.GCM.seal(
            plaintext.data(using: .utf8)!,
            using: SymmetricKey(data: sharedSecret),
            nonce: nonce
        )
        
        // Combine nonce + ciphertext + tag
        var result = Data()
        result.append(nonce.withUnsafeBytes { Data($0) })
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
        
        return result.base64EncodedString()
    }
    
    private static func decrypt(
        ciphertext: String,
        senderPubkey: String,
        recipientKey: P256K.Signing.PrivateKey
    ) throws -> String {
        
        guard let data = Data(base64Encoded: ciphertext),
              let senderPubkeyData = Data(hexString: senderPubkey) else {
            throw NostrError.invalidCiphertext
        }
        
        // Extract components
        let nonceData = data.prefix(12)
        let ciphertextData = data.dropFirst(12).dropLast(16)
        let tagData = data.suffix(16)
        
        // Derive shared secret
        let sharedSecret = try deriveSharedSecret(
            privateKey: recipientKey,
            publicKey: senderPubkeyData
        )
        
        // Decrypt
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData),
            ciphertext: ciphertextData,
            tag: tagData
        )
        
        let decrypted = try AES.GCM.open(
            sealedBox,
            using: SymmetricKey(data: sharedSecret)
        )
        
        return String(data: decrypted, encoding: .utf8) ?? ""
    }
    
    private static func deriveSharedSecret(
        privateKey: P256K.Signing.PrivateKey,
        publicKey: Data
    ) throws -> Data {
        // ECDH key agreement
        // Note: This is a placeholder implementation
        // The actual P256K library should provide proper ECDH methods
        // For now, we'll use a hash of both keys as a temporary shared secret
        
        var combinedData = Data()
        combinedData.append(privateKey.publicKey.dataRepresentation)
        combinedData.append(publicKey)
        
        let hash = CryptoKit.SHA256.hash(data: combinedData)
        
        // Derive key using HKDF
        let sharedSecret = HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(hash)),
            salt: "nip44-v2".data(using: .utf8)!,
            info: Data(),
            outputByteCount: 32
        )
        
        return sharedSecret.withUnsafeBytes { Data(Array($0)) }
    }
    
    private static func randomizedTimestamp() -> Date {
        // Add random offset to current time for privacy
        let offset = TimeInterval.random(in: -900...900) // +/- 15 minutes
        return Date().addingTimeInterval(offset)
    }
}

/// Nostr Event structure
struct NostrEvent: Codable {
    var id: String
    let pubkey: String
    let created_at: Int
    let kind: Int
    let tags: [[String]]
    let content: String
    var sig: String?
    
    init(
        pubkey: String,
        createdAt: Date,
        kind: NostrProtocol.EventKind,
        tags: [[String]],
        content: String,
        expiration: Date? = nil
    ) {
        self.pubkey = pubkey
        self.created_at = Int(createdAt.timeIntervalSince1970)
        self.kind = kind.rawValue
        self.tags = tags
        self.content = content
        self.sig = nil
        self.id = "" // Will be set during signing
        
        // Add expiration tag if provided
        if let exp = expiration {
            var mutableTags = tags
            mutableTags.append(["expiration", String(Int(exp.timeIntervalSince1970))])
        }
    }
    
    init(from dict: [String: Any]) throws {
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
    
    func sign(with key: P256K.Signing.PrivateKey) throws -> NostrEvent {
        let eventId = try calculateEventId()
        // Sign the event ID with the private key
        let eventIdData = Data(eventId.utf8)
        let signature = try key.signature(for: eventIdData)
        let signatureHex = try signature.derRepresentation.hexEncodedString()
        
        var signed = self
        signed.id = eventId
        signed.sig = signatureHex
        return signed
    }
    
    private func calculateEventId() throws -> String {
        let serialized = [
            0,
            pubkey,
            created_at,
            kind,
            tags,
            content
        ] as [Any]
        
        let data = try JSONSerialization.data(withJSONObject: serialized, options: [.withoutEscapingSlashes])
        let hash = CryptoKit.SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum NostrError: Error {
    case invalidPublicKey
    case invalidPrivateKey
    case invalidEvent
    case invalidCiphertext
    case signingFailed
    case encryptionFailed
}