import BitFoundation
import BitLogger
import Foundation

/// The narrow surface `NostrInboundPipeline` needs from its owner.
///
/// Split out of `ChatNostrContext`: member names are shared with the sibling
/// component contexts so `ChatViewModel` provides a single witness for each.
@MainActor
protocol NostrInboundPipelineContext: AnyObject {
    var currentGeohash: String? { get }

    // MARK: Event dedup
    func hasProcessedNostrEvent(_ eventID: String) -> Bool
    func recordProcessedNostrEvent(_ eventID: String)
    func recordProcessedEphemeralNostrEvent(_ eventID: String)

    // MARK: Nostr identity & blocking
    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity
    func currentNostrIdentity() -> NostrIdentity?
    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool
    func displayNameForNostrPubkey(_ pubkeyHex: String) -> String

    // MARK: Favorites bridge
    /// Fast reverse lookup from a Nostr pubkey (hex or npub) to a favorite's
    /// Noise static key.
    func favoriteNoiseKey(forNostrPubkey nostrPubkey: String) -> Data?

    // MARK: Presence & key mapping
    func setGeoNickname(_ nickname: String, forPubkey pubkeyHex: String)
    /// Records the Nostr pubkey behind a (possibly virtual) peer ID.
    func registerNostrKeyMapping(_ pubkey: String, for peerID: PeerID)
    /// `seenAt` is the event's own timestamp, so replayed history doesn't
    /// count its authors as present. Returns whether the activity counted.
    @discardableResult
    func recordGeoParticipant(pubkeyHex: String, seenAt: Date) -> Bool

    // MARK: Inbound public messages
    func handlePublicMessage(_ message: BitchatMessage)
    func checkForMentions(_ message: BitchatMessage)
    func sendHapticFeedback(for message: BitchatMessage)
    func parseMentions(from content: String) -> [String]

    // MARK: Inbound private (DM) payloads
    func handlePrivateMessage(
        _ payload: NoisePayload,
        senderPubkey: String,
        convKey: PeerID,
        id: NostrIdentity,
        messageTimestamp: Date
    )
    func handleDelivered(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID)
    func handleReadReceipt(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID)
}

extension ChatViewModel: NostrInboundPipelineContext {
    // `currentGeohash`, the identity/blocking members, key mapping, and the
    // inbound message handlers already have witnesses on `ChatViewModel`.
    // The members below flatten nested service accesses into intent-named calls.

    func hasProcessedNostrEvent(_ eventID: String) -> Bool {
        deduplicationService.hasProcessedNostrEvent(eventID)
    }

    func favoriteNoiseKey(forNostrPubkey nostrPubkey: String) -> Data? {
        FavoritesPersistenceService.shared.noisePublicKey(forNostrPubkey: nostrPubkey)
    }

    func recordProcessedNostrEvent(_ eventID: String) {
        deduplicationService.recordNostrEvent(eventID, persist: true)
    }

    func recordProcessedEphemeralNostrEvent(_ eventID: String) {
        deduplicationService.recordNostrEvent(eventID, persist: false)
    }

    func setGeoNickname(_ nickname: String, forPubkey pubkeyHex: String) {
        if locationPresenceStore.setNickname(nickname, for: pubkeyHex) {
            participantTracker.noteDisplayNameChanged(pubkeyHex: pubkeyHex)
        }
    }

    @discardableResult
    func recordGeoParticipant(pubkeyHex: String, seenAt: Date) -> Bool {
        participantTracker.recordParticipant(pubkeyHex: pubkeyHex, seenAt: seenAt)
    }
}

/// The inbound Nostr hot path: verified relay events in, chat messages /
/// Noise payloads out. Pure transformation plus dedup — no relay lifecycle.
///
/// Every event arriving here already had its Schnorr signature verified
/// exactly once, off the main actor, by `NostrRelayManager`'s serial inbound
/// pipeline (which records events into its own dedup cache only AFTER
/// verification, so forged copies can't suppress genuine events). This
/// pipeline therefore never re-verifies; it keeps its own event-ID dedup
/// (cheap main-actor lookups) and moves NIP-17 gift-wrap decryption — two
/// ECDH+ChaCha layers — off the main actor with an atomic main-actor
/// check-and-record.
final class NostrInboundPipeline {
    private weak var context: (any NostrInboundPipelineContext)?
    private let presence: GeoPresenceTracker
    private var geoEventLogCount = 0

    /// Monotonic panic-wipe generation for this pipeline. A panic wipe clears
    /// relay handlers so no NEW events flow, but a detached decrypt task
    /// spawned just BEFORE the wipe — which strongly captures a pre-wipe Nostr
    /// private key and ciphertext — survives it. Spawn sites capture this
    /// value; the task compares it at its main-actor hops and drops its result
    /// (no delivery; the captured identity and plaintext die with the task)
    /// if `invalidateInFlightDecrypts()` bumped it in between.
    @MainActor private(set) var wipeGeneration: UInt64 = 0

    /// Called from `ChatViewModel.panicClearAllData()` so plaintext decrypted
    /// with pre-wipe keys can never land in post-wipe state.
    @MainActor
    func invalidateInFlightDecrypts() {
        wipeGeneration &+= 1
    }

    init(context: any NostrInboundPipelineContext, presence: GeoPresenceTracker) {
        self.context = context
        self.presence = presence
    }

    /// `isHistoryReplay` marks events relays return from storage before EOSE.
    /// Those count as activity at the time they happened, so an hour of
    /// replayed history doesn't make its authors look present; live events
    /// count when they arrive, which keeps senders with skewed clocks visible.
    @MainActor
    func handleNostrEvent(_ event: NostrEvent, isHistoryReplay: Bool = false) {
        guard let context else { return }
        // Cheap rejects (kind, dedup lookup) — duplicates dominate real
        // traffic. The signature was already verified (exactly once, off the
        // main actor) by NostrRelayManager before delivery.
        guard (event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue
            || event.kind == NostrProtocol.EventKind.geohashPresence.rawValue),
              !context.hasProcessedNostrEvent(event.id)
        else {
            return
        }
        context.recordProcessedEphemeralNostrEvent(event.id)

        // Sampled: fires for every geo event and floods dev logs in busy geohashes.
        geoEventLogCount += 1
        if geoEventLogCount == 1 || geoEventLogCount.isMultiple(of: TransportConfig.nostrInboundEventLogInterval) {
            SecureLogger.debug(
                "GeoTeleport: recv #\(geoEventLogCount) pub=\(event.pubkey.prefix(8))… tagCount=\(event.tags.count)",
                category: .session
            )
        }

        let lowercasedPubkey = event.pubkey.lowercased()
        if context.isNostrBlocked(pubkeyHexLowercased: lowercasedPubkey) {
            return
        }

        let hasTeleportTag = GeoPresenceTracker.hasTeleportTag(event)

        let isSelf: Bool = {
            if let gh = context.currentGeohash,
               let my = try? context.deriveNostrIdentity(forGeohash: gh) {
                return my.publicKeyHex.lowercased() == lowercasedPubkey
            }
            return false
        }()

        let eventTime = Date(timeIntervalSince1970: TimeInterval(event.created_at))
        let seenAt = isHistoryReplay ? eventTime : Date()
        if isSelf, Date().timeIntervalSince(eventTime) < 15 {
            context.recordGeoParticipant(pubkeyHex: event.pubkey, seenAt: seenAt)
            return
        }

        // Learn the nickname before recording the sender, so a newcomer
        // enters the roster under their name rather than anon#xxxx.
        if let nickTag = event.tags.first(where: { $0.first == "n" }), nickTag.count >= 2 {
            context.setGeoNickname(nickTag[1].trimmed, forPubkey: event.pubkey)
        }

        context.registerNostrKeyMapping(event.pubkey, for: PeerID(nostr_: event.pubkey))
        context.registerNostrKeyMapping(event.pubkey, for: PeerID(nostr: event.pubkey))
        let countsAsPresence = context.recordGeoParticipant(pubkeyHex: event.pubkey, seenAt: seenAt)

        // Teleport markers describe people present now and are pruned only
        // when the roster changes, so a tag on history too old to count must
        // not mark its absent author.
        if hasTeleportTag, !isSelf, countsAsPresence {
            presence.scheduleMarkPeerTeleported(lowercasedPubkey, logged: true)
        }

        if event.kind == NostrProtocol.EventKind.geohashPresence.rawValue {
            return
        }

        let senderName = context.displayNameForNostrPubkey(event.pubkey)
        let content = event.content

        if hasTeleportTag, content.trimmed.isEmpty {
            return
        }

        let mentions = context.parseMentions(from: content)
        let message = BitchatMessage(
            id: event.id,
            sender: senderName,
            content: content,
            timestamp: min(eventTime, Date()),
            isRelay: false,
            senderPeerID: PeerID(nostr: event.pubkey),
            mentions: mentions.isEmpty ? nil : mentions
        )

        context.handlePublicMessage(message)
        context.checkForMentions(message)
        context.sendHapticFeedback(for: message)
    }

    @MainActor
    func handleGiftWrap(
        _ giftWrap: NostrEvent,
        id: NostrIdentity,
        outerSignatureAlreadyVerified: Bool = false
    ) {
        guard let context else { return }
        guard !context.hasProcessedNostrEvent(giftWrap.id) else { return }

        // Capture the wipe generation at spawn, alongside the per-geohash
        // identity (private key) the detached task strongly captures. A panic
        // wipe between spawn and delivery bumps the generation, and the task
        // drops its result instead of delivering plaintext post-wipe.
        let wipeGeneration = self.wipeGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.processGiftWrap(
                giftWrap,
                geohashIdentity: id,
                initialWipeGeneration: wipeGeneration,
                outerSignatureAlreadyVerified: outerSignatureAlreadyVerified
            )
        }
    }

    @MainActor
    func handleNostrMessage(_ giftWrap: NostrEvent, outerSignatureAlreadyVerified: Bool = false) {
        guard let context else { return }
        // Cheap dedup pre-check only; processNostrMessage does the
        // authoritative check-and-record before the off-main NIP-17 unwrap.
        if context.hasProcessedNostrEvent(giftWrap.id) { return }

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.processNostrMessage(
                giftWrap,
                outerSignatureAlreadyVerified: outerSignatureAlreadyVerified
            )
        }
    }

    func processNostrMessage(
        _ giftWrap: NostrEvent,
        outerSignatureAlreadyVerified: Bool = false
    ) async {
        await processGiftWrap(
            giftWrap,
            geohashIdentity: nil,
            initialWipeGeneration: nil,
            outerSignatureAlreadyVerified: outerSignatureAlreadyVerified
        )
    }

    /// Unified NIP-17 gift-wrap ingest for both geohash DMs (`geohashIdentity != nil`)
    /// and account DMs (`geohashIdentity == nil`). Decryption and BitChat packet
    /// decoding run off the main actor; dedup check-and-record and delivery run
    /// atomically on `@MainActor` guarded by `wipeGeneration`.
    private func processGiftWrap(
        _ giftWrap: NostrEvent,
        geohashIdentity: NostrIdentity?,
        initialWipeGeneration: UInt64?,
        outerSignatureAlreadyVerified: Bool
    ) async {
        guard let context else { return }
        let isGeohashDM = geohashIdentity != nil

        // Single pre-decrypt main-actor hop: atomically check-and-record dedup
        // AND resolve `(recipientIdentity, wipeGeneration)` so the generation
        // vouches for exactly the identity used to decrypt.
        let preDecrypt: (identity: NostrIdentity, wipeGeneration: UInt64)? = await MainActor.run {
            if let expectedGen = initialWipeGeneration, self.wipeGeneration != expectedGen {
                return nil
            }
            if context.hasProcessedNostrEvent(giftWrap.id) { return nil }
            context.recordProcessedNostrEvent(giftWrap.id)
            guard let identity = geohashIdentity ?? context.currentNostrIdentity() else { return nil }
            return (identity, initialWipeGeneration ?? self.wipeGeneration)
        }
        guard let (recipientIdentity, wipeGeneration) = preDecrypt else { return }

        let content: String
        let senderPubkey: String
        let rumorTimestamp: Int
        do {
            (content, senderPubkey, rumorTimestamp) = try NostrProtocol.decryptPrivateMessage(
                giftWrap: giftWrap,
                recipientIdentity: recipientIdentity,
                outerSignatureAlreadyVerified: outerSignatureAlreadyVerified
            )
        } catch {
            if isGeohashDM {
                SecureLogger.warning("GeoDM: failed decrypt giftWrap id=\(giftWrap.id.prefix(8))…", category: .session)
            } else {
                SecureLogger.error("Failed to decrypt Nostr message: \(error)", category: .session)
            }
            return
        }

        guard Self.isPlausibleRumorTimestamp(rumorTimestamp) else {
            let label = isGeohashDM ? "GeoDM: dropping gift-wrap" : "Dropping Nostr DM"
            SecureLogger.warning("\(label) with implausible rumor timestamp id=\(giftWrap.id.prefix(8))…", category: .session)
            return
        }

        if isGeohashDM {
            SecureLogger.debug(
                "GeoDM: decrypted gift-wrap id=\(giftWrap.id.prefix(16))... from=\(senderPubkey.prefix(8))...",
                category: .session
            )
        } else {
            if content.hasPrefix("verify:") { return }
            guard content.hasPrefix("bitchat1:") else {
                SecureLogger.debug("Ignoring non-embedded Nostr DM content", category: .session)
                return
            }
        }

        guard let packet = Self.decodeEmbeddedBitChatPacket(from: content) else {
            if !isGeohashDM {
                SecureLogger.error("Failed to decode embedded BitChat packet from Nostr DM", category: .session)
            }
            return
        }

        guard packet.type == MessageType.noiseEncrypted.rawValue,
              let payload = NoisePayload.decode(packet.payload) else {
            return
        }

        let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(rumorTimestamp))
        await MainActor.run {
            // Drop pre-wipe plaintext if a panic wipe landed during the off-main decrypt.
            guard self.wipeGeneration == wipeGeneration else { return }

            let convKey: PeerID
            if isGeohashDM {
                convKey = PeerID(nostr_: senderPubkey)
            } else {
                let actualSenderNoiseKey = self.findNoiseKey(for: senderPubkey)
                convKey = PeerID(str: actualSenderNoiseKey?.hexEncodedString()) ?? PeerID(nostr_: senderPubkey)
            }
            context.registerNostrKeyMapping(senderPubkey, for: convKey)

            switch payload.type {
            case .privateMessage:
                context.handlePrivateMessage(
                    payload,
                    senderPubkey: senderPubkey,
                    convKey: convKey,
                    id: recipientIdentity,
                    messageTimestamp: messageTimestamp
                )
            case .delivered:
                context.handleDelivered(payload, senderPubkey: senderPubkey, convKey: convKey)
            case .readReceipt:
                context.handleReadReceipt(payload, senderPubkey: senderPubkey, convKey: convKey)
            // Group state and live voice are mesh-only in v1.
            case .verifyChallenge, .verifyResponse, .groupInvite, .groupKeyUpdate, .vouch, .voiceFrame, .privateFile, .authenticatedPeerState:
                break
            }
        }
    }

    /// Resolves the Noise static key behind a Nostr pubkey via the favorites
    /// store. Lives here because the inbound DM path needs it per message.
    @MainActor
    func findNoiseKey(for nostrPubkey: String) -> Data? {
        guard let context else { return nil }
        if let noiseKey = context.favoriteNoiseKey(forNostrPubkey: nostrPubkey) {
            return noiseKey
        }
        SecureLogger.debug(
            "⚠️ No matching Noise key found for Nostr pubkey: \(nostrPubkey.prefix(16))...",
            category: .session
        )
        return nil
    }
}

extension NostrInboundPipeline {
    /// Client-side mirror of the relay-side `since` filter on DM
    /// subscriptions: a relay that ignores `since` — or replays archived
    /// events — must not inject stale or future-dated DMs. The inner rumor
    /// timestamp is the sender's true send time (only the outer gift wrap
    /// is randomized per NIP-17), so the plausible window is the
    /// subscription lookback plus tolerated clock skew on both ends.
    /// Internal (not private) so tests can pin the window directly.
    static func isPlausibleRumorTimestamp(_ ts: Int, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince1970 - TimeInterval(ts)
        return age >= -TransportConfig.nostrDMMaxClockSkewSeconds
            && age <= TransportConfig.nostrDMSubscribeLookbackSeconds
                + TransportConfig.nostrDMMaxClockSkewSeconds
    }
}

private extension NostrInboundPipeline {
    nonisolated static func decodeEmbeddedBitChatPacket(from content: String) -> BitchatPacket? {
        guard content.hasPrefix("bitchat1:") else { return nil }
        let encoded = String(content.dropFirst("bitchat1:".count))
        let maxBytes = FileTransferLimits.maxFramedFileBytes
        let maxEncoded = ((maxBytes + 2) / 3) * 4
        guard encoded.count <= maxEncoded else { return nil }
        guard let packetData = Base64URLCoding.decode(encoded),
              packetData.count <= maxBytes
        else {
            return nil
        }
        return BitchatPacket.from(packetData)
    }
}
