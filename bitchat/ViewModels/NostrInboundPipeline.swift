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

    // MARK: Nostr identity & blocking
    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity
    func currentNostrIdentity() -> NostrIdentity?
    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool
    func displayNameForNostrPubkey(_ pubkeyHex: String) -> String

    // MARK: Favorites bridge
    /// All favorite relationships, used to bridge a Nostr pubkey back to a
    /// Noise key on the inbound DM path.
    func allFavoriteRelationships() -> [FavoritesPersistenceService.FavoriteRelationship]

    // MARK: Presence & key mapping
    func setGeoNickname(_ nickname: String, forPubkey pubkeyHex: String)
    /// Records the Nostr pubkey behind a (possibly virtual) peer ID.
    func registerNostrKeyMapping(_ pubkey: String, for peerID: PeerID)
    func recordGeoParticipant(pubkeyHex: String)

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

    func allFavoriteRelationships() -> [FavoritesPersistenceService.FavoriteRelationship] {
        Array(FavoritesPersistenceService.shared.favorites.values)
    }

    func recordProcessedNostrEvent(_ eventID: String) {
        deduplicationService.recordNostrEvent(eventID)
    }

    func setGeoNickname(_ nickname: String, forPubkey pubkeyHex: String) {
        locationPresenceStore.setNickname(nickname, for: pubkeyHex)
    }

    func recordGeoParticipant(pubkeyHex: String) {
        participantTracker.recordParticipant(pubkeyHex: pubkeyHex)
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

    @MainActor
    func subscribeNostrEvent(_ event: NostrEvent) {
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

        context.recordProcessedNostrEvent(event.id)

        if let gh = context.currentGeohash,
           let myGeoIdentity = try? context.deriveNostrIdentity(forGeohash: gh),
           myGeoIdentity.publicKeyHex.lowercased() == event.pubkey.lowercased() {
            let eventTime = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            if Date().timeIntervalSince(eventTime) < 15 {
                return
            }
        }

        if let nickTag = event.tags.first(where: { $0.first == "n" }), nickTag.count >= 2 {
            let nick = nickTag[1].trimmed
            context.setGeoNickname(nick, forPubkey: event.pubkey)
        }

        context.registerNostrKeyMapping(event.pubkey, for: PeerID(nostr_: event.pubkey))
        context.registerNostrKeyMapping(event.pubkey, for: PeerID(nostr: event.pubkey))
        context.recordGeoParticipant(pubkeyHex: event.pubkey)

        if event.kind == NostrProtocol.EventKind.geohashPresence.rawValue {
            return
        }

        if GeoPresenceTracker.hasTeleportTag(event) {
            let key = event.pubkey.lowercased()
            let isSelf: Bool = {
                if let gh = context.currentGeohash,
                   let myIdentity = try? context.deriveNostrIdentity(forGeohash: gh) {
                    return myIdentity.publicKeyHex.lowercased() == key
                }
                return false
            }()
            if !isSelf {
                presence.scheduleMarkPeerTeleported(key, logged: false)
            }
        }

        let senderName = context.displayNameForNostrPubkey(event.pubkey)
        let content = event.content.trimmed
        let rawTs = Date(timeIntervalSince1970: TimeInterval(event.created_at))
        let timestamp = min(rawTs, Date())
        let mentions = context.parseMentions(from: content)
        let message = BitchatMessage(
            id: event.id,
            sender: senderName,
            content: content,
            timestamp: timestamp,
            isRelay: false,
            senderPeerID: PeerID(nostr: event.pubkey),
            mentions: mentions.isEmpty ? nil : mentions
        )

        Task { @MainActor [weak context] in
            guard let context else { return }
            let isBlocked = context.isNostrBlocked(pubkeyHexLowercased: event.pubkey.lowercased())
            context.handlePublicMessage(message)
            if !isBlocked {
                context.checkForMentions(message)
                context.sendHapticFeedback(for: message)
            }
        }
    }

    @MainActor
    func handleNostrEvent(_ event: NostrEvent) {
        guard let context else { return }
        // Cheap rejects (kind, dedup lookup) — the signature was already
        // verified (exactly once, off the main actor) by NostrRelayManager.
        guard (event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue
            || event.kind == NostrProtocol.EventKind.geohashPresence.rawValue)
        else {
            return
        }
        if context.hasProcessedNostrEvent(event.id) { return }
        context.recordProcessedNostrEvent(event.id)

        // Sampled: fires for every geo event and floods dev logs in busy geohashes.
        geoEventLogCount += 1
        if geoEventLogCount == 1 || geoEventLogCount.isMultiple(of: TransportConfig.nostrInboundEventLogInterval) {
            SecureLogger.debug("GeoTeleport: recv #\(geoEventLogCount) pub=\(event.pubkey.prefix(8))… tags=\(event.tags.map { "[" + $0.joined(separator: ",") + "]" }.joined(separator: ","))", category: .session)
        }

        if context.isNostrBlocked(pubkeyHexLowercased: event.pubkey) {
            return
        }

        let hasTeleportTag = GeoPresenceTracker.hasTeleportTag(event)

        let isSelf: Bool = {
            if let gh = context.currentGeohash,
               let my = try? context.deriveNostrIdentity(forGeohash: gh) {
                return my.publicKeyHex.lowercased() == event.pubkey.lowercased()
            }
            return false
        }()

        if hasTeleportTag, !isSelf {
            presence.scheduleMarkPeerTeleported(event.pubkey.lowercased(), logged: true)
        }

        context.recordGeoParticipant(pubkeyHex: event.pubkey)

        if isSelf {
            let eventTime = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            if Date().timeIntervalSince(eventTime) < 15 {
                return
            }
        }

        if let nickTag = event.tags.first(where: { $0.first == "n" }), nickTag.count >= 2 {
            context.setGeoNickname(nickTag[1].trimmed, forPubkey: event.pubkey)
        }

        context.registerNostrKeyMapping(event.pubkey, for: PeerID(nostr_: event.pubkey))
        context.registerNostrKeyMapping(event.pubkey, for: PeerID(nostr: event.pubkey))

        if event.kind == NostrProtocol.EventKind.geohashPresence.rawValue {
            return
        }

        let senderName = context.displayNameForNostrPubkey(event.pubkey)
        let content = event.content

        if let teleTag = event.tags.first(where: { $0.first == "t" }),
           teleTag.count >= 2,
           teleTag[1] == "teleport",
           content.trimmed.isEmpty {
            return
        }

        let rawTs = Date(timeIntervalSince1970: TimeInterval(event.created_at))
        let mentions = context.parseMentions(from: content)
        let message = BitchatMessage(
            id: event.id,
            sender: senderName,
            content: content,
            timestamp: min(rawTs, Date()),
            isRelay: false,
            senderPeerID: PeerID(nostr: event.pubkey),
            mentions: mentions.isEmpty ? nil : mentions
        )

        Task { @MainActor [weak context] in
            guard let context else { return }
            context.handlePublicMessage(message)
            context.checkForMentions(message)
            context.sendHapticFeedback(for: message)
        }
    }

    @MainActor
    func subscribeGiftWrap(_ giftWrap: NostrEvent, id: NostrIdentity) {
        guard let context else { return }
        // Cheap dedup pre-check only; processGeohashGiftWrap does the
        // authoritative main-actor check-and-record before the off-main
        // NIP-17 unwrap. The outer signature was already verified (exactly
        // once, off the main actor) by NostrRelayManager.
        guard !context.hasProcessedNostrEvent(giftWrap.id) else { return }

        // Capture the wipe generation at spawn, alongside the per-geohash
        // identity (private key) the detached task strongly captures. A panic
        // wipe between spawn and delivery bumps the generation, and the task
        // drops its result instead of delivering plaintext post-wipe.
        let wipeGeneration = self.wipeGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.processGeohashGiftWrap(giftWrap, id: id, verbose: false, wipeGeneration: wipeGeneration)
        }
    }

    @MainActor
    func handleGiftWrap(_ giftWrap: NostrEvent, id: NostrIdentity) {
        guard let context else { return }
        // Cheap dedup pre-check only; see subscribeGiftWrap.
        if context.hasProcessedNostrEvent(giftWrap.id) {
            return
        }

        // Spawn-time wipe-generation capture; see subscribeGiftWrap.
        let wipeGeneration = self.wipeGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.processGeohashGiftWrap(giftWrap, id: id, verbose: true, wipeGeneration: wipeGeneration)
        }
    }

    /// Geohash-DM gift wrap ingest. The NIP-17 unwrap (two ECDH+ChaCha
    /// layers) runs off the main actor; results hop back for state updates.
    /// `verbose` keeps `handleGiftWrap`'s decrypt logging without adding it
    /// to the sampling path.
    ///
    /// `wipeGeneration` is this pipeline's generation captured at spawn (the
    /// moment the pre-wipe `id` was captured); a mismatch at either main-actor
    /// hop means a panic wipe happened in between, so the task bails without
    /// decrypting (first hop) or without delivering the plaintext (second
    /// hop) — the captured identity and any decrypted material are simply
    /// dropped with the task.
    private func processGeohashGiftWrap(
        _ giftWrap: NostrEvent,
        id: NostrIdentity,
        verbose: Bool,
        wipeGeneration: UInt64
    ) async {
        guard let context else { return }
        // Authoritative check-and-record, atomic on the main actor so two
        // concurrent detached tasks can't both process the same event.
        let alreadyProcessed: Bool = await MainActor.run {
            guard self.wipeGeneration == wipeGeneration else { return true }
            if context.hasProcessedNostrEvent(giftWrap.id) { return true }
            context.recordProcessedNostrEvent(giftWrap.id)
            return false
        }
        if alreadyProcessed { return }

        guard let (content, senderPubkey, rumorTs) = try? NostrProtocol.decryptPrivateMessage(
            giftWrap: giftWrap,
            recipientIdentity: id
        ) else {
            if verbose {
                SecureLogger.warning("GeoDM: failed decrypt giftWrap id=\(giftWrap.id.prefix(8))…", category: .session)
            }
            return
        }

        if verbose {
            SecureLogger.debug(
                "GeoDM: decrypted gift-wrap id=\(giftWrap.id.prefix(16))... from=\(senderPubkey.prefix(8))...",
                category: .session
            )
        }

        await MainActor.run {
            // A panic wipe during the off-main decrypt must not let the
            // pre-wipe plaintext reach post-wipe state; drop it here, atomic
            // with the wipe on the main actor.
            guard self.wipeGeneration == wipeGeneration else { return }
            guard let packet = Self.decodeEmbeddedBitChatPacket(from: content),
                  packet.type == MessageType.noiseEncrypted.rawValue,
                  let payload = NoisePayload.decode(packet.payload)
            else {
                return
            }

            let convKey = PeerID(nostr_: senderPubkey)
            context.registerNostrKeyMapping(senderPubkey, for: convKey)

            switch payload.type {
            case .privateMessage:
                let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(rumorTs))
                context.handlePrivateMessage(
                    payload,
                    senderPubkey: senderPubkey,
                    convKey: convKey,
                    id: id,
                    messageTimestamp: messageTimestamp
                )
            case .delivered:
                context.handleDelivered(payload, senderPubkey: senderPubkey, convKey: convKey)
            case .readReceipt:
                context.handleReadReceipt(payload, senderPubkey: senderPubkey, convKey: convKey)
            case .verifyChallenge, .verifyResponse:
                break
            }
        }
    }

    @MainActor
    func handleNostrMessage(_ giftWrap: NostrEvent) {
        guard let context else { return }
        // Cheap dedup pre-check only; processNostrMessage does the
        // authoritative check-and-record before the off-main NIP-17 unwrap.
        // The outer signature was already verified (exactly once, off the
        // main actor) by NostrRelayManager, and only verified events are
        // recorded, so a forged-signature copy can never poison the dedup
        // set and suppress the genuine event.
        if context.hasProcessedNostrEvent(giftWrap.id) { return }

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.processNostrMessage(giftWrap)
        }
    }

    func processNostrMessage(_ giftWrap: NostrEvent) async {
        guard let context else { return }
        // Authoritative check-and-record, atomic on the main actor so two
        // concurrent detached tasks can't both process the same event.
        let alreadyProcessed: Bool = await MainActor.run {
            if context.hasProcessedNostrEvent(giftWrap.id) { return true }
            context.recordProcessedNostrEvent(giftWrap.id)
            return false
        }
        if alreadyProcessed { return }
        // Fetch the identity and the wipe generation in ONE main-actor hop:
        // the generation then vouches for exactly this identity. A wipe after
        // this point bumps the generation and the delivery hop below drops
        // the decrypted result (same guard as processGeohashGiftWrap; this
        // account-mailbox path had the identical hazard).
        let (currentIdentity, wipeGeneration): (NostrIdentity?, UInt64) = await MainActor.run {
            (context.currentNostrIdentity(), self.wipeGeneration)
        }
        guard let currentIdentity else { return }

        do {
            let (content, senderPubkey, rumorTimestamp) = try NostrProtocol.decryptPrivateMessage(
                giftWrap: giftWrap,
                recipientIdentity: currentIdentity
            )

            if content.hasPrefix("verify:") {
                return
            }

            if content.hasPrefix("bitchat1:") {
                let packet: BitchatPacket? = await MainActor.run {
                    Self.decodeEmbeddedBitChatPacket(from: content)
                }
                guard let packet else {
                    SecureLogger.error("Failed to decode embedded BitChat packet from Nostr DM", category: .session)
                    return
                }

                let actualSenderNoiseKey: Data? = await MainActor.run {
                    self.findNoiseKey(for: senderPubkey)
                }
                let targetPeerID = PeerID(str: actualSenderNoiseKey?.hexEncodedString()) ?? PeerID(nostr_: senderPubkey)

                if packet.type == MessageType.noiseEncrypted.rawValue,
                   let payload = NoisePayload.decode(packet.payload) {
                    let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(rumorTimestamp))
                    await MainActor.run {
                        // Drop pre-wipe plaintext if a panic wipe landed
                        // during the off-main decrypt (see above).
                        guard self.wipeGeneration == wipeGeneration else { return }
                        context.registerNostrKeyMapping(senderPubkey, for: targetPeerID)

                        switch payload.type {
                        case .privateMessage:
                            context.handlePrivateMessage(
                                payload,
                                senderPubkey: senderPubkey,
                                convKey: targetPeerID,
                                id: currentIdentity,
                                messageTimestamp: messageTimestamp
                            )
                        case .delivered:
                            context.handleDelivered(payload, senderPubkey: senderPubkey, convKey: targetPeerID)
                        case .readReceipt:
                            context.handleReadReceipt(payload, senderPubkey: senderPubkey, convKey: targetPeerID)
                        case .verifyChallenge, .verifyResponse:
                            break
                        }
                    }
                }
            } else {
                SecureLogger.debug("Ignoring non-embedded Nostr DM content", category: .session)
            }
        } catch {
            SecureLogger.error("Failed to decrypt Nostr message: \(error)", category: .session)
        }
    }

    /// Resolves the Noise static key behind a Nostr pubkey via the favorites
    /// store. Lives here because the inbound DM path needs it per message;
    /// the favorites glue in `ChatNostrCoordinator` delegates to it.
    @MainActor
    func findNoiseKey(for nostrPubkey: String) -> Data? {
        guard let context else { return nil }
        let favorites = context.allFavoriteRelationships()
        var npubToMatch = nostrPubkey

        if !nostrPubkey.hasPrefix("npub") {
            if let pubkeyData = Data(hexString: nostrPubkey),
               let encoded = try? Bech32.encode(hrp: "npub", data: pubkeyData) {
                npubToMatch = encoded
            } else {
                SecureLogger.warning(
                    "⚠️ Invalid hex public key format or encoding failed: \(nostrPubkey.prefix(16))...",
                    category: .session
                )
            }
        }

        for relationship in favorites {
            if let storedNostrKey = relationship.peerNostrPublicKey {
                if storedNostrKey == npubToMatch {
                    return relationship.peerNoisePublicKey
                }
                if !storedNostrKey.hasPrefix("npub") && storedNostrKey == nostrPubkey {
                    SecureLogger.debug("✅ Found Noise key for Nostr sender (hex match)", category: .session)
                    return relationship.peerNoisePublicKey
                }
            }
        }

        SecureLogger.debug(
            "⚠️ No matching Noise key found for Nostr pubkey: \(nostrPubkey.prefix(16))... (tried npub: \(npubToMatch.prefix(16))...)",
            category: .session
        )
        return nil
    }
}

private extension NostrInboundPipeline {
    @MainActor
    static func decodeEmbeddedBitChatPacket(from content: String) -> BitchatPacket? {
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
