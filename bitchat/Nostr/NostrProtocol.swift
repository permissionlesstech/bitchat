import Foundation
import CryptoKit
import P256K
import Security

// Note: This file depends on Data extension from BinaryEncodingUtils.swift
// Make sure BinaryEncodingUtils.swift is included in the target

/// NIP-17 Protocol Implementation for Private Direct Messages
struct NostrProtocol {
    
    /// Nostr event kinds
    enum EventKind: Int {
        case metadata = 0
        case textNote = 1
        case dm = 14 // NIP-17 DM rumor kind
        case seal = 13 // NIP-17 sealed event
        case giftWrap = 1059 // NIP-59 gift wrap
        case ephemeralEvent = 20000
    }
    
    /// Create a NIP-17 private message
    static func createPrivateMessage(
        content: String,
        recipientPubkey: String,
        senderIdentity: NostrIdentity
    ) throws -> NostrEvent {
        
        // Creating private message
        
        // 1. Create the rumor (unsigned event)
        let rumor = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: Date(),
            kind: .dm, // NIP-17: DM rumor kind 14
            tags: [],
            content: content
        )
        
        // 2. Create ephemeral key for this message
        let ephemeralKey = try P256K.Schnorr.PrivateKey()
        // Created ephemeral key for seal
        
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
        
        // Created gift wrap
        
        return giftWrap
    }
    
    /// Decrypt a received NIP-17 message
    /// Returns the content, sender pubkey, and the actual message timestamp (not the randomized gift wrap timestamp)
    static func decryptPrivateMessage(
        giftWrap: NostrEvent,
        recipientIdentity: NostrIdentity
    ) throws -> (content: String, senderPubkey: String, timestamp: Int) {
        
        // Starting decryption
        
        // 1. Unwrap the gift wrap
        let seal: NostrEvent
        do {
            seal = try unwrapGiftWrap(
                giftWrap: giftWrap,
                recipientKey: recipientIdentity.schnorrSigningKey()
            )
            // Successfully unwrapped gift wrap
        } catch {
            SecureLogger.log("❌ Failed to unwrap gift wrap: \(error)", 
                            category: SecureLogger.session, level: .error)
            throw error
        }
        
        // 2. Open the seal
        let rumor: NostrEvent
        do {
            rumor = try openSeal(
                seal: seal,
                recipientKey: recipientIdentity.schnorrSigningKey()
            )
            // Successfully opened seal
        } catch {
            SecureLogger.log("❌ Failed to open seal: \(error)", 
                            category: SecureLogger.session, level: .error)
            throw error
        }
        
        return (content: rumor.content, senderPubkey: rumor.pubkey, timestamp: rumor.created_at)
    }

    /// Create a geohash-scoped ephemeral public message (kind 20000)
    static func createEphemeralGeohashEvent(
        content: String,
        geohash: String,
        senderIdentity: NostrIdentity,
        nickname: String? = nil,
        teleported: Bool = false
    ) throws -> NostrEvent {
        var tags = [["g", geohash]]
        if let nickname = nickname, !nickname.isEmpty {
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
        
        // Sign the seal with the sender's Schnorr private key
        return try seal.sign(with: senderKey)
    }
    
    private static func createGiftWrap(
        seal: NostrEvent,
        recipientPubkey: String,
        senderKey: P256K.Schnorr.PrivateKey  // This is the ephemeral key used for the seal
    ) throws -> NostrEvent {
        
        let sealJSON = try seal.jsonString()
        
        // Create new ephemeral key for gift wrap
        let wrapKey = try P256K.Schnorr.PrivateKey()
        // Creating gift wrap with ephemeral key
        
        // Encrypt the seal with the new ephemeral key (not the seal's key)
        let encrypted = try encrypt(
            plaintext: sealJSON,
            recipientPubkey: recipientPubkey,
            senderKey: wrapKey  // Use the gift wrap ephemeral key
        )
        
        let giftWrap = NostrEvent(
            pubkey: Data(wrapKey.xonly.bytes).hexEncodedString(),
            createdAt: randomizedTimestamp(),
            kind: .giftWrap,
            tags: [["p", recipientPubkey]], // Tag recipient
            content: encrypted
        )
        
        // Sign the gift wrap with the wrap Schnorr private key
        return try giftWrap.sign(with: wrapKey)
    }
    
    private static func unwrapGiftWrap(
        giftWrap: NostrEvent,
        recipientKey: P256K.Schnorr.PrivateKey
    ) throws -> NostrEvent {
        
        // Unwrapping gift wrap
        
        let decrypted = try decrypt(
            ciphertext: giftWrap.content,
            senderPubkey: giftWrap.pubkey,
            recipientKey: recipientKey
        )
        
        guard let data = decrypted.data(using: .utf8),
              let sealDict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NostrError.invalidEvent
        }
        
        let seal = try NostrEvent(from: sealDict)
        // Unwrapped seal
        
        return seal
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
        
        // Encrypting message (NIP-44 v2: XChaCha20-Poly1305, versioned)
        
        // Derive shared secret
        let sharedSecret = try deriveSharedSecret(
            privateKey: senderKey,
            publicKey: recipientPubkeyData
        )
        // Derive NIP-44 v2 symmetric key (HKDF-SHA256 with label in info)
        let key = try deriveNIP44V2Key(from: sharedSecret)
        
        // 24-byte random nonce for XChaCha20-Poly1305
        var nonce24 = Data(count: 24)
        _ = nonce24.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 24, ptr.baseAddress!)
        }
        
        let pt = Data(plaintext.utf8)
        let sealed = try XChaCha20Poly1305Compat.seal(plaintext: pt, key: key, nonce24: nonce24)
        
        // v2: base64url(nonce24 || ciphertext || tag)
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
        // Expect NIP-44 v2 format
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

        // Try decryption with even-Y then odd-Y when sender pubkey is x-only
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

        // If 32 bytes (x-only) try both parities, otherwise single try
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
        // Deriving shared secret
        
        // Convert Schnorr private key to KeyAgreement private key
        let keyAgreementPrivateKey = try P256K.KeyAgreement.PrivateKey(
            dataRepresentation: privateKey.dataRepresentation
        )
        
        // Create KeyAgreement public key from the public key data
        // For ECDH, we need the full 33-byte compressed public key (with 0x02 or 0x03 prefix)
        var fullPublicKey = Data()
        if publicKey.count == 32 { // X-only key, need to add prefix
            // For x-only keys in Nostr/Bitcoin, we need to try both possible Y coordinates
            // First try with even Y (0x02 prefix)
            fullPublicKey.append(0x02)
            fullPublicKey.append(publicKey)
            // Trying with even Y coordinate
        } else {
            fullPublicKey = publicKey
        }
        
        // Try to create public key, if it fails with even Y, try odd Y
        let keyAgreementPublicKey: P256K.KeyAgreement.PublicKey
        do {
            keyAgreementPublicKey = try P256K.KeyAgreement.PublicKey(
                dataRepresentation: fullPublicKey,
                format: .compressed
            )
        } catch {
            if publicKey.count == 32 {
                // Try with odd Y (0x03 prefix)
                // Even Y failed, trying odd Y
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
        
        // Perform ECDH
        let sharedSecret = try keyAgreementPrivateKey.sharedSecretFromKeyAgreement(
            with: keyAgreementPublicKey,
            format: .compressed
        )
        
        // Convert SharedSecret to Data
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }
        // ECDH shared secret derived
        
        // Return raw ECDH shared secret; HKDF is applied by deriveNIP44V2Key
        return sharedSecretData
    }
    
    // Direct version that doesn't try to add prefixes
    private static func deriveSharedSecretDirect(
        privateKey: P256K.Schnorr.PrivateKey,
        publicKey: Data
    ) throws -> Data {
        // Direct shared secret calculation
        
        // Convert Schnorr private key to KeyAgreement private key
        let keyAgreementPrivateKey = try P256K.KeyAgreement.PrivateKey(
            dataRepresentation: privateKey.dataRepresentation
        )
        
        // Use the public key as-is (should already have prefix)
        let keyAgreementPublicKey = try P256K.KeyAgreement.PublicKey(
            dataRepresentation: publicKey,
            format: .compressed
        )
        
        // Perform ECDH
        let sharedSecret = try keyAgreementPrivateKey.sharedSecretFromKeyAgreement(
            with: keyAgreementPublicKey,
            format: .compressed
        )
        
        // Convert SharedSecret to Data
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }
        
        // Return raw ECDH shared secret; HKDF is applied by deriveNIP44V2Key
        return sharedSecretData
    }
    
    private static func randomizedTimestamp() -> Date {
        // Add random offset to current time for privacy
        // This prevents timing correlation attacks while the actual message timestamp
        // is preserved in the encrypted rumor
        let offset = TimeInterval.random(in: -900...900) // +/- 15 minutes
        let now = Date()
        let randomized = now.addingTimeInterval(offset)
        
        // Log with explicit UTC and local time for debugging
        let formatter = DateFormatter()
        //
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        
        formatter.timeZone = TimeZone.current
        
        // Timestamp randomized for privacy
        
        return randomized
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
        content: String
    ) {
        self.pubkey = pubkey
        self.created_at = Int(createdAt.timeIntervalSince1970)
        self.kind = kind.rawValue
        self.tags = tags
        self.content = content
        self.sig = nil
        self.id = "" // Will be set during signing
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
    
    func sign(with key: P256K.Schnorr.PrivateKey) throws -> NostrEvent {
        let (eventId, eventIdHash) = try calculateEventId()
        
        // Sign with Schnorr (BIP-340)
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
        let hash = CryptoKit.SHA256.hash(data: data)
        let hashData = Data(hash)
        let hashHex = hash.compactMap { String(format: "%02x", $0) }.joined()
        return (hashHex, hashData)
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
