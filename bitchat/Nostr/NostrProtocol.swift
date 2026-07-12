import Foundation
import CryptoKit
import P256K
import Security

// Note: This file depends on Data extension from BinaryEncodingUtils.swift
// Make sure BinaryEncodingUtils.swift is included in the target

/// BitChat's private-envelope protocol transported over Nostr relays.
///
/// This is deliberately BitChat-specific and is not NIP-17, NIP-44, or NIP-59.
/// It uses Nostr events and secp256k1 identities, but its XChaCha20-Poly1305
/// payload layout is proprietary and interoperates only with BitChat clients.
struct NostrProtocol {
    
    /// Nostr event kinds
    enum EventKind: Int {
        case metadata = 0
        case textNote = 1
        // Compatibility for BitChat releases that incorrectly emitted the
        // proprietary payload under standard NIP kinds. Kind 1059 continues
        // to be published and read until a coordinated cross-platform release
        // explicitly removes it; all three legacy layers remain readable.
        case legacyNIP59Seal = 13
        case legacyNIP17DirectMessage = 14
        case legacyNIP59GiftWrap = 1059
        // Provisional BitChat-specific regular event kinds. These are not
        // formally reserved by the Nostr kind registry. Only
        // `privateEnvelope` is published; message and seal exist solely
        // inside ciphertext.
        case privateEnvelope = 1402
        case privateSeal = 1403
        case privateMessage = 1404
        case ephemeralEvent = 20000
        case geohashPresence = 20001
        case deletion = 5 // NIP-09 event deletion request
        /// Sealed courier envelope parked on relays under its rotating
        /// recipient tag (`#x`). Regular (stored) kind so it survives until
        /// its NIP-40 expiration — the whole point is store-and-forward.
        case courierDrop = 1401
    }

    /// Prefix for BitChat private-envelope ciphertext. The suffix is
    /// base64url(nonce24 || ciphertext || poly1305Tag).
    static let privateEnvelopeContentPrefix = "bitchat-pm-v1:"

    /// Bound work before Base64 decoding either encrypted layer. Current
    /// private messages are normally only a few KiB; 64 KiB leaves ample
    /// migration headroom without allowing an addressed relay event to drive
    /// unbounded allocation.
    static let maximumPrivateEnvelopeCiphertextBytes = 64 * 1024

    /// Bound the inner authenticated message JSON before allocation/parsing.
    static let maximumPrivateEnvelopePlaintextBytes = 32 * 1024

    /// The outer authenticated seal JSON contains a Base64-encoded encrypted
    /// copy of the inner JSON, so it needs expansion headroom of its own. Keep
    /// the layer-specific cap below the public ciphertext ceiling.
    private static let maximumPrivateEnvelopeSealPlaintextBytes = 48 * 1024

    /// New clients subscribe to the provisional BitChat-specific kind and the
    /// compatibility legacy kind so both sides of a rolling rollout can
    /// recover stored messages. Do not remove kind 1059 here until all
    /// supported iOS and Android releases have migrated.
    static let acceptedPrivateEnvelopeKinds = [
        EventKind.privateEnvelope.rawValue,
        EventKind.legacyNIP59GiftWrap.rawValue
    ]

    private enum PrivateEnvelopeWireFormat {
        case bitchatV1
        case legacyMislabelledV2

        init?(outerKind: Int) {
            switch outerKind {
            case EventKind.privateEnvelope.rawValue:
                self = .bitchatV1
            case EventKind.legacyNIP59GiftWrap.rawValue:
                self = .legacyMislabelledV2
            default:
                return nil
            }
        }

        var messageKind: EventKind {
            switch self {
            case .bitchatV1: .privateMessage
            case .legacyMislabelledV2: .legacyNIP17DirectMessage
            }
        }

        var sealKind: EventKind {
            switch self {
            case .bitchatV1: .privateSeal
            case .legacyMislabelledV2: .legacyNIP59Seal
            }
        }

        var envelopeKind: EventKind {
            switch self {
            case .bitchatV1: .privateEnvelope
            case .legacyMislabelledV2: .legacyNIP59GiftWrap
            }
        }

        var contentPrefix: String {
            switch self {
            case .bitchatV1: NostrProtocol.privateEnvelopeContentPrefix
            case .legacyMislabelledV2: "v2:"
            }
        }

        var hkdfSalt: Data {
            switch self {
            case .bitchatV1: Data("bitchat-private-envelope-v1".utf8)
            case .legacyMislabelledV2: Data()
            }
        }

        var hkdfInfo: Data {
            switch self {
            case .bitchatV1: Data()
            case .legacyMislabelledV2: Data("nip44-v2".utf8)
            }
        }
    }
    
    /// Create a BitChat private envelope for relay transport.
    static func createPrivateEnvelope(
        content: String,
        recipientPubkey: String,
        senderIdentity: NostrIdentity
    ) throws -> NostrEvent {
        try createPrivateEnvelope(
            content: content,
            recipientPubkey: recipientPubkey,
            senderIdentity: senderIdentity,
            format: .bitchatV1
        )
    }

    /// Events to publish for one logical private payload. The primary
    /// BitChat-specific format is always first and a legacy copy follows for
    /// clients that still subscribe only to kind 1059. There is deliberately
    /// no date-based cutoff: removal requires a coordinated iOS/Android
    /// release after supported old clients have migrated. Both encrypt the
    /// exact same embedded BitChat payload, so receive-side logical-payload
    /// dedup collapses the pair.
    static func createPrivateEnvelopePublicationBatch(
        content: String,
        recipientPubkey: String,
        senderIdentity: NostrIdentity
    ) throws -> [NostrEvent] {
        let primary = try createPrivateEnvelope(
            content: content,
            recipientPubkey: recipientPubkey,
            senderIdentity: senderIdentity
        )
        let compatibilityCopy = try createPrivateEnvelope(
            content: content,
            recipientPubkey: recipientPubkey,
            senderIdentity: senderIdentity,
            format: .legacyMislabelledV2
        )
        return [primary, compatibilityCopy]
    }

    private static func createPrivateEnvelope(
        content: String,
        recipientPubkey: String,
        senderIdentity: NostrIdentity,
        format: PrivateEnvelopeWireFormat,
        messageTags: [[String]] = []
    ) throws -> NostrEvent {
        // 1. Create the unsigned inner BitChat message.
        let message = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: Date(),
            kind: format.messageKind,
            tags: messageTags,
            content: content
        )
        
        // 2. Encrypt the message to the recipient and sign the private seal
        // with the sender's stable Nostr identity for sender authentication.
        let senderKey = try senderIdentity.schnorrSigningKey()
        let sealedEvent = try createPrivateSeal(
            message: message,
            recipientPubkey: recipientPubkey,
            senderKey: senderKey,
            format: format
        )

        // 3. Encrypt the seal under a one-time key so the public envelope does
        // not reveal the stable sender identity.
        return try createPrivateEnvelopeEvent(
            seal: sealedEvent,
            recipientPubkey: recipientPubkey,
            format: format
        )
    }
    
    /// Decrypt a BitChat private envelope. Legacy proprietary envelopes that
    /// older BitChat releases placed under kinds 1059/13/14 are accepted only
    /// through the format-isolated receive path.
    static func decryptPrivateEnvelope(
        envelope: NostrEvent,
        recipientIdentity: NostrIdentity
    ) throws -> (content: String, senderPubkey: String, timestamp: Int) {
        let layers = try decodePrivateEnvelopeLayers(
            envelope: envelope,
            recipientIdentity: recipientIdentity
        )
        return (
            content: layers.message.content,
            senderPubkey: layers.seal.pubkey,
            timestamp: layers.message.created_at
        )
    }

    #if DEBUG
    static func createPrivateEnvelopeWithInvalidSealSignatureForTesting(
        content: String,
        recipientPubkey: String,
        senderIdentity: NostrIdentity
    ) throws -> NostrEvent {
        let format = PrivateEnvelopeWireFormat.bitchatV1
        let message = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: Date(),
            kind: format.messageKind,
            tags: [],
            content: content
        )
        var seal = try createPrivateSeal(
            message: message,
            recipientPubkey: recipientPubkey,
            senderKey: senderIdentity.schnorrSigningKey(),
            format: format
        )
        seal.sig = String(repeating: "0", count: 128)
        return try createPrivateEnvelopeEvent(
            seal: seal,
            recipientPubkey: recipientPubkey,
            format: format
        )
    }

    static func createPrivateEnvelopeWithMismatchedSealMessagePubkeyForTesting(
        content: String,
        recipientPubkey: String,
        messageIdentity: NostrIdentity,
        sealSignerIdentity: NostrIdentity
    ) throws -> NostrEvent {
        let format = PrivateEnvelopeWireFormat.bitchatV1
        let message = NostrEvent(
            pubkey: messageIdentity.publicKeyHex,
            createdAt: Date(),
            kind: format.messageKind,
            tags: [],
            content: content
        )
        let seal = try createPrivateSeal(
            message: message,
            recipientPubkey: recipientPubkey,
            senderKey: sealSignerIdentity.schnorrSigningKey(),
            format: format
        )
        return try createPrivateEnvelopeEvent(
            seal: seal,
            recipientPubkey: recipientPubkey,
            format: format
        )
    }

    static func createPrivateEnvelopeWithInnerTagsForTesting(
        content: String,
        recipientPubkey: String,
        senderIdentity: NostrIdentity,
        innerMessageTags: [[String]]
    ) throws -> NostrEvent {
        try createPrivateEnvelope(
            content: content,
            recipientPubkey: recipientPubkey,
            senderIdentity: senderIdentity,
            format: .bitchatV1,
            messageTags: innerMessageTags
        )
    }

    static func createLegacyPrivateEnvelopeForTesting(
        content: String,
        recipientPubkey: String,
        senderIdentity: NostrIdentity,
        innerMessageTags: [[String]] = []
    ) throws -> NostrEvent {
        // Current Android legacy envelopes use exactly one recipient `p` tag
        // on the unsigned inner kind-14 event; released iOS envelopes use no
        // inner tags. Tests pass the Android shape explicitly so this helper
        // cannot silently make the production encoder depend on that quirk.
        try createPrivateEnvelope(
            content: content,
            recipientPubkey: recipientPubkey,
            senderIdentity: senderIdentity,
            format: .legacyMislabelledV2,
            messageTags: innerMessageTags
        )
    }

    static func decodePrivateEnvelopeLayersForTesting(
        envelope: NostrEvent,
        recipientIdentity: NostrIdentity
    ) throws -> (seal: NostrEvent, message: NostrEvent) {
        try decodePrivateEnvelopeLayers(
            envelope: envelope,
            recipientIdentity: recipientIdentity
        )
    }

    static func decodePrivateEnvelopeEventJSONForTesting(_ json: String) throws -> NostrEvent {
        try decodePrivateEnvelopeEventJSON(json)
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
    
    private static func createPrivateSeal(
        message: NostrEvent,
        recipientPubkey: String,
        senderKey: P256K.Schnorr.PrivateKey,
        format: PrivateEnvelopeWireFormat
    ) throws -> NostrEvent {
        let encrypted = try encrypt(
            plaintext: message.jsonString(),
            recipientPubkey: recipientPubkey,
            senderKey: senderKey,
            format: format,
            maximumPlaintextBytes: maximumPrivateEnvelopePlaintextBytes
        )

        let seal = NostrEvent(
            pubkey: Data(senderKey.xonly.bytes).hexEncodedString(),
            createdAt: randomizedPastTimestamp(),
            kind: format.sealKind,
            tags: [],
            content: encrypted
        )
        return try seal.sign(with: senderKey)
    }

    private static func createPrivateEnvelopeEvent(
        seal: NostrEvent,
        recipientPubkey: String,
        format: PrivateEnvelopeWireFormat
    ) throws -> NostrEvent {
        // A fresh signing/encryption key for every public envelope keeps the
        // stable sender identity inside ciphertext.
        let envelopeKey = try P256K.Schnorr.PrivateKey()
        let encrypted = try encrypt(
            plaintext: seal.jsonString(),
            recipientPubkey: recipientPubkey,
            senderKey: envelopeKey,
            format: format,
            maximumPlaintextBytes: maximumPrivateEnvelopeSealPlaintextBytes
        )

        let envelope = NostrEvent(
            pubkey: Data(envelopeKey.xonly.bytes).hexEncodedString(),
            createdAt: randomizedPastTimestamp(),
            kind: format.envelopeKind,
            tags: [["p", recipientPubkey]],
            content: encrypted
        )
        return try envelope.sign(with: envelopeKey)
    }

    private static func decodePrivateEnvelopeLayers(
        envelope: NostrEvent,
        recipientIdentity: NostrIdentity
    ) throws -> (seal: NostrEvent, message: NostrEvent) {
        guard envelope.content.utf8.count <= maximumPrivateEnvelopeCiphertextBytes else {
            throw NostrError.invalidCiphertext
        }
        guard let format = PrivateEnvelopeWireFormat(outerKind: envelope.kind),
              envelope.tags == [["p", recipientIdentity.publicKeyHex]],
              envelope.isValidSignature() else {
            throw NostrError.invalidEvent
        }

        let recipientKey = try recipientIdentity.schnorrSigningKey()
        let sealJSON = try decrypt(
            ciphertext: envelope.content,
            senderPubkey: envelope.pubkey,
            recipientKey: recipientKey,
            format: format,
            maximumPlaintextBytes: maximumPrivateEnvelopeSealPlaintextBytes
        )
        let seal = try decodePrivateEnvelopeEventJSON(
            sealJSON,
            maximumBytes: maximumPrivateEnvelopeSealPlaintextBytes
        )
        guard seal.kind == format.sealKind.rawValue,
              seal.tags.isEmpty,
              seal.isValidSignature() else {
            throw NostrError.invalidEvent
        }

        let messageJSON = try decrypt(
            ciphertext: seal.content,
            senderPubkey: seal.pubkey,
            recipientKey: recipientKey,
            format: format,
            maximumPlaintextBytes: maximumPrivateEnvelopePlaintextBytes
        )
        let message = try decodePrivateEnvelopeEventJSON(
            messageJSON,
            maximumBytes: maximumPrivateEnvelopePlaintextBytes
        )

        // The inner message is intentionally unsigned; sender authentication
        // comes from the seal. Bind its claimed sender and custom kind to that
        // authenticated layer before exposing content.
        guard message.kind == format.messageKind.rawValue,
              validInnerMessageTags(
                message.tags,
                format: format,
                recipientPubkey: recipientIdentity.publicKeyHex
              ),
              message.sig == nil,
              seal.pubkey == message.pubkey else {
            throw NostrError.invalidEvent
        }

        return (seal, message)
    }

    /// Released iOS legacy envelopes used no inner tags, while current
    /// Android legacy envelopes use exactly the authenticated recipient tag.
    /// Accept only those two historical shapes for kind 1059. The new kind
    /// 1402 format remains strict and rejects every inner tag.
    private static func validInnerMessageTags(
        _ tags: [[String]],
        format: PrivateEnvelopeWireFormat,
        recipientPubkey: String
    ) -> Bool {
        switch format {
        case .bitchatV1:
            return tags.isEmpty
        case .legacyMislabelledV2:
            return tags.isEmpty || tags == [["p", recipientPubkey]]
        }
    }

    private static func decodePrivateEnvelopeEventJSON(
        _ json: String,
        maximumBytes: Int = maximumPrivateEnvelopePlaintextBytes
    ) throws -> NostrEvent {
        // Check UTF-8 size before allocating Data or invoking the general JSON
        // parser. `decrypt` enforces the same cap on authenticated bytes; this
        // local guard keeps the parser boundary explicit and independently
        // testable.
        guard json.utf8.count <= maximumBytes else {
            throw NostrError.invalidCiphertext
        }
        guard let data = json.data(using: .utf8),
              let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NostrError.invalidEvent
        }
        return try NostrEvent(from: dictionary)
    }

    // MARK: - BitChat private-envelope encryption

    private static func encrypt(
        plaintext: String,
        recipientPubkey: String,
        senderKey: P256K.Schnorr.PrivateKey,
        format: PrivateEnvelopeWireFormat,
        maximumPlaintextBytes: Int
    ) throws -> String {
        guard let recipientPubkeyData = Data(hexString: recipientPubkey) else {
            throw NostrError.invalidPublicKey
        }

        let sharedSecret = try deriveSharedSecret(
            privateKey: senderKey,
            publicKey: recipientPubkeyData
        )
        let key = derivePrivateEnvelopeKey(from: sharedSecret, format: format)

        var nonce24 = Data(count: 24)
        let randomStatus = nonce24.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 24, ptr.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw NostrError.cryptographicFailure
        }

        let plaintextData = Data(plaintext.utf8)
        guard plaintextData.count <= maximumPlaintextBytes else {
            throw NostrError.invalidCiphertext
        }
        let sealed = try XChaCha20Poly1305Compat.seal(
            plaintext: plaintextData,
            key: key,
            nonce24: nonce24
        )

        var combined = Data()
        combined.append(nonce24)
        combined.append(sealed.ciphertext)
        combined.append(sealed.tag)
        return format.contentPrefix + Base64URLCoding.encode(combined)
    }

    private static func decrypt(
        ciphertext: String,
        senderPubkey: String,
        recipientKey: P256K.Schnorr.PrivateKey,
        format: PrivateEnvelopeWireFormat,
        maximumPlaintextBytes: Int
    ) throws -> String {
        guard ciphertext.utf8.count <= maximumPrivateEnvelopeCiphertextBytes,
              ciphertext.hasPrefix(format.contentPrefix) else {
            throw NostrError.invalidCiphertext
        }
        let encoded = String(ciphertext.dropFirst(format.contentPrefix.count))
        guard let data = Base64URLCoding.decode(encoded),
              data.count > (24 + 16),
              let senderPubkeyData = Data(hexString: senderPubkey) else {
            throw NostrError.invalidCiphertext
        }

        let nonce24 = data.prefix(24)
        let rest = data.dropFirst(24)
        let tag = rest.suffix(16)
        let ciphertextBytes = rest.dropLast(16)

        func attemptDecrypt(using publicKeyData: Data) throws -> Data {
            let sharedSecret = try deriveSharedSecret(
                privateKey: recipientKey,
                publicKey: publicKeyData
            )
            let key = derivePrivateEnvelopeKey(from: sharedSecret, format: format)
            return try XChaCha20Poly1305Compat.open(
                ciphertext: Data(ciphertextBytes),
                tag: Data(tag),
                key: key,
                nonce24: Data(nonce24)
            )
        }

        let plaintext: Data
        if senderPubkeyData.count == 32 {
            let evenKey = Data([0x02]) + senderPubkeyData
            if let opened = try? attemptDecrypt(using: evenKey) {
                plaintext = opened
            } else {
                let oddKey = Data([0x03]) + senderPubkeyData
                plaintext = try attemptDecrypt(using: oddKey)
            }
        } else {
            plaintext = try attemptDecrypt(using: senderPubkeyData)
        }

        guard plaintext.count <= maximumPlaintextBytes,
              let decoded = String(data: plaintext, encoding: .utf8) else {
            throw NostrError.invalidCiphertext
        }
        return decoded
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
        
        // Return raw ECDH shared secret; the wire-format-specific HKDF is
        // applied by derivePrivateEnvelopeKey.
        return sharedSecretData
    }
    
    private static func randomizedPastTimestamp() -> Date {
        // Keep public timestamps in the past: future-dated events are rejected
        // by some relays. The actual message timestamp remains encrypted.
        Date().addingTimeInterval(
            -TimeInterval.random(in: 0...TransportConfig.nostrPrivateEnvelopeTimestampFuzzSeconds)
        )
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
    case cryptographicFailure
}

// MARK: - BitChat private-envelope key derivation

private extension NostrProtocol {
    private static func derivePrivateEnvelopeKey(
        from sharedSecretData: Data,
        format: PrivateEnvelopeWireFormat
    ) -> Data {
        let derivedKey = HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecretData),
            salt: format.hkdfSalt,
            info: format.hkdfInfo,
            outputByteCount: 32
        )
        return derivedKey.withUnsafeBytes { Data($0) }
    }
}
