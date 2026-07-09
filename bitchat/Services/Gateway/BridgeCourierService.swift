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
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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
        /// Coalescing window for dedup-record writes: a backlog re-fetch
        /// mutates the seen set once per event, and each snapshot save is a
        /// full JSON encode + atomic write on the main actor.
        static let dedupPersistCoalesceSeconds: TimeInterval = 1.0
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
    /// Returns false when the handoff could not even be attempted (peer no
    /// longer reachable), so the drop event stays retryable.
    var deliverToPeer: (@MainActor (CourierEnvelope, PeerID) -> Bool)?
    /// Held envelopes eligible for (re)publish, honoring the cooldown.
    var heldEnvelopes: (@MainActor (TimeInterval) -> [CourierEnvelope])?
    /// Timer injection for tests; nil arms a real `Task`.
    var scheduleTimer: (@MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void)?

    // MARK: State

    private(set) var myTagsHex: Set<String> = []
    private(set) var watchedPeerTags: [(peerID: PeerID, tagsHex: Set<String>)] = []
    private(set) var pendingDrops: [(envelope: CourierEnvelope, dedupKey: String?)] = []
    /// Message IDs already published as drops (sender-side dedup) and drop
    /// event IDs already handled (multi-relay dedup). Both persist across
    /// relaunches: relays hold drops for the full 24h NIP-40 window and the
    /// persisted outbox keeps re-depositing, so in-memory-only dedup meant
    /// every relaunch republished the same message as a fresh drop and every
    /// gateway relaunch re-delivered the whole backlog (field-verified
    /// amplification storm). Entries age out with the 24h drop window.
    private var publishedDropKeys: ExpiringIDSet
    private var seenDropEventIDs: ExpiringIDSet
    private var subscriptionOpen = false
    private var lastSubscribedTags: Set<String> = []
    private var refreshTimerArmed = false
    private var lastAnnounceRefresh = Date.distantPast

    private let now: () -> Date
    private let dedupStore: BridgeDropDedupStore

    private var dedupPersistScheduled = false

    init(now: @escaping () -> Date = Date.init, dedupStore: BridgeDropDedupStore? = nil) {
        self.now = now
        self.dedupStore = dedupStore ?? BridgeDropDedupStore(persistsToDisk: !TestEnvironment.isRunningTests)
        let snapshot = self.dedupStore.load()
        let date = now()
        self.publishedDropKeys = ExpiringIDSet(
            capacity: Limits.maxTrackedIDs,
            lifetime: CourierEnvelope.maxLifetimeSeconds,
            entries: snapshot.publishedDropKeys,
            now: date
        )
        self.seenDropEventIDs = ExpiringIDSet(
            capacity: Limits.maxTrackedIDs,
            lifetime: CourierEnvelope.maxLifetimeSeconds,
            entries: snapshot.seenDropEventIDs,
            now: date
        )
        // A coalesced dedup write scheduled just before a background kill
        // would be lost; flush when the app backgrounds or terminates.
        #if os(iOS)
        let flushNotifications = [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification]
        #else
        let flushNotifications = [NSApplication.willTerminateNotification]
        #endif
        for name in flushNotifications {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushDedupSnapshot() }
            }
        }
    }

    /// Schedules a coalesced write of the dedup record (see
    /// `Limits.dedupPersistCoalesceSeconds`); lifecycle notifications flush
    /// any scheduled write before a background kill could drop it.
    private func persistDedup() {
        guard !dedupPersistScheduled else { return }
        dedupPersistScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Limits.dedupPersistCoalesceSeconds * 1_000_000_000))
            guard let self else { return }
            self.dedupPersistScheduled = false
            self.flushDedupSnapshot()
        }
    }

    /// Writes the dedup record now. Sender keys still sitting in the
    /// in-memory `pendingDrops` queue are excluded: their drop is not durable
    /// until it actually reaches a relay, and persisting the key early would
    /// turn "app killed before relays connected" into a silent 24h blackhole
    /// (the relaunch loses the queued drop but the persisted key blocks every
    /// re-deposit). `flushPendingDrops` re-persists once they publish.
    func flushDedupSnapshot() {
        let pendingKeys = Set(pendingDrops.compactMap(\.dedupKey))
        dedupStore.save(BridgeDropDedupStore.Snapshot(
            publishedDropKeys: publishedDropKeys.entries.filter { !pendingKeys.contains($0.key) },
            seenDropEventIDs: seenDropEventIDs.entries
        ))
    }

    /// Panic wipe: forget queued drops and the persisted dedup record.
    func wipe() {
        pendingDrops.removeAll()
        publishedDropKeys = ExpiringIDSet(capacity: Limits.maxTrackedIDs, lifetime: CourierEnvelope.maxLifetimeSeconds)
        seenDropEventIDs = ExpiringIDSet(capacity: Limits.maxTrackedIDs, lifetime: CourierEnvelope.maxLifetimeSeconds)
        dedupStore.wipe()
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
        guard !publishedDropKeys.contains(messageID, now: now()) else { return false }
        guard let envelope = sealEnvelope?(content, messageID, recipientNoiseKey) else { return false }
        // An envelope that can't encode within the drop size caps fails the
        // same way on every attempt (size is a function of the content, not
        // of the sealing); consume the dedup slot so the retry sweep stops
        // re-running Noise sealing on a drop that can never ship.
        guard let encoded = envelope.encode(), encoded.count <= Limits.maxDropEnvelopeBytes else {
            publishedDropKeys.insert(messageID, now: now())
            persistDedup()
            return false
        }
        // Only consume the sender-side dedup slot once the drop is durably
        // accepted (published, or safely queued for the next relay
        // connection). If the compose fails, leave the slot open so the
        // router's retry sweep can attempt a fresh deposit rather than
        // marking the message "carried" and blocking retries forever.
        guard publishDrop(envelope, messageID: messageID) else { return false }
        publishedDropKeys.insert(messageID, now: now())
        persistDedup()
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
                if let key = evicted.dedupKey {
                    publishedDropKeys.remove(key)
                    persistDedup()
                }
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
            if let key = item.dedupKey {
                publishedDropKeys.remove(key)
            }
        }
        // Flushed keys just became durable (published, so no longer excluded
        // as pending) or were released above; either way the record changed.
        persistDedup()
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
        guard seenDropEventIDs.insert(event.id, now: now()) else { return }
        persistDedup()
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
            if deliverToPeer?(envelope, match.peerID) != true {
                // The best-effort handoff never left this device (the peer
                // walked away between the relay fetch and the mesh send).
                // Release the seen slot so a relaunch or backlog redelivery
                // retries — a single-gateway island has no other carrier.
                seenDropEventIDs.remove(event.id)
                persistDedup()
            }
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
