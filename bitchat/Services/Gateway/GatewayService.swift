//
// GatewayService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import Combine
import Foundation

/// Policy engine for gateway mode: an opt-in "share my internet with the
/// mesh" bridge. While the toggle is on, this device advertises the
/// `.gateway` capability bit, publishes signed geohash events deposited by
/// mesh-only peers to Nostr relays (uplink), and rebroadcasts inbound relay
/// events onto the mesh (downlink) so mesh-only peers can take part in the
/// local geohash channel. Mesh-only peers need no toggle: their uplink
/// engages automatically when relays are unreachable and a gateway peer
/// exists.
///
/// Threat model:
/// - Keys never leave the originating device. Mesh-only senders sign events
///   locally with their per-geohash ephemeral identity; the gateway carries
///   only the finished, signed event.
/// - The gateway cannot forge or alter events: every carried event is
///   Schnorr-verified here before it is published or rebroadcast, and again
///   independently by relays and receivers.
/// - Carried contents are public geohash chat, already plaintext on Nostr,
///   so the mesh carrier adds no confidentiality loss.
///
/// Loop-prevention rules (each enforced here and unit-tested):
/// 1. An event learned from a `fromGateway` mesh broadcast is never
///    re-published to relays, never re-uplinked, and never rebroadcast
///    (`meshBroadcastEventIDs`), so a second gateway on the same mesh cannot
///    echo mesh-carried traffic back out. Mesh-level propagation of the
///    original broadcast packet is the TTL relay's job, not ours.
/// 2. An uplink deposit is published at most once (`publishedEventIDs`) and
///    a relay event is rebroadcast at most once (`rebroadcastEventIDs`), so
///    repeat deposits and relay echoes are absorbed.
/// 3. Uplink is only attempted for locally composed events at the send site
///    (`GeohashSubscriptionManager.sendGeohash`); events received over the
///    carrier never re-enter the uplink path.
/// Rebroadcast storms at the mesh layer are additionally bounded by the BLE
/// `MessageDeduplicator` and packet TTL, and receivers dedup carried events
/// against their own relay subscriptions via the Nostr event-ID cache in
/// `NostrInboundPipeline`.
///
/// All dependencies are closure-injected (repo convention) so the policy
/// layer is unit-testable without relays or radios.
@MainActor
final class GatewayService: ObservableObject {
    enum Limits {
        /// Uplink deposits held while relays are unreachable (CourierStore-style
        /// bounded mailbag: bounded total, bounded per depositor).
        static let maxQueuedUplinks = 20
        static let maxQueuedUplinksPerDepositor = 5
        /// Uplink deposits accepted per depositor per minute.
        static let uplinkEventsPerMinutePerDepositor = 10
        /// Downlink mesh rebroadcasts per minute — BLE airtime is precious.
        /// Beyond the budget events queue (bounded, drop-oldest) and drain as
        /// the window frees; a busy channel triggers frequent drains, a quiet
        /// one never queues.
        static let downlinkEventsPerMinute = 30
        static let maxPendingDownlinks = 30
        /// Accepted clock skew for a carried ephemeral event; anything older
        /// is stale replay the relays would drop anyway.
        static let maxEventAgeSeconds: TimeInterval = 15 * 60
        /// Bounded loop-prevention ID caches (oldest evicted).
        static let maxTrackedEventIDs = 512
    }

    struct QueuedUplink {
        let depositor: PeerID
        let geohash: String
        let event: NostrEvent
        let queuedAt: Date
    }

    static let shared = GatewayService()

    /// The user toggle. While true this device advertises `.gateway` and
    /// bridges mesh <-> Nostr for geohash channels.
    @Published private(set) var isEnabled: Bool

    // MARK: Wiring (set once by the bootstrapper; fakes in tests)

    /// Publishes a verified event to the geo relays for a geohash.
    var publishToRelays: (@MainActor (NostrEvent, String) -> Void)?
    /// Broadcasts an encoded `fromGateway` carrier payload on the mesh.
    var broadcastToMesh: (@MainActor (Data) -> Void)?
    /// Sends an encoded `toGateway` carrier payload directed to a gateway
    /// peer. Returns false when the transport could not accept it.
    var sendToGatewayPeer: (@MainActor (Data, PeerID) -> Bool)?
    /// Reachable mesh peers currently advertising the `.gateway` capability.
    var availableGatewayPeers: (@MainActor () -> [PeerID])?
    /// Whether any Nostr relay connection is currently working.
    var relaysConnected: (@MainActor () -> Bool)?
    /// The geohash channel the local user is viewing, if any.
    var currentGeohash: (@MainActor () -> String?)?
    /// Injects a verified carried event into the same inbound pipeline as
    /// relay-received events (blocking, rate limits, dedup, rendering).
    var injectInbound: (@MainActor (NostrEvent) -> Void)?
    /// Fired on toggle changes (advertise/withdraw the capability bit and
    /// force a re-announce).
    var onEnabledChanged: (@MainActor (Bool) -> Void)?

    // MARK: State

    /// Loop rule 1: event IDs seen in `fromGateway` mesh broadcasts.
    private var meshBroadcastEventIDs: BoundedIDSet
    /// Loop rule 2 (uplink): event IDs this gateway already published.
    private var publishedEventIDs: BoundedIDSet
    /// Loop rule 2 (downlink): event IDs this gateway already rebroadcast.
    private var rebroadcastEventIDs: BoundedIDSet

    private(set) var queuedUplinks: [QueuedUplink] = []
    private var uplinkDepositTimes: [PeerID: [Date]] = [:]
    private var downlinkSendTimes: [Date] = []
    private var pendingDownlinks: [(event: NostrEvent, geohash: String)] = []

    private let defaults: UserDefaults
    private let now: () -> Date
    private static let enabledKey = "gateway.userEnabled"

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.meshBroadcastEventIDs = BoundedIDSet(capacity: Limits.maxTrackedEventIDs)
        self.publishedEventIDs = BoundedIDSet(capacity: Limits.maxTrackedEventIDs)
        self.rebroadcastEventIDs = BoundedIDSet(capacity: Limits.maxTrackedEventIDs)
    }

    // MARK: - Toggle

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled {
            queuedUplinks.removeAll()
            pendingDownlinks.removeAll()
            uplinkDepositTimes.removeAll()
        }
        SecureLogger.info("🌐 Gateway mode \(enabled ? "enabled" : "disabled")", category: .session)
        onEnabledChanged?(enabled)
    }

    // MARK: - Mesh carrier ingress (both roles)

    /// Entry point for received `nostrCarrier` packets. `directedToUs` is
    /// true for packets addressed to this device (uplink deposits); false
    /// for broadcasts (downlink rebroadcasts from a gateway).
    func handleMeshCarrier(_ payload: Data, from peerID: PeerID, directedToUs: Bool) {
        guard let carrier = NostrCarrierPacket.decode(payload) else {
            SecureLogger.debug("🌐 Gateway: dropping undecodable carrier from \(peerID.id.prefix(8))…", category: .session)
            return
        }
        switch carrier.direction {
        case .toGateway:
            // Uplink deposits are directed; a broadcast toGateway is malformed.
            guard directedToUs else { return }
            handleUplinkDeposit(carrier, from: peerID)
        case .fromGateway:
            // Downlink rides broadcast only; a directed fromGateway is malformed.
            guard !directedToUs else { return }
            handleDownlinkBroadcast(carrier)
        }
    }

    // MARK: - Uplink (gateway role: mesh peer -> internet)

    private func handleUplinkDeposit(_ carrier: NostrCarrierPacket, from depositor: PeerID) {
        guard isEnabled else { return }
        guard let event = validatedEvent(from: carrier) else {
            SecureLogger.debug("🌐 Gateway: rejected uplink deposit from \(depositor.id.prefix(8))… (failed validation)", category: .security)
            return
        }
        // Loop rule 1: events learned from a fromGateway broadcast are
        // mesh-carried; a gateway must never re-publish them.
        guard !meshBroadcastEventIDs.contains(event.id) else { return }
        // Loop rule 2: repeat deposits of an already handled event are absorbed.
        guard !publishedEventIDs.contains(event.id),
              !queuedUplinks.contains(where: { $0.event.id == event.id }) else {
            return
        }
        guard allowUplinkDeposit(from: depositor) else {
            SecureLogger.debug("🌐 Gateway: rate-limited uplink deposit from \(depositor.id.prefix(8))…", category: .session)
            return
        }

        if relaysConnected?() ?? false {
            publish(event, geohash: carrier.geohash)
        } else {
            enqueueUplink(QueuedUplink(depositor: depositor, geohash: carrier.geohash, event: event, queuedAt: now()))
        }

        // Show the carried message on our own timeline when we're viewing
        // that geohash; the relay echo (if any) dedups in the pipeline.
        if currentGeohash?() == carrier.geohash {
            injectInbound?(event)
        }
    }

    /// Publish everything queued while relays were unreachable. Called when
    /// relay connectivity comes back.
    func flushQueuedUplinks() {
        guard isEnabled, relaysConnected?() ?? false, !queuedUplinks.isEmpty else { return }
        let queued = queuedUplinks
        queuedUplinks.removeAll()
        for item in queued where !publishedEventIDs.contains(item.event.id) {
            publish(item.event, geohash: item.geohash)
        }
    }

    private func publish(_ event: NostrEvent, geohash: String) {
        publishedEventIDs.insert(event.id)
        publishToRelays?(event, geohash)
        SecureLogger.info("🌐 Gateway: published carried event \(event.id.prefix(8))… to relays for #\(geohash)", category: .session)
    }

    private func enqueueUplink(_ item: QueuedUplink) {
        let fromDepositor = queuedUplinks.filter { $0.depositor == item.depositor }.count
        guard fromDepositor < Limits.maxQueuedUplinksPerDepositor else {
            SecureLogger.debug("🌐 Gateway: uplink queue quota reached for \(item.depositor.id.prefix(8))…", category: .session)
            return
        }
        if queuedUplinks.count >= Limits.maxQueuedUplinks {
            queuedUplinks.removeFirst(queuedUplinks.count - Limits.maxQueuedUplinks + 1)
        }
        queuedUplinks.append(item)
    }

    private func allowUplinkDeposit(from depositor: PeerID) -> Bool {
        let cutoff = now().addingTimeInterval(-60)
        var times = uplinkDepositTimes[depositor, default: []]
        times.removeAll { $0 < cutoff }
        guard times.count < Limits.uplinkEventsPerMinutePerDepositor else {
            uplinkDepositTimes[depositor] = times
            return false
        }
        times.append(now())
        uplinkDepositTimes[depositor] = times
        // Bound the tracker itself against a churn of spoofed depositors.
        if uplinkDepositTimes.count > Limits.maxTrackedEventIDs {
            uplinkDepositTimes = uplinkDepositTimes.filter { !$0.value.isEmpty && $0.value.contains { $0 >= cutoff } }
        }
        return true
    }

    // MARK: - Downlink (gateway role: internet -> mesh)

    /// Called for every event the gateway's own geohash-channel subscription
    /// delivers. Wraps it in a `fromGateway` carrier and broadcasts it on
    /// the mesh, within the airtime budget.
    func rebroadcastRelayEvent(_ event: NostrEvent, geohash: String) {
        guard isEnabled, broadcastToMesh != nil else { return }
        guard event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue else { return }
        // Loop rule 1: never rebroadcast mesh-carried events back onto the
        // mesh. Loop rule 2: rebroadcast each relay event at most once.
        guard !meshBroadcastEventIDs.contains(event.id),
              !rebroadcastEventIDs.contains(event.id) else {
            return
        }
        // Verify before spending BLE airtime; receivers verify again.
        guard event.isValidSignature() else { return }
        rebroadcastEventIDs.insert(event.id)

        pendingDownlinks.append((event, geohash))
        if pendingDownlinks.count > Limits.maxPendingDownlinks {
            // Bandwidth guard: drop-oldest — fresher chat is worth more.
            pendingDownlinks.removeFirst(pendingDownlinks.count - Limits.maxPendingDownlinks)
        }
        drainPendingDownlinks()
    }

    private func drainPendingDownlinks() {
        let cutoff = now().addingTimeInterval(-60)
        downlinkSendTimes.removeAll { $0 < cutoff }
        while !pendingDownlinks.isEmpty,
              downlinkSendTimes.count < Limits.downlinkEventsPerMinute {
            let (event, geohash) = pendingDownlinks.removeFirst()
            guard let carrier = NostrCarrierPacket(direction: .fromGateway, geohash: geohash, event: event),
                  let payload = carrier.encode() else { continue }
            broadcastToMesh?(payload)
            downlinkSendTimes.append(now())
        }
    }

    // MARK: - Downlink (receiver role: carried event arrives over mesh)

    private func handleDownlinkBroadcast(_ carrier: NostrCarrierPacket) {
        guard let event = validatedEvent(from: carrier) else { return }
        // Mark only AFTER signature verification, so a forged copy carrying a
        // real event's ID cannot poison the never-republish set, and use the
        // marking as dedup: the same broadcast relayed along several mesh
        // paths injects once (the pipeline's Nostr event-ID cache additionally
        // dedups against our own relay subscription).
        guard meshBroadcastEventIDs.insert(event.id) else { return }
        // Only inject events for the channel we're viewing; the inbound
        // pipeline files public messages under the current geohash.
        guard currentGeohash?() == carrier.geohash else { return }
        injectInbound?(event)
    }

    // MARK: - Uplink (sender role: mesh-only peer with no relays)

    /// Hands a locally signed event to a mesh gateway peer when we have no
    /// working relay connection. Returns true when the event was sent.
    ///
    /// v1 is deliberately fire-and-forget: no gateway ack. The event also
    /// stays in `NostrRelayManager`'s own pending queue, so if our internet
    /// comes back the relays dedup the duplicate publish by event ID.
    ///
    /// Loop rule 3: call sites only pass freshly composed events (see
    /// `GeohashSubscriptionManager.sendGeohash`); received carrier events
    /// never reach this path, and the mesh-carried guard below backstops it.
    func uplinkViaMesh(event: NostrEvent, geohash: String) -> Bool {
        if relaysConnected?() ?? true { return false }
        guard !meshBroadcastEventIDs.contains(event.id),
              !publishedEventIDs.contains(event.id) else {
            return false
        }
        // A single gateway is enough — relays fan out from there, and BLE
        // airtime is precious.
        guard let gateway = availableGatewayPeers?().first else { return false }
        guard let carrier = NostrCarrierPacket(direction: .toGateway, geohash: geohash, event: event),
              let payload = carrier.encode() else {
            return false
        }
        guard sendToGatewayPeer?(payload, gateway) ?? false else { return false }
        SecureLogger.info("🌐 Gateway: uplinked event \(event.id.prefix(8))… for #\(geohash) via mesh gateway \(gateway.id.prefix(8))…", category: .session)
        return true
    }

    // MARK: - Validation

    /// Structural and cryptographic checks every carried event must pass
    /// before a gateway publishes it or a receiver displays it. Ordered
    /// cheap-first; Schnorr verification runs last.
    private func validatedEvent(from carrier: NostrCarrierPacket) -> NostrEvent? {
        guard carrier.eventJSON.count <= NostrCarrierPacket.maxEventJSONBytes,
              Self.isValidGeohash(carrier.geohash),
              let event = carrier.event(),
              event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue,
              event.tags.contains(where: { $0.count >= 2 && $0[0] == "g" && $0[1] == carrier.geohash }),
              abs(now().timeIntervalSince1970 - TimeInterval(event.created_at)) <= Limits.maxEventAgeSeconds,
              event.isValidSignature() else {
            return nil
        }
        return event
    }

    static func isValidGeohash(_ geohash: String) -> Bool {
        let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
        return (1...NostrCarrierPacket.maxGeohashLength).contains(geohash.count)
            && geohash.allSatisfy { allowed.contains($0) }
    }
}

/// Insertion-ordered string set with a fixed capacity; the oldest entry is
/// evicted when full.
private struct BoundedIDSet {
    private var members: Set<String> = []
    private var order: [String] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func contains(_ id: String) -> Bool {
        members.contains(id)
    }

    /// Returns false when the ID was already present.
    @discardableResult
    mutating func insert(_ id: String) -> Bool {
        guard members.insert(id).inserted else { return false }
        order.append(id)
        if order.count > capacity {
            members.remove(order.removeFirst())
        }
        return true
    }
}
