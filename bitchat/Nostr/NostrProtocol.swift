import BitLogger
import BitSecp256k1
import Foundation
import CryptoKit
import Security

// Note: This file depends on Data extension from BinaryEncodingUtils.swift
// Make sure BinaryEncodingUtils.swift is included in the target

/// BitChat's private-envelope protocol transported over Nostr relays.
///
/// This construction is deliberately BitChat-specific and is **not** NIP-17,
/// NIP-44, or NIP-59 compatible, even though it historically reuses those
/// NIPs' kind numbers (1059/13/14) and a `v2:` content prefix. It uses Nostr
/// events and secp256k1 identities, but the XChaCha20-Poly1305 payload layout
/// and key derivation are proprietary and interoperate only with BitChat
/// clients.
struct NostrProtocol {

    /// Nostr event kinds
    enum EventKind: Int {
        case metadata = 0 // NIP-01 user profile metadata
        case textNote = 1
        // BitChat's proprietary private-envelope layers. These reuse the
        // NIP-17/NIP-59 kind numbers (14/13/1059) for historical reasons, but
        // the encrypted payloads are BitChat-specific and not NIP-compatible.
        case dm = 14 // unsigned inner message (inside ciphertext)
        case seal = 13 // sender-signed seal (inside ciphertext)
        case giftWrap = 1059 // public outer envelope (one-time key)
        case ephemeralEvent = 20000
        case geohashPresence = 20001
        case deletion = 5 // NIP-09 event deletion request
        case reaction = 7 // NIP-25 reaction
        case blossomAuth = 24242 // BUD-01/02 Blossom upload authorization
        /// Sealed courier envelope parked on relays under its rotating
        /// recipient tag (`#x`). Regular (stored) kind so it survives until
        /// its NIP-40 expiration — the whole point is store-and-forward.
        case courierDrop = 1401
    }

    /// Bound work before Base64-decoding either encrypted layer of an inbound
    /// private envelope, and before parsing each decrypted nested JSON layer.
    /// Real envelopes are normally a few KiB; 64 KiB leaves ample headroom
    /// without letting an addressed relay event drive unbounded allocation.
    static let maximumPrivateEnvelopeCiphertextBytes = 64 * 1024

    /// Create a BitChat private envelope for relay transport (outer kind 1059).
    static func createPrivateMessage(
        content: String,
        recipientPubkey: String,
        senderIdentity: NostrIdentity
    ) throws -> NostrEvent {
        try createPrivateMessage(
            content: content,
            recipientPubkey: recipientPubkey,
            senderIdentity: senderIdentity,
            messageTags: []
        )
    }

    private static func createPrivateMessage(
        content: String,
        recipientPubkey: String,
        senderIdentity: NostrIdentity,
        messageTags: [[String]]
    ) throws -> NostrEvent {
        // 1. Create the rumor (unsigned inner event)
        let rumor = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: Date(),
            kind: .dm,
            tags: messageTags,
            content: content
        )

        // 2. Seal the rumor (encrypt to recipient) and sign it with the SENDER'S
        //    real identity key so the recipient can authenticate who sent the
        //    message; signing with a throwaway key leaves DMs
        //    forgeable/impersonatable.
        let senderKey = try senderIdentity.schnorrSigningKey()
        let sealedEvent = try createSeal(
            rumor: rumor,
            recipientPubkey: recipientPubkey,
            senderKey: senderKey
        )

        // 3. Wrap the sealed event with a throwaway ephemeral key (the wrap
        //    layer hides the sender's identity from relays; createGiftWrap mints
        //    its own ephemeral key internally).
        let giftWrap = try createGiftWrap(
            seal: sealedEvent,
            recipientPubkey: recipientPubkey
        )

        return giftWrap
    }

    /// Decrypt a received BitChat private envelope.
    /// Returns the content, sender pubkey, and the actual message timestamp (not the randomized outer timestamp)
    static func decryptPrivateMessage(
        giftWrap: NostrEvent,
        recipientIdentity: NostrIdentity,
        outerSignatureAlreadyVerified: Bool = false
    ) throws -> (content: String, senderPubkey: String, timestamp: Int) {

        // 0. Validate the untrusted outer envelope before any decryption work.
        //    Every BitChat client (released iOS and current Android) publishes
        //    exactly one outer recipient `p` tag on a validly signed kind-1059
        //    wrap; anything else is malformed or misbound.
        guard giftWrap.content.utf8.count <= maximumPrivateEnvelopeCiphertextBytes else {
            SecureLogger.error("❌ Rejecting DM: oversized outer envelope ciphertext", category: .session)
            throw NostrError.invalidCiphertext
        }
        guard giftWrap.kind == EventKind.giftWrap.rawValue,
              giftWrap.tags == [["p", recipientIdentity.publicKeyHex]],
              (outerSignatureAlreadyVerified || giftWrap.isValidSignature()) else {
            SecureLogger.error("❌ Rejecting DM: malformed or misbound outer envelope", category: .session)
            throw NostrError.invalidEvent
        }

        let recipientKey = try recipientIdentity.schnorrSigningKey()

        // 1. Unwrap the gift wrap
        let seal: NostrEvent
        do {
            seal = try unwrapGiftWrap(
                giftWrap: giftWrap,
                recipientKey: recipientKey
            )
            // Successfully unwrapped gift wrap
        } catch {
            SecureLogger.error("❌ Failed to unwrap gift wrap: \(error)", category: .session)
            throw error
        }
        
        // 2. Authenticate the seal. The seal MUST be signed by the sender's real
        //    identity key; without this check a DM is forgeable by anyone who
        //    knows the recipient's npub. Every BitChat sender emits a tagless
        //    kind-13 seal, so bind the decrypted layer to that exact shape.
        guard seal.kind == EventKind.seal.rawValue,
              seal.tags.isEmpty,
              seal.isValidSignature() else {
            SecureLogger.error("❌ Rejecting DM: seal is malformed or its signature is missing/invalid", category: .session)
            throw NostrError.invalidEvent
        }

        // 3. Open the seal
        let rumor: NostrEvent
        do {
            rumor = try openSeal(
                seal: seal,
                recipientKey: recipientKey
            )
            // Successfully opened seal
        } catch {
            SecureLogger.error("❌ Failed to open seal: \(error)", category: .session)
            throw error
        }

        // 4. The rumor is intentionally unsigned; sender authentication comes
        //    from the seal. The sender claimed inside the rumor must match the
        //    key that actually signed the seal, otherwise the sender field is
        //    unauthenticated and spoofable. Also bind the inner kind and tag
        //    shape to what BitChat clients actually emit.
        guard rumor.kind == EventKind.dm.rawValue,
              validInnerMessageTags(rumor.tags, recipientPubkey: recipientIdentity.publicKeyHex),
              rumor.sig == nil,
              seal.pubkey == rumor.pubkey else {
            SecureLogger.error("❌ Rejecting DM: rumor is malformed or does not match seal signer", category: .session)
            throw NostrError.invalidEvent
        }

        // Return the seal signer's pubkey as the authenticated sender.
        return (content: rumor.content, senderPubkey: seal.pubkey, timestamp: rumor.created_at)
    }

    /// Released iOS envelopes use no inner tags, while current Android
    /// envelopes place exactly the authenticated recipient's `p` tag on the
    /// unsigned inner event. Accept only those two historical shapes;
    /// alternate recipients, duplicate tags, and extra tags are rejected.
    private static func validInnerMessageTags(
        _ tags: [[String]],
        recipientPubkey: String
    ) -> Bool {
        tags.isEmpty || tags == [["p", recipientPubkey]]
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

    /// Reproduces historical wire shapes (current Android places exactly one
    /// recipient `p` tag on the unsigned inner event) without making the
    /// production encoder depend on that quirk.
    static func createPrivateMessageWithInnerTagsForTesting(
        content: String,
        recipientPubkey: String,
        senderIdentity: NostrIdentity,
        innerMessageTags: [[String]]
    ) throws -> NostrEvent {
        try createPrivateMessage(
            content: content,
            recipientPubkey: recipientPubkey,
            senderIdentity: senderIdentity,
            messageTags: innerMessageTags
        )
    }
    #endif

    /// Create a geohash-scoped ephemeral public message (kind 20000).
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

    /// Tags for a kind-20000 geohash message.
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

    /// NIP-10 thread reference extracted from or written to a kind-1 note's
    /// `e` and `p` tags.
    struct ThreadReference: Equatable, Sendable {
        /// Event ID of the thread root post.
        let rootEventID: String
        /// Event ID of the direct parent when replying to a reply; nil (or
        /// equal to `rootEventID`) for a direct reply to the root post.
        let replyEventID: String?
        /// Pubkey hex of the author being replied to (`p` tag), if known.
        let replyAuthorPubkey: String?

        init(rootEventID: String, replyEventID: String? = nil, replyAuthorPubkey: String? = nil) {
            self.rootEventID = rootEventID.lowercased()
            let normalizedReply = replyEventID?.lowercased()
            self.replyEventID = (normalizedReply == self.rootEventID) ? nil : normalizedReply
            self.replyAuthorPubkey = replyAuthorPubkey?.lowercased()
        }
    }

    /// NIP-92 `imeta` attachment metadata for a Blossom content-addressed blob.
    /// Strictly requires HTTPS and a 64-char SHA-256 hash so receivers can
    /// verify downloaded bytes before decoding or displaying.
    struct MediaAttachment: Equatable, Hashable, Sendable, Identifiable {
        let url: URL
        let mimeType: String
        let sha256Hex: String
        let sizeBytes: Int?
        let dimensions: String?

        var id: String { "\(sha256Hex)|\(url.absoluteString)" }
    }

    static let maxAttachmentsPerNote = 4

    /// Encodes a `MediaAttachment` as a NIP-92 `imeta` tag.
    static func imetaTag(for attachment: MediaAttachment) -> [String] {
        var fields = [
            "imeta",
            "url \(attachment.url.absoluteString)",
            "m \(attachment.mimeType)",
            "x \(attachment.sha256Hex.lowercased())"
        ]
        if let size = attachment.sizeBytes, size > 0 {
            fields.append("size \(size)")
        }
        if let dim = attachment.dimensions?.trimmedOrNilIfEmpty {
            fields.append("dim \(dim)")
        }
        return fields
    }

    /// Parses up to `maxAttachmentsPerNote` validated NIP-92 `imeta` tags.
    /// Rejects non-HTTPS URLs, local/private hosts, and attachments missing a
    /// valid 64-character SHA-256 digest (`x`).
    static func parseMediaAttachments(from tags: [[String]]) -> [MediaAttachment] {
        var attachments: [MediaAttachment] = []
        var seenHashes = Set<String>()

        for tag in tags where tag.count >= 2 && tag[0].lowercased() == "imeta" {
            var urlString: String?
            var mimeType = "image/jpeg"
            var sha256Hex: String?
            var sizeBytes: Int?
            var dimensions: String?

            for field in tag.dropFirst() {
                guard let spaceIdx = field.firstIndex(of: " ") else { continue }
                let key = field[..<spaceIdx].lowercased()
                let value = String(field[field.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                switch key {
                case "url":
                    urlString = value
                case "m":
                    if value.count <= 64 { mimeType = value.lowercased() }
                case "x":
                    let lower = value.lowercased()
                    if lower.count == 64, isValidHexIdentifier(lower) {
                        sha256Hex = lower
                    }
                case "size":
                    if let parsed = Int(value), parsed > 0 { sizeBytes = parsed }
                case "dim":
                    if value.count <= 24 { dimensions = value }
                default:
                    break
                }
            }

            guard let urlString,
                  let url = validatedRemoteHTTPSURL(urlString),
                  let sha256Hex,
                  mimeType.hasPrefix("image/"),
                  seenHashes.insert(sha256Hex).inserted else {
                continue
            }

            attachments.append(MediaAttachment(
                url: url,
                mimeType: mimeType,
                sha256Hex: sha256Hex,
                sizeBytes: sizeBytes,
                dimensions: dimensions
            ))
            if attachments.count >= maxAttachmentsPerNote {
                break
            }
        }
        return attachments
    }

    /// Creates a signed BUD-02 Blossom upload authorization event (kind 24242).
    static func createBlossomUploadAuthEvent(
        sha256Hex: String,
        expiration: Date,
        senderIdentity: NostrIdentity,
        createdAt: Date = Date()
    ) throws -> NostrEvent {
        let normalizedHash = sha256Hex.lowercased()
        guard normalizedHash.count == 64, isValidHexIdentifier(normalizedHash) else {
            throw NostrError.invalidEvent
        }
        let tags = [
            ["t", "upload"],
            ["x", normalizedHash],
            ["expiration", String(Int(expiration.timeIntervalSince1970))]
        ]
        let event = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: createdAt,
            kind: .blossomAuth,
            tags: tags,
            content: "Upload blob"
        )
        let schnorrKey = try senderIdentity.schnorrSigningKey()
        return try event.sign(with: schnorrKey)
    }

    static func validatedRemoteHTTPSURL(_ raw: String) -> URL? {
        guard raw.count <= 1024,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty,
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal"),
              !host.hasPrefix("127."),
              !host.hasPrefix("10."),
              !host.hasPrefix("192.168."),
              host != "::1" else {
            return nil
        }
        return url
    }

    /// Minimum committed NIP-13 leading-zero bit count required for a note to
    /// carry the verified-PoW feed badge or match the PoW feed filter.
    static let verifiedPoWThresholdBits = 8

    /// Passive read-only NIP-13 proof-of-work validator for inbound events.
    /// Returns the committed target difficulty if the event carries a valid
    /// `["nonce", <nonce>, <target>]` tag and its `idHex` meets at least that
    /// many leading zero bits; otherwise returns 0.
    static func validatedPoWDifficulty(idHex: String, tags: [[String]]) -> Int {
        guard let nonceTag = tags.first(where: { $0.count >= 3 && $0[0] == "nonce" }),
              let committed = Int(nonceTag[2]),
              committed > 0, committed <= 256 else {
            return 0
        }
        guard let idData = Data(hexString: idHex), idData.count == 32 else {
            return 0
        }
        var leadingZeros = 0
        for byte in idData {
            if byte == 0 {
                leadingZeros += 8
            } else {
                leadingZeros += byte.leadingZeroBitCount
                break
            }
        }
        return leadingZeros >= committed ? committed : 0
    }

    /// Create a persistent location note (kind 1: text note) tagged to a geohash.
    /// Supports optional NIP-40 expiration, urgency, teleport marker, NIP-10
    /// thread reply tags, NIP-92 `imeta` attachments, and extra tags.
    static func createGeohashTextNote(
        content: String,
        geohash: String,
        senderIdentity: NostrIdentity,
        nickname: String? = nil,
        expiresAt: Date? = nil,
        urgent: Bool = false,
        replyTo: ThreadReference? = nil,
        teleported: Bool = false,
        attachments: [MediaAttachment] = [],
        createdAt: Date = Date(),
        extraTags: [[String]] = []
    ) throws -> NostrEvent {
        var tags = geohashTextNoteTags(
            geohash: geohash,
            nickname: nickname,
            expiresAt: expiresAt,
            urgent: urgent,
            replyTo: replyTo,
            teleported: teleported
        )
        for attachment in attachments.prefix(maxAttachmentsPerNote) {
            tags.append(imetaTag(for: attachment))
        }
        if !extraTags.isEmpty {
            tags.append(contentsOf: extraTags)
        }
        let event = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: createdAt,
            kind: .textNote,
            tags: tags,
            content: content
        )
        let schnorrKey = try senderIdentity.schnorrSigningKey()
        return try event.sign(with: schnorrKey)
    }

    private static func geohashTextNoteTags(
        geohash: String,
        nickname: String?,
        expiresAt: Date?,
        urgent: Bool,
        replyTo: ThreadReference?,
        teleported: Bool
    ) -> [[String]] {
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
        if teleported {
            tags.append(["t", "teleport"])
        }
        if let replyTo, isValidHexIdentifier(replyTo.rootEventID) {
            tags.append(["e", replyTo.rootEventID, "", "root"])
            if let directReply = replyTo.replyEventID,
               directReply != replyTo.rootEventID,
               isValidHexIdentifier(directReply) {
                tags.append(["e", directReply, "", "reply"])
            }
            if let authorPubkey = replyTo.replyAuthorPubkey,
               isValidHexIdentifier(authorPubkey) {
                tags.append(["p", authorPubkey])
            }
        }
        return tags
    }

    /// Create a NIP-25 reaction (kind 7) targeting a note inside a geohash feed.
    /// Carries the place's `g` tag so the single per-place relay subscription
    /// receives both posts and reactions without extra Tor socket overhead.
    static func createGeohashReactionEvent(
        emoji: String,
        targetEventID: String,
        targetAuthorPubkey: String?,
        geohash: String,
        senderIdentity: NostrIdentity,
        createdAt: Date = Date()
    ) throws -> NostrEvent {
        let normalizedEmoji = normalizeReactionContent(emoji) ?? "❤️"
        var tags = [
            ["g", geohash],
            ["e", targetEventID.lowercased()]
        ]
        if let author = targetAuthorPubkey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           isValidHexIdentifier(author) {
            tags.append(["p", author])
        }
        let event = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: createdAt,
            kind: .reaction,
            tags: tags,
            content: normalizedEmoji
        )
        let schnorrKey = try senderIdentity.schnorrSigningKey()
        return try event.sign(with: schnorrKey)
    }

    /// Parse a NIP-10 thread reference from a kind-1 note's tags.
    /// Prefers marked `e` tags (`root` / `reply`, ignoring `mention`); falls
    /// back to positional `e` tags when no markers are present.
    static func parseThreadReference(from tags: [[String]]) -> ThreadReference? {
        var markedRoot: String?
        var markedReply: String?
        var positionalEventIDs: [String] = []
        var replyAuthorPubkey: String?

        for tag in tags where tag.count >= 2 {
            let key = tag[0].lowercased()
            switch key {
            case "e":
                let candidate = tag[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard isValidHexIdentifier(candidate) else { continue }
                let marker = tag.count >= 4
                    ? tag[3].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    : ""
                switch marker {
                case "root":
                    if markedRoot == nil { markedRoot = candidate }
                case "reply":
                    markedReply = candidate
                case "mention":
                    continue
                default:
                    positionalEventIDs.append(candidate)
                }
            case "p":
                let candidate = tag[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if isValidHexIdentifier(candidate) {
                    replyAuthorPubkey = candidate
                }
            default:
                break
            }
        }

        if let root = markedRoot {
            return ThreadReference(
                rootEventID: root,
                replyEventID: markedReply,
                replyAuthorPubkey: replyAuthorPubkey
            )
        }
        if let replyOnly = markedReply {
            // Some clients emit only a single "reply" marker on direct replies.
            return ThreadReference(
                rootEventID: replyOnly,
                replyEventID: nil,
                replyAuthorPubkey: replyAuthorPubkey
            )
        }
        if let first = positionalEventIDs.first {
            let last = positionalEventIDs.count > 1 ? positionalEventIDs.last : nil
            return ThreadReference(
                rootEventID: first,
                replyEventID: last,
                replyAuthorPubkey: replyAuthorPubkey
            )
        }
        return nil
    }

    /// Parse a NIP-25 kind-7 reaction event into its target event ID (last `e`
    /// tag per NIP-25) and normalized display emoji.
    static func parseReactionTarget(from event: NostrEvent) -> (targetEventID: String, emoji: String)? {
        guard event.kind == EventKind.reaction.rawValue,
              let emoji = normalizeReactionContent(event.content) else {
            return nil
        }
        var targetEventID: String?
        for tag in event.tags where tag.count >= 2 && tag[0].lowercased() == "e" {
            let candidate = tag[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if isValidHexIdentifier(candidate) {
                targetEventID = candidate
            }
        }
        guard let targetEventID else { return nil }
        return (targetEventID, emoji)
    }

    /// Normalizes NIP-25 reaction content: empty or `"+"` maps to `"❤️"`,
    /// `"-"` is ignored, and custom emoji strings are bounded defensively.
    static func normalizeReactionContent(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "+" {
            return "❤️"
        }
        if trimmed == "-" {
            return nil
        }
        guard trimmed.count <= 2, trimmed.utf8.count <= 16 else {
            return nil
        }
        return trimmed
    }

    /// Sanitized NIP-01 kind-0 profile metadata. Intentionally excludes remote
    /// avatar/banner URLs so reading profiles never triggers clearnet image
    /// fetches or IP leaks in Stealth Mode.
    struct ProfileMetadata: Codable, Equatable, Sendable {
        let name: String?
        let displayName: String?
        let about: String?
        let nip05: String?

        var preferredName: String? {
            displayName?.trimmedOrNilIfEmpty ?? name?.trimmedOrNilIfEmpty
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case displayName = "display_name"
            case about
            case nip05
        }
    }

    /// Defensive upper bound on untrusted kind-0 metadata JSON content.
    static let maximumProfileMetadataBytes = 8 * 1024

    /// Create a signed NIP-01 kind-0 metadata event for an opt-in persistent
    /// Nostr public handle.
    static func createMetadataEvent(
        profile: ProfileMetadata,
        senderIdentity: NostrIdentity,
        createdAt: Date = Date()
    ) throws -> NostrEvent {
        var payload: [String: String] = [:]
        if let name = sanitizeMetadataField(profile.name, maxLength: 64, allowNewlines: false) {
            payload["name"] = name
        }
        if let displayName = sanitizeMetadataField(profile.displayName, maxLength: 64, allowNewlines: false) {
            payload["display_name"] = displayName
        }
        if let about = sanitizeMetadataField(profile.about, maxLength: 280, allowNewlines: true) {
            payload["about"] = about
        }
        if let nip05 = sanitizeMetadataField(profile.nip05, maxLength: 120, allowNewlines: false) {
            payload["nip05"] = nip05
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        let content = String(data: data, encoding: .utf8) ?? "{}"
        let event = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: createdAt,
            kind: .metadata,
            tags: [],
            content: content
        )
        let schnorrKey = try senderIdentity.schnorrSigningKey()
        return try event.sign(with: schnorrKey)
    }

    /// Parse and sanitize a NIP-01 kind-0 profile metadata event.
    static func parseMetadataEvent(_ event: NostrEvent) -> ProfileMetadata? {
        guard event.kind == EventKind.metadata.rawValue,
              event.content.utf8.count <= maximumProfileMetadataBytes,
              let data = event.content.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let name = sanitizeMetadataField(dict["name"] as? String, maxLength: 64, allowNewlines: false)
        let displayName = sanitizeMetadataField(dict["display_name"] as? String, maxLength: 64, allowNewlines: false)
        let about = sanitizeMetadataField(dict["about"] as? String, maxLength: 280, allowNewlines: true)
        let nip05 = sanitizeMetadataField(dict["nip05"] as? String, maxLength: 120, allowNewlines: false)
        guard name != nil || displayName != nil || about != nil || nip05 != nil else {
            return nil
        }
        return ProfileMetadata(
            name: name,
            displayName: displayName,
            about: about,
            nip05: nip05
        )
    }

    /// Create a global (non-geohash) kind-1 text note signed synchronously by a
    /// persistent public handle, with optional NIP-10 reply tags and NIP-92 `imeta`.
    static func createPublicTextNote(
        content: String,
        senderIdentity: NostrIdentity,
        nickname: String? = nil,
        expiresAt: Date? = nil,
        replyTo: ThreadReference? = nil,
        attachments: [MediaAttachment] = [],
        createdAt: Date = Date()
    ) throws -> NostrEvent {
        var tags: [[String]] = []
        if let nickname = nickname?.trimmedOrNilIfEmpty {
            tags.append(["n", nickname])
        }
        if let expiresAt {
            tags.append(["expiration", String(Int(expiresAt.timeIntervalSince1970))])
        }
        if let replyTo, isValidHexIdentifier(replyTo.rootEventID) {
            tags.append(["e", replyTo.rootEventID, "", "root"])
            if let directReply = replyTo.replyEventID,
               directReply != replyTo.rootEventID,
               isValidHexIdentifier(directReply) {
                tags.append(["e", directReply, "", "reply"])
            }
            if let authorPubkey = replyTo.replyAuthorPubkey,
               isValidHexIdentifier(authorPubkey) {
                tags.append(["p", authorPubkey])
            }
        }
        for attachment in attachments.prefix(maxAttachmentsPerNote) {
            tags.append(imetaTag(for: attachment))
        }
        let event = NostrEvent(
            pubkey: senderIdentity.publicKeyHex,
            createdAt: createdAt,
            kind: .textNote,
            tags: tags,
            content: content
        )
        let schnorrKey = try senderIdentity.schnorrSigningKey()
        return try event.sign(with: schnorrKey)
    }

    /// Decode either a 64-character hex pubkey or a `npub1...` Bech32 string
    /// into canonical lowercase 64-char hex.
    static func normalizePubkeyHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("npub1") {
            guard let (hrp, data) = try? Bech32.decode(lower),
                  hrp == "npub",
                  data.count == 32 else {
                return nil
            }
            return data.hexEncodedString().lowercased()
        }
        guard lower.count == 64, isValidHexIdentifier(lower) else {
            return nil
        }
        return lower
    }

    private static func sanitizeMetadataField(_ raw: String?, maxLength: Int, allowNewlines: Bool) -> String? {
        guard let raw else { return nil }
        let disallowed = allowNewlines
            ? CharacterSet.controlCharacters.subtracting(.newlines)
            : CharacterSet.controlCharacters.union(.newlines)
        var cleaned = ""
        cleaned.unicodeScalars.append(contentsOf: raw.unicodeScalars.filter { !disallowed.contains($0) })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maxLength))
    }

    private static func isValidHexIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x61 && byte <= 0x66)
                || (byte >= 0x41 && byte <= 0x46)
        }
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
        senderKey: BitSecp256k1.SchnorrPrivateKey
    ) throws -> NostrEvent {
        
        let rumorJSON = try rumor.jsonString()
        let encrypted = try encrypt(
            plaintext: rumorJSON,
            recipientPubkey: recipientPubkey,
            senderKey: senderKey
        )
        
        let seal = NostrEvent(
            pubkey: senderKey.xonlyPublicKey.hexEncodedString(),
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
        let wrapKey = try BitSecp256k1.SchnorrPrivateKey()
        // Creating gift wrap with ephemeral key
        
        // Encrypt the seal with the new ephemeral key (not the seal's key)
        let encrypted = try encrypt(
            plaintext: sealJSON,
            recipientPubkey: recipientPubkey,
            senderKey: wrapKey  // Use the gift wrap ephemeral key
        )
        
        let giftWrap = NostrEvent(
            pubkey: wrapKey.xonlyPublicKey.hexEncodedString(),
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
        recipientKey: BitSecp256k1.SchnorrPrivateKey
    ) throws -> NostrEvent {
        
        // Unwrapping gift wrap
        
        let decrypted = try decrypt(
            ciphertext: giftWrap.content,
            senderPubkey: giftWrap.pubkey,
            recipientKey: recipientKey
        )
        
        // Check UTF-8 size before allocating Data or invoking the general
        // JSON parser on attacker-influenced plaintext.
        guard decrypted.utf8.count <= maximumPrivateEnvelopeCiphertextBytes else {
            throw NostrError.invalidCiphertext
        }
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
        recipientKey: BitSecp256k1.SchnorrPrivateKey
    ) throws -> NostrEvent {
        
        let decrypted = try decrypt(
            ciphertext: seal.content,
            senderPubkey: seal.pubkey,
            recipientKey: recipientKey
        )
        
        guard decrypted.utf8.count <= maximumPrivateEnvelopeCiphertextBytes else {
            throw NostrError.invalidCiphertext
        }
        guard let data = decrypted.data(using: .utf8),
              let rumorDict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NostrError.invalidEvent
        }

        return try NostrEvent(from: rumorDict)
    }

    // MARK: - BitChat private-envelope encryption
    //
    // Not NIP-44: the `v2:` prefix, base64url(nonce24 || ciphertext || tag)
    // layout, XChaCha20-Poly1305 cipher, and HKDF parameters are all
    // BitChat-specific.

    private static func encrypt(
        plaintext: String,
        recipientPubkey: String,
        senderKey: BitSecp256k1.SchnorrPrivateKey
    ) throws -> String {
        
        guard let recipientPubkeyData = Data(hexString: recipientPubkey) else {
            throw NostrError.invalidPublicKey
        }
        
        // Derive shared secret
        let sharedSecret = try deriveSharedSecret(
            privateKey: senderKey,
            publicKey: recipientPubkeyData
        )
        // Derive the BitChat private-envelope symmetric key (HKDF-SHA256)
        let key = try derivePrivateEnvelopeKey(from: sharedSecret)

        // 24-byte random nonce for XChaCha20-Poly1305
        var nonce24 = Data(count: 24)
        let randomStatus = nonce24.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 24, ptr.baseAddress!)
        }
        // Never encrypt with an unrandomized nonce: nonce reuse under the same
        // key breaks XChaCha20-Poly1305 confidentiality and authenticity.
        guard randomStatus == errSecSuccess else {
            throw NostrError.cryptographicFailure
        }

        let pt = Data(plaintext.utf8)
        let sealed = try XChaCha20Poly1305Compat.seal(plaintext: pt, key: key, nonce24: nonce24)
        
        // v2: base64url(nonce24 || ciphertext || tag)
        var combined = Data(capacity: 24 + sealed.ciphertext.count + sealed.tag.count)
        combined.append(nonce24)
        combined.append(sealed.ciphertext)
        combined.append(sealed.tag)
        return "v2:" + Base64URLCoding.encode(combined)
    }
    
    private static func decrypt(
        ciphertext: String,
        senderPubkey: String,
        recipientKey: BitSecp256k1.SchnorrPrivateKey
    ) throws -> String {
        // Expect BitChat's historical `v2:` private-envelope framing, and
        // bound work before Base64 decoding attacker-sized input.
        guard ciphertext.utf8.count <= maximumPrivateEnvelopeCiphertextBytes,
              ciphertext.hasPrefix("v2:") else {
            throw NostrError.invalidCiphertext
        }
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
            let key = try derivePrivateEnvelopeKey(from: ss)
            return try XChaCha20Poly1305Compat.open(
                ciphertext: Data(ct),
                tag: Data(tag),
                key: key,
                nonce24: Data(nonce24)
            )
        }

        // If 32 bytes (x-only) try both parities, otherwise single try
        let plaintext: Data
        if senderPubkeyData.count == 32 {
            let even = Data([0x02]) + senderPubkeyData
            if let pt = try? attemptDecrypt(using: even) {
                plaintext = pt
            } else {
                let odd = Data([0x03]) + senderPubkeyData
                plaintext = try attemptDecrypt(using: odd)
            }
        } else {
            plaintext = try attemptDecrypt(using: senderPubkeyData)
        }

        // Authenticated plaintext that is not valid UTF-8 is a malformed
        // envelope, not an empty message.
        guard let decoded = String(data: plaintext, encoding: .utf8) else {
            throw NostrError.invalidCiphertext
        }
        return decoded
    }
    
    private static func deriveSharedSecret(
        privateKey: BitSecp256k1.SchnorrPrivateKey,
        publicKey: Data
    ) throws -> Data {
        if publicKey.count == 32 {
            // For x-only keys, try even Y (0x02) first, then odd Y (0x03).
            var compressed = Data(capacity: 33)
            compressed.append(0x02)
            compressed.append(publicKey)
            if let shared = try? BitSecp256k1.ecdhCompressed(
                privateKey: privateKey.dataRepresentation,
                compressedPublicKey: compressed
            ) {
                return shared
            }
            compressed[0] = 0x03
            return try BitSecp256k1.ecdhCompressed(
                privateKey: privateKey.dataRepresentation,
                compressedPublicKey: compressed
            )
        } else {
            return try BitSecp256k1.ecdhCompressed(
                privateKey: privateKey.dataRepresentation,
                compressedPublicKey: publicKey
            )
        }
    }
    
    private static func randomizedTimestamp() -> Date {
        // Add random offset to current time for privacy.
        // This prevents timing correlation attacks while the actual message timestamp
        // is preserved in the encrypted rumor.
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

        guard Self.isWithinInboundTagLimits(tags) else {
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

    /// Bounds untrusted relay tag arrays so attackers cannot force large
    /// allocations or expensive joins on the inbound hot path.
    static func isWithinInboundTagLimits(_ tags: [[String]]) -> Bool {
        guard tags.count <= TransportConfig.nostrMaxEventTags else { return false }

        for tag in tags {
            guard tag.count <= TransportConfig.nostrMaxEventTagValues else { return false }
            guard tag.allSatisfy({ $0.utf8.count <= TransportConfig.nostrMaxEventTagValueBytes }) else {
                return false
            }
        }

        return true
    }
    
    func sign(with key: BitSecp256k1.SchnorrPrivateKey) throws -> NostrEvent {
        let (eventId, eventIdHash) = try calculateEventId()
        
        // Sign with Schnorr (BIP-340)
        let messageBytes = [UInt8](eventIdHash)
        var auxRand = [UInt8](repeating: 0, count: 32)
        let auxStatus = auxRand.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        guard auxStatus == errSecSuccess else {
            throw NostrError.cryptographicFailure
        }
        let schnorrSignature = try key.sign(message: messageBytes, auxiliaryRand: auxRand)
        
        let signatureHex = schnorrSignature.hexEncodedString()
        
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
              let (expectedId, eventHash) = try? calculateEventId(),
              expectedId == id
        else {
            return false
        }

        return BitSecp256k1.verifySchnorr(
            signature: sigData,
            message: [UInt8](eventHash),
            xonlyPublicKey: pubData
        )
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
        return data.sha256FingerprintAndHash()
    }
    
    private static let unescapedJSONEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    func jsonString() throws -> String {
        let data = try Self.unescapedJSONEncoder.encode(self)
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
    /// The HKDF info string retains the historical "nip44-v2" label for wire
    /// compatibility with deployed clients, but this is not the NIP-44 key
    /// schedule: NIP-44 derives a conversation key via HKDF-extract with that
    /// label as the *salt* and uses ChaCha20 with per-message expanded keys.
    static func derivePrivateEnvelopeKey(from sharedSecretData: Data) throws -> Data {
        let derivedKey = HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecretData),
            salt: Data(),
            info: Data("nip44-v2".utf8),
            outputByteCount: 32
        )
        return derivedKey.withUnsafeBytes { Data($0) }
    }
}
