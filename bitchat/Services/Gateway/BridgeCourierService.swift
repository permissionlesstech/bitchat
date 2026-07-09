//
// BridgeCourierService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import Foundation

/// Courier delivery over the internet bridge: sealed courier envelopes are
/// parked on relays as kind-1401 "drops" tagged with their rotating
/// recipient tag, so delivery stops requiring a physical courier to bump
/// into the recipient.
///
/// Three duties, all gated on the bridge toggle:
/// - Sender: when the message router seals mail for an unreachable peer, a
///   copy is published as a drop (queued until relays connect). The drop is
///   signed with a fresh throwaway key per publish — the envelope
///   authenticates its sender internally via Noise-X, and a stable publisher
///   key would leak courier traffic patterns to relays.
/// - Recipient: subscribes for its own candidate tags (adjacent UTC days)
///   and opens matching drops directly.
/// - Gateway (bridge + gateway toggles): additionally watches the tags of
///   verified local mesh peers and hands matching drops to them as directed
///   courier packets, so mesh-only recipients are served too.
///
/// Privacy: a drop reveals to relays only that "someone" is messaging "some
/// 16-byte day-rotating tag". Only parties who already know the recipient's
/// Noise static key can compute the tag; the payload is an opaque Noise-X
/// seal. Duplicate deliveries (drop + physical courier + direct link) are
/// absorbed downstream by message-ID dedup.
@MainActor
final class BridgeCourierService: ObservableObject {
    enum Limits {
        /// Drops waiting for relay connectivity (bounded, drop-oldest).
        static let maxPendingDrops = 20
        /// Republish cooldown for gateway-held envelopes.
        static let heldEnvelopePublishCooldown: TimeInterval = 30 * 60
        /// Local peers a gateway watches drops for (x3 candidate tags each).
        static let maxWatchedPeers = 16
        /// Tag-set refresh cadence (also covers UTC day rollover).
        static let refreshIntervalSeconds: TimeInterval = 30 * 60
        /// Minimum spacing for announce-driven refreshes.
        static let announceRefreshDebounceSeconds: TimeInterval = 60
        /// Encoded envelope cap for a drop (16 KiB ciphertext + TLV slack).
        static let maxDropEnvelopeBytes = 20 * 1024
        static let maxTrackedIDs = 512
    }

    static let shared = BridgeCourierService()

    // MARK: Wiring (set once by the bootstrapper; fakes in tests)

    var bridgeEnabled: (@MainActor () -> Bool)?
    var relaysConnected: (@MainActor () -> Bool)?
    /// Publishes a signed drop event to the default (DM) relays.
    var publishEvent: (@MainActor (NostrEvent) -> Void)?
    /// (Re)opens the drop subscription for the given hex tags.
    var openSubscription: (@MainActor ([String]) -> Void)?
    var closeSubscription: (@MainActor () -> Void)?
    /// Our own Noise static public key.
    var myNoiseKey: (@MainActor () -> Data?)?
    /// Verified reachable local peers with known Noise keys.
    var localVerifiedPeers: (@MainActor () -> [(peerID: PeerID, noiseKey: Data)])?
    /// Seals content into a carry-only envelope for a recipient key.
    var sealEnvelope: (@MainActor (String, String, Data) -> CourierEnvelope?)?
    /// Opens a drop addressed to us (tag verified inside).
    var openEnvelope: (@MainActor (CourierEnvelope) -> Void)?
    /// Hands a drop to a matching local peer as a directed courier packet.
    var deliverToPeer: (@MainActor (CourierEnvelope, PeerID) -> Void)?
    /// Held envelopes eligible for (re)publish, honoring the cooldown.
    var heldEnvelopes: (@MainActor (TimeInterval) -> [CourierEnvelope])?
    /// Timer injection for tests; nil arms a real `Task`.
    var scheduleTimer: (@MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void)?

    // MARK: State

    private(set) var myTagsHex: Set<String> = []
    private(set) var watchedPeerTags: [(peerID: PeerID, tagsHex: Set<String>)] = []
    private(set) var pendingDrops: [(envelope: CourierEnvelope, dedupKey: String?)] = []
    /// Message IDs already published as drops (sender-side dedup).
    private var publishedDropKeys: BoundedIDSet
    /// Drop event IDs already handled (multi-relay dedup).
    private var seenDropEventIDs: BoundedIDSet
    private var subscriptionOpen = false
    private var lastSubscribedTags: Set<String> = []
    private var refreshTimerArmed = false
    private var lastAnnounceRefresh = Date.distantPast

    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        self.publishedDropKeys = BoundedIDSet(capacity: Limits.maxTrackedIDs)
        self.seenDropEventIDs = BoundedIDSet(capacity: Limits.maxTrackedIDs)
    }

    // MARK: - Sender role

    /// Parallel-deposit a sealed copy of an outbound private message as a
    /// relay drop. Called by the message router alongside physical courier
    /// deposits; idempotent per message ID. Returns true when a fresh drop
    /// was sealed (published now or queued for the next relay connection) —
    /// the router marks the message "carried" so the sender sees progress.
    @discardableResult
    func depositDrop(content: String, messageID: String, recipientNoiseKey: Data) -> Bool {
        guard bridgeEnabled?() ?? false else { return false }
        guard !publishedDropKeys.contains(messageID) else { return false }
        guard let envelope = sealEnvelope?(content, messageID, recipientNoiseKey) else { return false }
        // Only consume the sender-side dedup slot once the drop is durably
        // accepted (published, or safely queued for the next relay
        // connection). If the compose fails, leave the slot open so the
        // router's retry sweep can attempt a fresh deposit rather than
        // marking the message "carried" and blocking retries forever.
        guard publishDrop(envelope, messageID: messageID) else { return false }
        publishedDropKeys.insert(messageID)
        return true
    }

    /// Publishes held envelopes (mail we carry for others) as drops,
    /// honoring the per-envelope cooldown.
    func publishHeldEnvelopes() {
        guard bridgeEnabled?() ?? false, relaysConnected?() ?? false else { return }
        for envelope in heldEnvelopes?(Limits.heldEnvelopePublishCooldown) ?? [] {
            publishDrop(envelope)
        }
    }

    /// Publishes a drop, or queues it when relays are down. `messageID` is the
    /// sender-side dedup key (nil for held/relayed envelopes we don't track);
    /// it rides the pending queue so an evicted drop can release its slot.
    /// Returns false only when the drop could not be made durable (bad
    /// encode/expired/compose failure) so callers can keep it retryable.
    @discardableResult
    private func publishDrop(_ envelope: CourierEnvelope, messageID: String? = nil) -> Bool {
        guard let encoded = envelope.encode(),
              encoded.count <= Limits.maxDropEnvelopeBytes,
              !envelope.isExpired else { return false }
        guard relaysConnected?() ?? false else {
            pendingDrops.append((envelope, messageID))
            while pendingDrops.count > Limits.maxPendingDrops {
                let evicted = pendingDrops.removeFirst()
                // The oldest queued drop is being dropped before it ever
                // published; release its dedup slot so it stays retryable.
                if let key = evicted.dedupKey { publishedDropKeys.remove(key) }
            }
            return true
        }
        guard let identity = try? NostrIdentity.generate(),
              let event = try? NostrProtocol.createCourierDropEvent(
                envelope: encoded,
                recipientTagHex: envelope.recipientTag.hexEncodedString(),
                expiresAt: Date(timeIntervalSince1970: TimeInterval(envelope.expiry) / 1000),
                senderIdentity: identity
              ) else {
            SecureLogger.error("📦🌉 Failed to compose courier drop", category: .encryption)
            return false
        }
        publishEvent?(event)
        SecureLogger.debug("📦🌉 Published courier drop for tag \(envelope.recipientTag.hexEncodedString().prefix(8))…", category: .session)
        return true
    }

    /// Drops queued while relays were unreachable publish on reconnect.
    func flushPendingDrops() {
        guard bridgeEnabled?() ?? false, relaysConnected?() ?? false, !pendingDrops.isEmpty else { return }
        let queued = pendingDrops
        pendingDrops.removeAll()
        for item in queued where !publishDrop(item.envelope, messageID: item.dedupKey) {
            // Compose failed with relays up: release the slot so the router's
            // retry sweep can attempt a fresh deposit.
            if let key = item.dedupKey { publishedDropKeys.remove(key) }
        }
    }

    // MARK: - Subscription (recipient + gateway watch)

    /// Recomputes the watched tag set and (re)opens the subscription.
    /// Call on toggle changes, relay connectivity changes, and periodically
    /// (tags rotate daily); idempotent.
    func refresh() {
        armRefreshTimerIfNeeded()
        guard bridgeEnabled?() ?? false, relaysConnected?() ?? false else {
            if subscriptionOpen {
                closeSubscription?()
                subscriptionOpen = false
            }
            return
        }
        let date = now()
        if let myKey = myNoiseKey?() {
            myTagsHex = Set(CourierEnvelope.candidateTags(noiseStaticKey: myKey, around: date).map { $0.hexEncodedString() })
        } else {
            myTagsHex = []
        }
        // While bridging with internet, every device watches drops for its
        // verified local peers — the single-switch analogue of gateway duty.
        let peers = (localVerifiedPeers?() ?? []).prefix(Limits.maxWatchedPeers)
        watchedPeerTags = peers.map { peer in
            (peer.peerID, Set(CourierEnvelope.candidateTags(noiseStaticKey: peer.noiseKey, around: date).map { $0.hexEncodedString() }))
        }
        let allTags = myTagsHex.union(watchedPeerTags.flatMap(\.tagsHex))
        guard !allTags.isEmpty else {
            if subscriptionOpen {
                closeSubscription?()
                subscriptionOpen = false
                lastSubscribedTags = []
            }
            return
        }
        // Resubscribe only when the watched set actually changed — refresh
        // fires on every verified announce (field logs showed the drop
        // subscription rebuilt every ~60s for an unchanged tag set).
        if !subscriptionOpen || allTags != lastSubscribedTags {
            openSubscription?(allTags.sorted())
            subscriptionOpen = true
            lastSubscribedTags = allTags
        }
        flushPendingDrops()
        publishHeldEnvelopes()
    }

    /// Announce-driven refresh, debounced — a newly verified peer should be
    /// watched promptly, but announce storms must not thrash subscriptions.
    func refreshAfterVerifiedAnnounce() {
        guard bridgeEnabled?() ?? false else { return }
        guard now().timeIntervalSince(lastAnnounceRefresh) >= Limits.announceRefreshDebounceSeconds else { return }
        lastAnnounceRefresh = now()
        refresh()
    }

    private func armRefreshTimerIfNeeded() {
        guard bridgeEnabled?() ?? false, !refreshTimerArmed else { return }
        refreshTimerArmed = true
        let fire: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.refreshTimerArmed = false
            self.refresh()
        }
        if let scheduleTimer {
            scheduleTimer(Limits.refreshIntervalSeconds, fire)
        } else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Limits.refreshIntervalSeconds * 1_000_000_000))
                fire()
            }
        }
    }

    // MARK: - Inbound drops

    /// Entry point for every drop event the subscription delivers (the relay
    /// manager has already verified the event signature).
    func handleDropEvent(_ event: NostrEvent) {
        guard bridgeEnabled?() ?? false else { return }
        guard event.kind == NostrProtocol.EventKind.courierDrop.rawValue else { return }
        guard seenDropEventIDs.insert(event.id) else { return }
        guard let data = Data(base64Encoded: event.content),
              data.count <= Limits.maxDropEnvelopeBytes,
              let envelope = CourierEnvelope.decode(data),
              !envelope.isExpired else {
            return
        }
        let tagHex = envelope.recipientTag.hexEncodedString()
        // The envelope's own tag must match the event's filterable tag —
        // otherwise a mislabeled drop could ride a subscription it doesn't
        // belong to.
        guard event.tags.contains(where: { $0.count >= 2 && $0[0] == "x" && $0[1] == tagHex }) else { return }

        if myTagsHex.contains(tagHex) {
            SecureLogger.info("📦🌉 Courier drop for us arrived via bridge", category: .session)
            openEnvelope?(envelope)
            return
        }
        if let match = watchedPeerTags.first(where: { $0.tagsHex.contains(tagHex) }) {
            SecureLogger.info("📦🌉 Courier drop fetched for local peer \(match.peerID.id.prefix(8))…", category: .session)
            deliverToPeer?(envelope, match.peerID)
        }
    }

    // MARK: - Helpers

    /// A fresh random Nostr identity for signing one drop. Delegates to the
    /// canonical generator (Schnorr key that can't fail validity) instead of
    /// hand-rolling SecRandom + retry.
    static func makeThrowawayIdentity() -> NostrIdentity? {
        try? NostrIdentity.generate()
    }
}
