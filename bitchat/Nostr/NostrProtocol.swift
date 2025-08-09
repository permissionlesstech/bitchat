import Foundation
import CryptoKit
// TODO: Add secp256k1 library for Nostr support
// Options: https://github.com/GigaBitcoin/secp256k1.swift
// or: https://github.com/Boilertalk/secp256k1.swift
// import secp256k1

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
        // TODO: Implement with secp256k1 library
        // This function requires secp256k1 for Schnorr signatures
        // Temporarily returning a placeholder event
        
        return NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: Date(),
            kind: .textNote,
            tags: [],
            content: content
        )
    }
    
    /// Decrypt a received NIP-17 message
    static func decryptPrivateMessage(
        giftWrap: NostrEvent,
        recipientIdentity: NostrIdentity
    ) throws -> (content: String, senderPubkey: String) {
        // TODO: Implement with secp256k1 library
        // This function requires secp256k1 for Schnorr signatures
        // Temporarily returning placeholder data
        
        throw NostrError.notImplemented("Decryption requires secp256k1 library")
    }
    
    // MARK: - Private Methods
    
    // TODO: Implement with secp256k1 library
    // private static func createSeal(
    //     rumor: NostrEvent,
    //     recipientPubkey: String,
    //     senderKey: secp256k1.Schnorr.PrivateKey
    // ) throws -> NostrEvent {
    //     Implementation requires secp256k1
    // }
    
    // TODO: Implement with secp256k1 library
    // private static func createGiftWrap(
    //     seal: NostrEvent,
    //     recipientPubkey: String,
    //     senderKey: secp256k1.Schnorr.PrivateKey
    // ) throws -> NostrEvent {
    //     Implementation requires secp256k1
    // }
    
    // TODO: Implement with secp256k1 library
    // private static func unwrapGiftWrap(
    //     giftWrap: NostrEvent,
    //     recipientKey: secp256k1.Schnorr.PrivateKey
    // ) throws -> NostrEvent {
    //     Implementation requires secp256k1
    // }
    
    // TODO: Implement with secp256k1 library
    // private static func openSeal(
    //     seal: NostrEvent,
    //     recipientKey: secp256k1.Schnorr.PrivateKey
    // ) throws -> NostrEvent {
    //     Implementation requires secp256k1
    // }
    
    // MARK: - Encryption (NIP-44 style)
    
    // TODO: Implement with secp256k1 library
    private static func encrypt(
        plaintext: String,
        recipientPubkey: String,
        senderKey: Any // P256K.Schnorr.PrivateKey
    ) throws -> String {
        
        guard Data(hexString: recipientPubkey) != nil else {
            throw NostrError.invalidPublicKey
        }
        
        // let _ = Data(senderKey.xonly.bytes).hexEncodedString()
        // Encrypting message
        
        // Derive shared secret
        // TODO: Implement with secp256k1
        // let sharedSecret = try deriveSharedSecret(
        //     privateKey: senderKey,
        //     publicKey: recipientPubkeyData
        // )
        let sharedSecret = Data(repeating: 0, count: 32) // Placeholder
        
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
    
    // TODO: Implement with secp256k1 library
    private static func decrypt(
        ciphertext: String,
        senderPubkey: String,
        recipientKey: Any // P256K.Schnorr.PrivateKey
    ) throws -> String {
        
        // Decrypting message
        
        guard let data = Data(base64Encoded: ciphertext),
              Data(hexString: senderPubkey) != nil else {
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
            // TODO: Implement with secp256k1
            // sharedSecret = try deriveSharedSecret(
            //     privateKey: recipientKey,
            //     publicKey: senderPubkeyData
            // )
            sharedSecret = Data(repeating: 0, count: 32) // Placeholder
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
                // TODO: Implement with secp256k1
                // AES-GCM decryption failed, would try alternate Y coordinate
                // but that requires deriveSharedSecretDirect which needs secp256k1
                throw error
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
    
    // TODO: Implement with secp256k1 library
    private static func deriveSharedSecret(
        privateKey: Any, // P256K.Schnorr.PrivateKey,
        publicKey: Data
    ) throws -> Data {
        // Deriving shared secret
        
        // Convert Schnorr private key to KeyAgreement private key
        // let keyAgreementPrivateKey = try P256K.KeyAgreement.PrivateKey(
        //     dataRepresentation: privateKey.dataRepresentation
        // )
        throw NostrError.notImplemented("deriveSharedSecret requires secp256k1")
        
        // Unreachable code commented out to avoid warnings
        // Will be re-enabled when secp256k1 library is added
        /*
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
        
        // TODO: Implement with secp256k1
        // Try to create public key, if it fails with even Y, try odd Y
        // let keyAgreementPublicKey: secp256k1.KeyAgreement.PublicKey
        // ... implementation requires secp256k1
        
        // Placeholder - will not work until secp256k1 is added
        let sharedSecret = Data()
        
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
        */
    }
    
    // TODO: Implement with secp256k1 library
    // Direct version that doesn't try to add prefixes
    // private static func deriveSharedSecretDirect(
    //     privateKey: secp256k1.Schnorr.PrivateKey,
    //     publicKey: Data
    // ) throws -> Data {
    //     Implementation requires secp256k1
    // }
    
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
    
    // TODO: Implement with secp256k1 library
    // func sign(with key: secp256k1.Signing.PrivateKey) throws -> NostrEvent {
    //     Implementation requires secp256k1
    // }
    
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
    case notImplemented(String)
}