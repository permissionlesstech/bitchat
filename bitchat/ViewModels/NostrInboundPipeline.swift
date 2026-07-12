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
    /// `powBits` is the validated NIP-13 difficulty of the source event
    /// (`NostrPoW.validatedDifficulty`); it relaxes the per-sender rate limit
    /// downstream.
    func handlePublicMessage(_ message: BitchatMessage, powBits: Int)
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

/// The inbound Nostr hot path: raw relay events in, chat messages / Noise
/// payloads out. Pure transformation plus dedup — no relay lifecycle.
///
/// Ordering is deliberate and performance-critical: cheap rejects (kind,
/// dedup lookup) run BEFORE Schnorr signature verification because duplicates
/// dominate real relay traffic; events are recorded only AFTER verification so
/// a forged-signature copy can never poison the dedup set; private-envelope
/// verification for the account mailbox runs off-main with an atomic
/// main-actor check-and-record.
final class NostrInboundPipeline {
    private weak var context: (any NostrInboundPipelineContext)?
    private let presence: GeoPresenceTracker
    private var geoEventLogCount = 0
    // During the coordinated wire-format migration, one logical private
    // payload is published under both primary and compatibility formats. Outer
    // event IDs differ, so collapse the authenticated embedded payload before
    // invoking message/ack side effects. Keep this bounded like the outer-ID
    // caches; the recipient and authenticated sender are part of the key.
    private var recentPrivatePayloadFormats: [String: UInt8] = [:]
    private var recentPrivatePayloadKeyOrder: [String] = []
    private static let privatePayloadDedupCapacity = 2_048

    init(context: any NostrInboundPipelineContext, presence: GeoPresenceTracker) {
        self.context = context
        self.presence = presence
    }

    @MainActor
    func subscribeNostrEvent(_ event: NostrEvent) {
        guard let context else { return }
        // Cheap rejects (kind, dedup lookup) before Schnorr verification —
        // duplicates dominate real traffic and must not pay for crypto.
        // Only verified events are recorded, so a forged-signature copy can
        // never poison the dedup set and suppress the genuine event.
        guard (event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue
            || event.kind == NostrProtocol.EventKind.geohashPresence.rawValue),
              !context.hasProcessedNostrEvent(event.id)
        else {
            return
        }
        guard event.isValidSignature() else { return }

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
        let powBits = NostrPoW.validatedDifficulty(idHex: event.id, tags: event.tags)
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
            context.handlePublicMessage(message, powBits: powBits)
            if !isBlocked {
                context.checkForMentions(message)
                context.sendHapticFeedback(for: message)
            }
        }
    }

    @MainActor
    func handleNostrEvent(_ event: NostrEvent) {
        guard let context else { return }
        // Cheap rejects (kind, dedup lookup) before Schnorr verification —
        // duplicates dominate real traffic and must not pay for crypto.
        guard (event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue
            || event.kind == NostrProtocol.EventKind.geohashPresence.rawValue)
        else {
            return
        }
        if context.hasProcessedNostrEvent(event.id) { return }
        guard event.isValidSignature() else { return }
        context.recordProcessedNostrEvent(event.id)

        let powBits = NostrPoW.validatedDifficulty(idHex: event.id, tags: event.tags)

        // Sampled: fires for every geo event and floods dev logs in busy geohashes.
        geoEventLogCount += 1
        if geoEventLogCount == 1 || geoEventLogCount.isMultiple(of: TransportConfig.nostrInboundEventLogInterval) {
            SecureLogger.debug("GeoTeleport: recv #\(geoEventLogCount) pub=\(event.pubkey.prefix(8))… pow=\(powBits) tags=\(event.tags.map { "[" + $0.joined(separator: ",") + "]" }.joined(separator: ","))", category: .session)
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
            context.handlePublicMessage(message, powBits: powBits)
            context.checkForMentions(message)
            context.sendHapticFeedback(for: message)
        }
    }

    @MainActor
    func subscribePrivateEnvelope(_ envelope: NostrEvent, id: NostrIdentity) {
        guard let context else { return }
        // Dedup lookup before Schnorr verification; record only after it passes.
        guard !context.hasProcessedNostrEvent(envelope.id) else { return }
        guard envelope.content.utf8.count <= NostrProtocol.maximumPrivateEnvelopeCiphertextBytes else { return }
        guard envelope.isValidSignature() else { return }
        context.recordProcessedNostrEvent(envelope.id)

        guard let (content, senderPubkey, messageTs) = try? NostrProtocol.decryptPrivateEnvelope(
            envelope: envelope,
            recipientIdentity: id
        ),
        let packet = Self.decodeEmbeddedBitChatPacket(from: content),
        packet.type == MessageType.noiseEncrypted.rawValue,
        let noisePayload = NoisePayload.decode(packet.payload)
        else {
            return
        }
        guard shouldProcessPrivatePayload(
            noisePayload,
            senderPubkey: senderPubkey,
            recipientPubkey: id.publicKeyHex,
            envelopeKind: envelope.kind
        ) else { return }

        let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(messageTs))
        let convKey = PeerID(nostr_: senderPubkey)
        context.registerNostrKeyMapping(senderPubkey, for: convKey)

        switch noisePayload.type {
        case .privateMessage:
            context.handlePrivateMessage(
                noisePayload,
                senderPubkey: senderPubkey,
                convKey: convKey,
                id: id,
                messageTimestamp: messageTimestamp
            )
        case .delivered:
            context.handleDelivered(noisePayload, senderPubkey: senderPubkey, convKey: convKey)
        case .readReceipt:
            context.handleReadReceipt(noisePayload, senderPubkey: senderPubkey, convKey: convKey)
        // Group state travels only over mesh Noise sessions in v1; anything
        // claiming to be group traffic over Nostr is ignored.
        // Live voice is mesh-only: latency and relay cost make it
        // meaningless over Nostr.
        case .verifyChallenge, .verifyResponse, .groupInvite, .groupKeyUpdate, .vouch, .voiceFrame:
            break
        }
    }

    @MainActor
    func handlePrivateEnvelope(_ envelope: NostrEvent, id: NostrIdentity) {
        guard let context else { return }
        // Dedup lookup before Schnorr verification; record only after it passes.
        if context.hasProcessedNostrEvent(envelope.id) {
            return
        }
        guard envelope.content.utf8.count <= NostrProtocol.maximumPrivateEnvelopeCiphertextBytes else { return }
        guard envelope.isValidSignature() else { return }
        context.recordProcessedNostrEvent(envelope.id)

        guard let (content, senderPubkey, messageTs) = try? NostrProtocol.decryptPrivateEnvelope(
            envelope: envelope,
            recipientIdentity: id
        ) else {
            SecureLogger.warning("GeoDM: failed decrypt private envelope id=\(envelope.id.prefix(8))…", category: .session)
            return
        }

        SecureLogger.debug(
            "GeoDM: decrypted private envelope id=\(envelope.id.prefix(16))... from=\(senderPubkey.prefix(8))...",
            category: .session
        )

        guard let packet = Self.decodeEmbeddedBitChatPacket(from: content),
              packet.type == MessageType.noiseEncrypted.rawValue,
              let payload = NoisePayload.decode(packet.payload)
        else {
            return
        }
        guard shouldProcessPrivatePayload(
            payload,
            senderPubkey: senderPubkey,
            recipientPubkey: id.publicKeyHex,
            envelopeKind: envelope.kind
        ) else { return }

        let convKey = PeerID(nostr_: senderPubkey)
        context.registerNostrKeyMapping(senderPubkey, for: convKey)

        switch payload.type {
        case .privateMessage:
            let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(messageTs))
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
        // Group state travels only over mesh Noise sessions in v1; anything
        // claiming to be group traffic over Nostr is ignored.
        // Live voice is mesh-only: latency and relay cost make it
        // meaningless over Nostr.
        case .verifyChallenge, .verifyResponse, .groupInvite, .groupKeyUpdate, .vouch, .voiceFrame:
            break
        }
    }

    @MainActor
    func handleAccountPrivateEnvelope(_ envelope: NostrEvent) {
        guard let context else { return }
        // Cheap dedup pre-check only; Schnorr verification runs off-main in
        // processAccountPrivateEnvelope, which then does the authoritative
        // check-and-record. Recording stays after verification so a
        // forged-signature copy can never poison the dedup set and suppress
        // the genuine event.
        if context.hasProcessedNostrEvent(envelope.id) { return }

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.processAccountPrivateEnvelope(envelope)
        }
    }

    func processAccountPrivateEnvelope(_ envelope: NostrEvent) async {
        guard envelope.content.utf8.count <= NostrProtocol.maximumPrivateEnvelopeCiphertextBytes else { return }
        guard envelope.isValidSignature() else { return }
        guard let context else { return }
        // Authoritative check-and-record, atomic on the main actor so two
        // concurrent detached tasks can't both process the same event.
        let alreadyProcessed: Bool = await MainActor.run {
            if context.hasProcessedNostrEvent(envelope.id) { return true }
            context.recordProcessedNostrEvent(envelope.id)
            return false
        }
        if alreadyProcessed { return }
        let currentIdentity: NostrIdentity? = await MainActor.run {
            context.currentNostrIdentity()
        }
        guard let currentIdentity else { return }

        do {
            let (content, senderPubkey, messageTimestampSeconds) = try NostrProtocol.decryptPrivateEnvelope(
                envelope: envelope,
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
                    let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(messageTimestampSeconds))
                    await MainActor.run {
                        guard self.shouldProcessPrivatePayload(
                            payload,
                            senderPubkey: senderPubkey,
                            recipientPubkey: currentIdentity.publicKeyHex,
                            envelopeKind: envelope.kind
                        ) else { return }
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
                        // Group state travels only over mesh Noise sessions
                        // in v1; group traffic over Nostr is ignored.
                        // Live voice is mesh-only: latency and relay cost make it
                        // meaningless over Nostr.
                        case .verifyChallenge, .verifyResponse, .groupInvite, .groupKeyUpdate, .vouch, .voiceFrame:
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
    /// store. Lives here because the inbound DM path needs it per message.
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
    func shouldProcessPrivatePayload(
        _ payload: NoisePayload,
        senderPubkey: String,
        recipientPubkey: String,
        envelopeKind: Int
    ) -> Bool {
        let digest = payload.encode().sha256Fingerprint()
        let key = "\(recipientPubkey.lowercased()):\(senderPubkey.lowercased()):\(digest)"
        let formatBit: UInt8
        switch envelopeKind {
        case NostrProtocol.EventKind.privateEnvelope.rawValue:
            formatBit = 1 << 0
        case NostrProtocol.EventKind.legacyNIP59GiftWrap.rawValue:
            formatBit = 1 << 1
        default:
            return true
        }

        if let observedFormats = recentPrivatePayloadFormats[key] {
            if observedFormats & formatBit != 0 {
                // A same-format re-envelope is a delivery retry. Let it reach
                // the coordinator so a lost DELIVERED acknowledgement can be
                // sent again; downstream message-ID dedup prevents rerendering.
                return true
            }
            // The same authenticated payload under the other migration format
            // is the compatibility twin, not a new message or acknowledgement.
            recentPrivatePayloadFormats[key] = observedFormats | formatBit
            return false
        }

        recentPrivatePayloadFormats[key] = formatBit
        recentPrivatePayloadKeyOrder.append(key)
        if recentPrivatePayloadKeyOrder.count > Self.privatePayloadDedupCapacity {
            let evicted = recentPrivatePayloadKeyOrder.removeFirst()
            recentPrivatePayloadFormats.removeValue(forKey: evicted)
        }
        return true
    }

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
