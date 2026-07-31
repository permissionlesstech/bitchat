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
    /// Publishes a signed drop event directly to connected default (DM)
    /// relays. Completion is true only after at least one relay explicitly
    /// accepts the event via NIP-20 OK; this must never mean "queued in RAM"
    /// or merely "written to a socket".
    var publishEvent: (@MainActor (NostrEvent, @escaping @MainActor (Bool) -> Void) -> Void)?
    /// (Re)opens the drop subscription for the given hex tags.
    var openSubscription: (@MainActor ([String]) -> Void)?
    var closeSubscription: (@MainActor () -> Void)?
    /// Our own Noise static public key.
    var myNoiseKey: (@MainActor () -> Data?)?
    /// Verified reachable local peers with known Noise keys.
    var localVerifiedPeers: (@MainActor () -> [(peerID: PeerID, noiseKey: Data)])?
    /// Seals content into a carry-only envelope for a recipient key.
    var sealEnvelope: (@MainActor (String, String, Data) -> CourierEnvelope?)?
    /// Opens a drop addressed to us. True means the inner envelope was
    /// delivered, deduplicated, or intentionally rejected after decryption;
    /// false leaves the relay event retryable after a transient crypto/key
    /// failure.
    var openEnvelope: (@MainActor (CourierEnvelope) -> Bool)?
    /// Hands a drop to a matching local peer as a directed courier packet.
    /// Returns true only when the transport accepted the packet onto a live
    /// physical link or its link-specific backpressure queue. Stale
    /// reachability and process-local directed spooling return false so the
    /// drop event stays retryable.
    var deliverToPeer: (@MainActor (CourierEnvelope, PeerID) -> Bool)?
    /// Held envelopes eligible for (re)publish, honoring the cooldown.
    var heldEnvelopes: (@MainActor (TimeInterval) -> [CourierEnvelope])?
    /// Commits a held envelope's cooldown after confirmed relay acceptance.
    var markHeldEnvelopePublished: (@MainActor (CourierEnvelope) -> Void)?
    /// Timer injection for tests; nil arms a real `Task`.
    var scheduleTimer: (@MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void)?

    // MARK: State

    private(set) var myTagsHex: Set<String> = []
    private(set) var watchedPeerTags: [(peerID: PeerID, tagsHex: Set<String>)] = []
    private(set) var pendingDrops: [(
        envelope: CourierEnvelope,
        dedupKey: String?,
        operationID: UUID?
    )] = []
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
    private var announceRefreshTimerArmed = false
    private var lastAnnounceRefresh = Date.distantPast
    private struct ActiveDropOperation {
        let id: UUID
        let completion: @MainActor (Bool) -> Void
    }
    /// Sender operations queued locally or awaiting relay confirmation.
    /// The per-attempt ID prevents a stale pre-wipe callback from completing
    /// a newer attempt for the same message.
    private var activeDropOperations: [String: ActiveDropOperation] = [:]
    /// Held-envelope publishes have no sender message ID, but still need an
    /// in-flight identity: repeated refreshes inside the NIP-20 wait window
    /// must not mint duplicate relay events for the same opaque envelope.
    private var heldDropOperations: [Data: UUID] = [:]
    /// Deterministically invalid envelopes are suppressed for this process,
    /// but never persisted as if a relay accepted them. Bound and age them so
    /// rotating oversize IDs cannot grow process memory forever.
    private var rejectedDropKeys = ExpiringIDSet(
        capacity: Limits.maxTrackedIDs,
        lifetime: CourierEnvelope.maxLifetimeSeconds
    )

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

    /// Writes the dedup record now. `publishedDropKeys` contains only drops
    /// a relay explicitly accepted; queued and in-flight keys
    /// live in `activeDropOperations` and are intentionally process-local.
    func flushDedupSnapshot() {
        dedupStore.save(BridgeDropDedupStore.Snapshot(
            publishedDropKeys: publishedDropKeys.entries,
            seenDropEventIDs: seenDropEventIDs.entries
        ))
    }

    /// Panic wipe: forget queued drops and the persisted dedup record.
    func wipe() {
        cancelActivePublishes()
        rejectedDropKeys = ExpiringIDSet(
            capacity: Limits.maxTrackedIDs,
            lifetime: CourierEnvelope.maxLifetimeSeconds
        )
        publishedDropKeys = ExpiringIDSet(capacity: Limits.maxTrackedIDs, lifetime: CourierEnvelope.maxLifetimeSeconds)
        seenDropEventIDs = ExpiringIDSet(capacity: Limits.maxTrackedIDs, lifetime: CourierEnvelope.maxLifetimeSeconds)
        dedupStore.wipe()
    }

    // MARK: - Sender role

    /// Parallel-deposit a sealed copy of an outbound private message as a
    /// relay drop. Called by the message router alongside physical courier
    /// deposits; idempotent per message ID. Completion becomes true only
    /// after a real relay acceptance arrives, which is when the router may
    /// show "carried".
    func depositDrop(
        content: String,
        messageID: String,
        recipientNoiseKey: Data,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        guard bridgeEnabled?() ?? false else {
            completion(false)
            return
        }
        guard !publishedDropKeys.contains(messageID, now: now()),
              activeDropOperations[messageID] == nil,
              !rejectedDropKeys.contains(messageID, now: now()) else {
            completion(false)
            return
        }
        guard let envelope = sealEnvelope?(content, messageID, recipientNoiseKey) else {
            completion(false)
            return
        }
        // An envelope that can't encode within the drop size caps fails the
        // same way on every attempt (size is a function of the content, not
        // of the sealing); suppress it in-memory so the retry sweep does not
        // churn, but never persist it as a published drop.
        guard let encoded = envelope.encode(), encoded.count <= Limits.maxDropEnvelopeBytes else {
            rejectedDropKeys.insert(messageID, now: now())
            completion(false)
            return
        }
        let operationID = UUID()
        activeDropOperations[messageID] = ActiveDropOperation(id: operationID, completion: completion)
        publishDrop(envelope, messageID: messageID, operationID: operationID)
    }

    /// Publishes held envelopes (mail we carry for others) as drops,
    /// honoring the per-envelope cooldown.
    func publishHeldEnvelopes() {
        guard bridgeEnabled?() ?? false, relaysConnected?() ?? false else { return }
        for envelope in heldEnvelopes?(Limits.heldEnvelopePublishCooldown) ?? [] {
            let key = envelope.ciphertext
            guard heldDropOperations[key] == nil else { continue }
            let operationID = UUID()
            heldDropOperations[key] = operationID
            publishDrop(envelope) { [weak self] succeeded in
                guard let self, self.heldDropOperations[key] == operationID else { return }
                self.heldDropOperations.removeValue(forKey: key)
                if succeeded {
                    self.markHeldEnvelopePublished?(envelope)
                }
            }
        }
    }

    /// Publishes a drop, or queues it when relays are down. `messageID` is the
    /// sender-side dedup key (nil for held/relayed envelopes we don't track);
    /// it rides the pending queue so an evicted or failed drop can release its
    /// in-flight slot. Completion reports actual NIP-20 relay acceptance.
    private func publishDrop(
        _ envelope: CourierEnvelope,
        messageID: String? = nil,
        operationID: UUID? = nil,
        untrackedCompletion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard let encoded = envelope.encode(),
              encoded.count <= Limits.maxDropEnvelopeBytes,
              !envelope.isExpired else {
            finishPublish(
                messageID: messageID,
                operationID: operationID,
                succeeded: false,
                untrackedCompletion: untrackedCompletion
            )
            return
        }
        guard relaysConnected?() ?? false else {
            // Held mail remains in CourierStore and has no sender operation to
            // recover after an in-memory queue loss. Leave its cooldown unset
            // and let the next connected refresh offer it again.
            guard messageID != nil else {
                untrackedCompletion?(false)
                return
            }
            pendingDrops.append((envelope, messageID, operationID))
            while pendingDrops.count > Limits.maxPendingDrops {
                let evicted = pendingDrops.removeFirst()
                finishPublish(
                    messageID: evicted.dedupKey,
                    operationID: evicted.operationID,
                    succeeded: false
                )
            }
            return
        }
        guard let identity = try? NostrIdentity.generate(),
              let event = try? NostrProtocol.createCourierDropEvent(
                envelope: encoded,
                recipientTagHex: envelope.recipientTag.hexEncodedString(),
                expiresAt: Date(timeIntervalSince1970: TimeInterval(envelope.expiry) / 1000),
                senderIdentity: identity
              ) else {
            SecureLogger.error("📦🌉 Failed to compose courier drop", category: .encryption)
            finishPublish(
                messageID: messageID,
                operationID: operationID,
                succeeded: false,
                untrackedCompletion: untrackedCompletion
            )
            return
        }
        guard let publishEvent else {
            SecureLogger.error("📦🌉 Courier drop publisher is not configured", category: .session)
            finishPublish(
                messageID: messageID,
                operationID: operationID,
                succeeded: false,
                untrackedCompletion: untrackedCompletion
            )
            return
        }
        publishEvent(event) { [weak self] succeeded in
            guard let self else { return }
            guard self.finishPublish(
                messageID: messageID,
                operationID: operationID,
                succeeded: succeeded,
                untrackedCompletion: untrackedCompletion
            ) else { return }
            if succeeded {
                SecureLogger.debug("📦🌉 Published courier drop for tag \(envelope.recipientTag.hexEncodedString().prefix(8))…", category: .session)
            } else {
                SecureLogger.warning("📦🌉 No relay accepted courier drop", category: .session)
            }
        }
    }

    @discardableResult
    private func finishPublish(
        messageID: String?,
        operationID: UUID?,
        succeeded: Bool,
        untrackedCompletion: (@MainActor (Bool) -> Void)? = nil
    ) -> Bool {
        guard let messageID else {
            untrackedCompletion?(succeeded)
            return true
        }
        // Missing/mismatched means this callback was duplicated, invalidated
        // by panic wipe, or belongs to an older attempt for the same key.
        guard let operationID,
              let operation = activeDropOperations[messageID],
              operation.id == operationID else { return false }
        activeDropOperations.removeValue(forKey: messageID)
        if succeeded {
            publishedDropKeys.insert(messageID, now: now())
            persistDedup()
        }
        operation.completion(succeeded)
        return true
    }

    /// Drops queued while relays were unreachable publish on reconnect.
    func flushPendingDrops() {
        guard bridgeEnabled?() ?? false, relaysConnected?() ?? false, !pendingDrops.isEmpty else { return }
        let queued = pendingDrops
        pendingDrops.removeAll()
        for item in queued {
            publishDrop(
                item.envelope,
                messageID: item.dedupKey,
                operationID: item.operationID
            )
        }
    }

    // MARK: - Subscription (recipient + gateway watch)

    /// Recomputes the watched tag set and (re)opens the subscription.
    /// Call on toggle changes, relay connectivity changes, and periodically
    /// (tags rotate daily); idempotent.
    func refresh() {
        armRefreshTimerIfNeeded()
        guard bridgeEnabled?() ?? false else {
            cancelActivePublishes()
            if subscriptionOpen {
                closeSubscription?()
                subscriptionOpen = false
            }
            return
        }
        guard relaysConnected?() ?? false else {
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
    /// Calls inside the window coalesce into one trailing refresh so peers
    /// learned after the leading edge are not omitted until the 30-minute
    /// periodic timer.
    func refreshAfterVerifiedAnnounce() {
        guard bridgeEnabled?() ?? false else { return }
        let date = now()
        let elapsed = date.timeIntervalSince(lastAnnounceRefresh)
        if elapsed >= Limits.announceRefreshDebounceSeconds {
            lastAnnounceRefresh = date
            refresh()
            return
        }

        guard !announceRefreshTimerArmed else { return }
        announceRefreshTimerArmed = true
        let delay = max(0, Limits.announceRefreshDebounceSeconds - elapsed)
        let fire: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.announceRefreshTimerArmed = false
            guard self.bridgeEnabled?() ?? false else { return }
            self.lastAnnounceRefresh = self.now()
            self.refresh()
        }
        if let scheduleTimer {
            scheduleTimer(delay, fire)
        } else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                fire()
            }
        }
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
        // A resubscribe can still deliver an event from the old watch set.
        // Do not durably consume it until it actually belongs to us/current
        // local peer and is opened or accepted for physical delivery.
        guard !seenDropEventIDs.contains(event.id, now: now()) else { return }
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
            if openEnvelope?(envelope) == true {
                seenDropEventIDs.insert(event.id, now: now())
                persistDedup()
            }
            return
        }
        if let match = watchedPeerTags.first(where: { $0.tagsHex.contains(tagHex) }) {
            SecureLogger.info("📦🌉 Courier drop fetched for local peer \(match.peerID.id.prefix(8))…", category: .session)
            if deliverToPeer?(envelope, match.peerID) == true {
                seenDropEventIDs.insert(event.id, now: now())
                persistDedup()
            }
        }
    }

    // MARK: - Helpers

    /// Cancels queued and in-flight sender operations after bridge disable or
    /// panic wipe. Invalidate first, then resolve false so callback re-entry
    /// cannot be mistaken for an active operation; late relay callbacks no-op.
    private func cancelActivePublishes() {
        let invalidated = activeDropOperations.values.map(\.completion)
        pendingDrops.removeAll()
        activeDropOperations.removeAll()
        // Untracked held publishes are invalidated too. Their late relay
        // callbacks compare operation IDs and no-op after this reset.
        heldDropOperations.removeAll()
        invalidated.forEach { $0(false) }
    }

    /// A fresh random Nostr identity for signing one drop. Delegates to the
    /// canonical generator (Schnorr key that can't fail validity) instead of
    /// hand-rolling SecRandom + retry.
    static func makeThrowawayIdentity() -> NostrIdentity? {
        try? NostrIdentity.generate()
    }
}
