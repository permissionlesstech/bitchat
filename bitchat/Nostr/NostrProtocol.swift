import BitLogger
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
        case geohashPresence = 20001
        case deletion = 5 // NIP-09 event deletion request
        /// Sealed courier envelope parked on relays under its rotating
        /// recipient tag (`#x`). Regular (stored) kind so it survives until
        /// its NIP-40 expiration — the whole point is store-and-forward.
        case courierDrop = 1401
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
        
        // 2. Seal the rumor (encrypt to recipient) and sign it with the SENDER'S
        //    real identity key. NIP-17 requires the seal be signed by the sender
        //    so the recipient can authenticate who sent the message; signing with
        //    a throwaway key leaves DMs forgeable/impersonatable.
        let senderKey = try senderIdentity.schnorrSigningKey()
        let sealedEvent = try createSeal(
            rumor: rumor,
            recipientPubkey: recipientPubkey,
            senderKey: senderKey
        )

        // 3. Gift wrap the sealed event with a throwaway ephemeral key (the wrap
        //    layer hides the sender's identity from relays; createGiftWrap mints
        //    its own ephemeral key internally).
        let giftWrap = try createGiftWrap(
            seal: sealedEvent,
            recipientPubkey: recipientPubkey
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
            SecureLogger.error("❌ Failed to unwrap gift wrap: \(error)", category: .session)
            throw error
        }
        
        // 2. Authenticate the seal. The seal MUST be signed by the sender's real
        //    identity key (NIP-17); without this check a DM is forgeable by anyone
        //    who knows the recipient's npub. Verify the seal's own signature.
        guard seal.isValidSignature() else {
            SecureLogger.error("❌ Rejecting DM: seal signature is missing or invalid", category: .session)
            throw NostrError.invalidEvent
        }

        // 3. Open the seal
        let rumor: NostrEvent
        do {
            rumor = try openSeal(
                seal: seal,
                recipientKey: recipientIdentity.schnorrSigningKey()
            )
            // Successfully opened seal
        } catch {
            SecureLogger.error("❌ Failed to open seal: \(error)", category: .session)
            throw error
        }

        // 4. The sender claimed inside the rumor must match the key that actually
        //    signed the seal, otherwise the sender field is unauthenticated and
        //    spoofable.
        guard seal.pubkey == rumor.pubkey else {
            SecureLogger.error("❌ Rejecting DM: rumor pubkey does not match seal signer", category: .session)
            throw NostrError.invalidEvent
        }

        // Return the seal signer's pubkey as the authenticated sender.
        return (content: rumor.content, senderPubkey: seal.pubkey, timestamp: rumor.created_at)
    }

    #if DEBUG
    static func createPrivateMessageWithInvalidSealSignatureForTesting(
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
        var seal = try createSeal(
            rumor: rumor,
            recipientPubkey: recipientPubkey,
            senderKey: senderIdentity.schnorrSigningKey()
        )
        seal.sig = String(repeating: "0", count: 128)
        return try createGiftWrap(seal: seal, recipientPubkey: recipientPubkey)
    }

    static func createPrivateMessageWithMismatchedSealRumorPubkeyForTesting(
        content: String,
        recipientPubkey: String,
        rumorIdentity: NostrIdentity,
        sealSignerIdentity: NostrIdentity
    ) throws -> NostrEvent {
        let rumor = NostrEvent(
            pubkey: rumorIdentity.publicKeyHex,
            createdAt: Date(),
            kind: .dm,
            tags: [],
            content: content
        )
        let seal = try createSeal(
            rumor: rumor,
            recipientPubkey: recipientPubkey,
            senderKey: sealSignerIdentity.schnorrSigningKey()
        )
        return try createGiftWrap(seal: seal, recipientPubkey: recipientPubkey)
    }
    #endif

    /// Create a geohash-scoped ephemeral public message (kind 20000)
    static func createEphemeralGeohashEvent(
        content: String,
        geohash: String,
        senderIdentity: NostrIdentity,
        nickname: String? = nil,
        teleported: Bool = false
    ) throws -> NostrEvent {
        let event = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: Date(),
            kind: .ephemeralEvent,
            tags: ephemeralGeohashTags(geohash: geohash, nickname: nickname, teleported: teleported),
            content: content
        )
        let schnorrKey = try senderIdentity.schnorrSigningKey()
        return try event.sign(with: schnorrKey)
    }

    /// Create a kind-20000 geohash message carrying a NIP-13 proof-of-work
    /// nonce tag (see `NostrPoW`). Mining runs off the calling actor and is
    /// bounded by `NostrPoW.miningTimeCap`; when the cap hits (or the
    /// surrounding task is cancelled) the event ships at the highest
    /// committed difficulty still met, and if mining is impossible it ships
    /// unmined — sending is never blocked.
    static func createMinedEphemeralGeohashEvent(
        content: String,
        geohash: String,
        senderIdentity: NostrIdentity,
        nickname: String? = nil,
        teleported: Bool = false,
        powTargetBits: Int = NostrPoW.targetBits
    ) async throws -> NostrEvent {
        var tags = ephemeralGeohashTags(geohash: geohash, nickname: nickname, teleported: teleported)
        // Fix created_at up front: the mined nonce commits to the full
        // serialized event, so the signed event must reuse the exact value.
        let createdAt = Int(Date().timeIntervalSince1970)
        if let nonceTag = await NostrPoW.mineNonceTag(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: createdAt,
            kind: EventKind.ephemeralEvent.rawValue,
            tags: tags,
            content: content,
            targetBits: powTargetBits
        ) {
            tags.append(nonceTag)
        }
        let event = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            kind: .ephemeralEvent,
            tags: tags,
            content: content
        )
        let schnorrKey = try senderIdentity.schnorrSigningKey()
        return try event.sign(with: schnorrKey)
    }

    /// Tags for a kind-20000 geohash message (shared by the plain and mined
    /// variants).
    private static func ephemeralGeohashTags(
        geohash: String,
        nickname: String?,
        teleported: Bool
    ) -> [[String]] {
        var tags = [["g", geohash]]
        if let nickname = nickname?.trimmedOrNilIfEmpty {
            tags.append(["n", nickname])
        }
        if teleported {
            tags.append(["t", "teleport"])
        }
        return tags
    }

    /// Create a geohash presence heartbeat (kind 20001)
    /// Must contain empty content and NO nickname tag
    static func createGeohashPresenceEvent(
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

    // MARK: - Mesh bridge (rendezvous) events

    /// Create a mesh-bridge public message (kind 20000) for a geohash-cell
    /// rendezvous. The distinct `r` tag keeps bridge traffic out of geohash
    /// channel subscriptions (which filter on `#g`); `m` is
    /// `[stable ID, mesh sender ID, wire timestamp in ms]`. Element 1 is the
    /// content-stable mesh message ID (`MeshMessageIdentity`) for v1.7.0
    /// parsers, which key their dedup on `m[1]` unconditionally and need it
    /// per-message-unique. Current parsers key bridge rows by the authenticated
    /// event ID and recompute elements 2-3 only as a radio-copy hint; the mesh
    /// coordinates are public and cannot authenticate the Nostr signer.
    static func createBridgeMeshEvent(
        content: String,
        cell: String,
        senderIdentity: NostrIdentity,
        nickname: String? = nil,
        meshSenderID: String? = nil,
        meshTimestampMs: UInt64? = nil
    ) throws -> NostrEvent {
        var tags = [["r", cell]]
        if let nickname = nickname?.trimmedOrNilIfEmpty {
            tags.append(["n", nickname])
        }
        if let meshSenderID = meshSenderID?.trimmedOrNilIfEmpty, let meshTimestampMs {
            let stableID = MeshMessageIdentity.stableID(
                senderIDHex: meshSenderID,
                timestampMs: meshTimestampMs,
                content: content
            )
            tags.append(["m", stableID, meshSenderID, String(meshTimestampMs)])
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

    /// Create a mesh-bridge presence heartbeat (kind 20001) on a rendezvous
    /// cell: empty content, `r` tag only — the bridge analogue of geohash
    /// presence, counted into "people across the bridge".
    static func createBridgePresenceEvent(
        cell: String,
        senderIdentity: NostrIdentity
    ) throws -> NostrEvent {
        let event = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: Date(),
            kind: .geohashPresence,
            tags: [["r", cell]],
            content: ""
        )
        let schnorrKey = try senderIdentity.schnorrSigningKey()
        return try event.sign(with: schnorrKey)
    }

    /// Create a courier drop (kind 1401): an opaque sealed courier envelope
    /// parked on relays. `x` is the hex recipient tag the recipient (or a
    /// gateway acting for them) subscribes for; the NIP-40 expiration tracks
    /// the envelope expiry so honoring relays garbage-collect the drop. The
    /// signing identity should be a throwaway — the envelope authenticates
    /// its sender internally via Noise-X, and linking drops to a stable
    /// publisher key would leak courier traffic patterns.
    static func createCourierDropEvent(
        envelope: Data,
        recipientTagHex: String,
        expiresAt: Date,
        senderIdentity: NostrIdentity
    ) throws -> NostrEvent {
        let tags = [
            ["x", recipientTagHex],
            ["expiration", String(Int(expiresAt.timeIntervalSince1970))]
        ]
        let event = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: Date(),
            kind: .courierDrop,
            tags: tags,
            content: envelope.base64EncodedString()
        )
        let schnorrKey = try senderIdentity.schnorrSigningKey()
        return try event.sign(with: schnorrKey)
    }

    /// Create a persistent location note (kind 1: text note) tagged to a street-level geohash.
    /// An optional `expiresAt` adds a NIP-40 expiration tag so honoring relays
    /// drop the note in step with a bridged board post's expiry.
    static func createGeohashTextNote(
        content: String,
        geohash: String,
        senderIdentity: NostrIdentity,
        nickname: String? = nil,
        expiresAt: Date? = nil,
        urgent: Bool = false
    ) throws -> NostrEvent {
        var tags = [["g", geohash]]
        if let nickname = nickname?.trimmedOrNilIfEmpty {
            tags.append(["n", nickname])
        }
        if let expiresAt {
            tags.append(["expiration", String(Int(expiresAt.timeIntervalSince1970))])
        }
        if urgent {
            tags.append(["t", "urgent"])
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

    /// Create a NIP-09 deletion request for one of our own events. Relays that
    /// honor NIP-09 drop the referenced event; it must be signed by the same
    /// key that signed the original.
    static func createDeleteEvent(
        ofEventID eventID: String,
        senderIdentity: NostrIdentity
    ) throws -> NostrEvent {
        let event = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: Date(),
            kind: .deletion,
            tags: [["e", eventID]],
            content: ""
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
        recipientPubkey: String
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
        return "v2:" + Base64URLCoding.encode(combined)
    }
    
    private static func decrypt(
        ciphertext: String,
        senderPubkey: String,
        recipientKey: P256K.Schnorr.PrivateKey
    ) throws -> String {
        // Expect NIP-44 v2 format
        guard ciphertext.hasPrefix("v2:") else { throw NostrError.invalidCiphertext }
        let encoded = String(ciphertext.dropFirst(3))
        guard let data = Base64URLCoding.decode(encoded),
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

    /// Validate that the event ID and Schnorr signature match the content and pubkey.
    /// Returns false when the signature is missing, malformed, or does not verify.
    func isValidSignature() -> Bool {
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
    
    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum NostrError: Error {
    case invalidPublicKey
    case invalidEvent
    case invalidCiphertext
}

// MARK: - NIP-44 v2 helpers (XChaCha20-Poly1305)

private extension NostrProtocol {
    static func deriveNIP44V2Key(from sharedSecretData: Data) throws -> Data {
        let derivedKey = HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecretData),
            salt: Data(),
            info: Data("nip44-v2".utf8),
            outputByteCount: 32
        )
        return derivedKey.withUnsafeBytes { Data($0) }
    }
}
