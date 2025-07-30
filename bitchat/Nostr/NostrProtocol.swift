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
        
        // Creating private message
        
        // 1. Create the rumor (unsigned event)
        let rumor = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: Date(),
            kind: .textNote,
            tags: [],
            content: content
        )
        
        // 2. Create ephemeral key for this message
        let ephemeralKey = try P256K.Schnorr.PrivateKey()
        let _ = Data(ephemeralKey.xonly.bytes).hexEncodedString()
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
    static func decryptPrivateMessage(
        giftWrap: NostrEvent,
        recipientIdentity: NostrIdentity
    ) throws -> (content: String, senderPubkey: String) {
        
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
        
        return (content: rumor.content, senderPubkey: rumor.pubkey)
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
        
        // Convert to P256K.Signing.PrivateKey for signing (temporary until we update sign method)
        let signingKey = try P256K.Signing.PrivateKey(dataRepresentation: senderKey.dataRepresentation)
        return try seal.sign(with: signingKey)
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
        
        // Convert to P256K.Signing.PrivateKey for signing (temporary until we update sign method)
        let signingKey = try P256K.Signing.PrivateKey(dataRepresentation: wrapKey.dataRepresentation)
        return try giftWrap.sign(with: signingKey)
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
    
    // MARK: - Encryption (NIP-44 style)
    
    private static func encrypt(
        plaintext: String,
        recipientPubkey: String,
        senderKey: P256K.Schnorr.PrivateKey
    ) throws -> String {
        
        guard let recipientPubkeyData = Data(hexString: recipientPubkey) else {
            throw NostrError.invalidPublicKey
        }
        
        let _ = Data(senderKey.xonly.bytes).hexEncodedString()
        // Encrypting message
        
        // Derive shared secret
        let sharedSecret = try deriveSharedSecret(
            privateKey: senderKey,
            publicKey: recipientPubkeyData
        )
        
        // Derived shared secret
        
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
        recipientKey: P256K.Schnorr.PrivateKey
    ) throws -> String {
        
        // Decrypting message
        
        guard let data = Data(base64Encoded: ciphertext),
              let senderPubkeyData = Data(hexString: senderPubkey) else {
            SecureLogger.log("❌ Invalid ciphertext or sender pubkey format", 
                            category: SecureLogger.session, level: .error)
            throw NostrError.invalidCiphertext
        }
        
        // Ciphertext data parsed
        
        // Extract components
        let nonceData = data.prefix(12)
        let ciphertextData = data.dropFirst(12).dropLast(16)
        let tagData = data.suffix(16)
        
        // Components parsed
        
        // Derive shared secret - try with default Y coordinate first
        var sharedSecret: Data
        var decrypted: Data? = nil
        
        do {
            sharedSecret = try deriveSharedSecret(
                privateKey: recipientKey,
                publicKey: senderPubkeyData
            )
            // Derived shared secret with first Y coordinate
            
            // Try to decrypt
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: ciphertextData,
                tag: tagData
            )
            
            do {
                decrypted = try AES.GCM.open(
                    sealedBox,
                    using: SymmetricKey(data: sharedSecret)
                )
                // AES-GCM decryption successful
            } catch {
                // AES-GCM decryption failed, trying alternate
                
                // If the sender pubkey is x-only (32 bytes), try the other Y coordinate
                if senderPubkeyData.count == 32 {
                    // Trying alternate Y coordinate
                    
                    // Force deriveSharedSecret to use odd Y by manipulating the data
                    var altPubkey = Data()
                    altPubkey.append(0x03) // Force odd Y
                    altPubkey.append(senderPubkeyData)
                    
                    sharedSecret = try deriveSharedSecretDirect(
                        privateKey: recipientKey,
                        publicKey: altPubkey
                    )
                    
                    decrypted = try AES.GCM.open(
                        sealedBox,
                        using: SymmetricKey(data: sharedSecret)
                    )
                    // AES-GCM decryption successful with alternate Y
                } else {
                    throw error
                }
            }
        } catch {
            SecureLogger.log("❌ Failed to derive shared secret or decrypt: \(error)", 
                            category: SecureLogger.session, level: .error)
            throw error
        }
        
        guard let finalDecrypted = decrypted else {
            throw NostrError.encryptionFailed
        }
        
        return String(data: finalDecrypted, encoding: .utf8) ?? ""
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
        
        // Derive key using HKDF for NIP-44 v2
        let derivedKey = HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecretData),
            salt: "nip44-v2".data(using: .utf8)!,
            info: Data(),
            outputByteCount: 32
        )
        
        let result = derivedKey.withUnsafeBytes { Data($0) }
        // Final derived key ready
        return result
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
        
        // Derive key using HKDF for NIP-44 v2
        let derivedKey = HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecretData),
            salt: "nip44-v2".data(using: .utf8)!,
            info: Data(),
            outputByteCount: 32
        )
        
        return derivedKey.withUnsafeBytes { Data($0) }
    }
    
    private static func randomizedTimestamp() -> Date {
        // Add random offset to current time for privacy
        // TEMPORARY: Reduced range to debug timestamp issue
        let offset = TimeInterval.random(in: -60...60) // +/- 1 minute (was +/- 15 minutes)
        let now = Date()
        let randomized = now.addingTimeInterval(offset)
        
        // Log with explicit UTC and local time for debugging
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        let _ = formatter.string(from: now)
        let _ = formatter.string(from: randomized)
        
        formatter.timeZone = TimeZone.current
        let _ = formatter.string(from: now)
        let _ = formatter.string(from: randomized)
        
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
    
    func sign(with key: P256K.Signing.PrivateKey) throws -> NostrEvent {
        let (eventId, eventIdHash) = try calculateEventId()
        
        // Convert to Schnorr key for Nostr signing
        let schnorrKey = try P256K.Schnorr.PrivateKey(dataRepresentation: key.dataRepresentation)
        
        // Sign with Schnorr
        var messageBytes = [UInt8](eventIdHash)
        var auxRand = [UInt8](repeating: 0, count: 32) // Zero auxiliary randomness for deterministic signing
        let schnorrSignature = try schnorrKey.signature(message: &messageBytes, auxiliaryRand: &auxRand)
        
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