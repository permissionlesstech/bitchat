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
/// Loop-prevention rules:
/// 1. An event learned from a `fromGateway` mesh broadcast is never
///    re-published to relays, never re-uplinked, and never rebroadcast
///    (`meshBroadcastEventIDs`), so a second gateway on the same mesh cannot
///    echo mesh-carried traffic back out. Mesh-level propagation of the
///    original broadcast packet is the TTL relay's job, not ours.
/// 2. An uplink deposit is published at most once (`publishedEventIDs`) and
///    a relay event is rebroadcast at most once (`rebroadcastEventIDs`), so
///    repeat deposits and relay echoes are absorbed. An event this gateway
///    itself uplinked (`publishedEventIDs`) is additionally never
///    downlink-rebroadcast: it originated on this mesh, so echoing it back
///    when our own relay subscription redelivers it would double BLE airtime
///    (the device-confirmed self-echo bug).
/// 3. Uplink is only attempted for locally composed events at the send site
///    (`GeohashSubscriptionManager.sendGeohash`); events received over the
///    carrier never re-enter the uplink path. This is a call-site convention;
///    the `meshBroadcastEventIDs`/`publishedEventIDs` backstops in
///    `uplinkViaMesh` enforce it defensively and are unit-tested.
/// Rules 1 and 2 are enforced here and unit-tested.
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
        /// Beyond the budget events queue (bounded, drop-oldest) and drain on
        /// a scheduled timer once the window frees (also re-driven by the next
        /// inbound relay event); a quiet channel does not strand its backlog.
        static let downlinkEventsPerMinute = 30
        static let maxPendingDownlinks = 30
        /// Accepted clock skew for a carried ephemeral event; anything older
        /// is stale replay the relays would drop anyway.
        static let maxEventAgeSeconds: TimeInterval = 15 * 60
        /// Bounded loop-prevention ID caches (oldest evicted).
        static let maxTrackedEventIDs = 512
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
    /// Schedules a downlink-drain closure to run after a delay. Injected so
    /// the drain timer is deterministic in tests; nil arms a real `Task`.
    var scheduleDrainTimer: (@MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void)?

    // MARK: State

    private let relayEngine: CarrierRelayEngine
    private let defaults: UserDefaults
    private static let enabledKey = "gateway.userEnabled"

    var queuedUplinks: [CarrierRelayEngine.QueuedUplink] {
        relayEngine.queuedUplinks
    }

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.relayEngine = CarrierRelayEngine(
            config: .init(
                maxQueuedUplinks: Limits.maxQueuedUplinks,
                maxQueuedUplinksPerDepositor: Limits.maxQueuedUplinksPerDepositor,
                uplinkEventsPerMinutePerDepositor: Limits.uplinkEventsPerMinutePerDepositor,
                downlinkEventsPerMinute: Limits.downlinkEventsPerMinute,
                maxPendingDownlinks: Limits.maxPendingDownlinks,
                maxEventAgeSeconds: Limits.maxEventAgeSeconds,
                maxTrackedEventIDs: Limits.maxTrackedEventIDs
            ),
            now: now
        )
    }

    // MARK: - Toggle

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled {
            relayEngine.clearQueuesOnDisable()
        }
        SecureLogger.info("🌐 Gateway mode \(enabled ? "enabled" : "disabled")", category: .session)
        onEnabledChanged?(enabled)
    }

    /// Panic-wipe hook: disable gateway mode, clear its persisted toggle, and
    /// drop queued uplinks/downlinks and loop-prevention caches.
    func resetForPanic() {
        isEnabled = false
        defaults.removeObject(forKey: Self.enabledKey)
        relayEngine.resetForPanic()
        onEnabledChanged?(false)
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
        case .toBridge, .fromBridge:
            // Mesh-bridge carriers are BridgeService territory; the ingress
            // router dispatches them there.
            return
        }
    }

    // MARK: - Uplink (gateway role: mesh peer -> internet)

    private func handleUplinkDeposit(_ carrier: NostrCarrierPacket, from depositor: PeerID) {
        guard isEnabled else { return }
        // Cheap structural checks first (parse, size, geohash, kind, #g tag,
        // age) — no crypto — so junk and stale replays are dropped before we
        // ever pay for a MainActor Schnorr verify.
        guard let event = structurallyValidEvent(from: carrier) else {
            SecureLogger.debug("🌐 Gateway: rejected uplink deposit from \(depositor.id.prefix(8))… (failed validation)", category: .security)
            return
        }
        // Dedup by the carried event ID BEFORE verification. Loop rule 1: a
        // fromGateway-learned event is mesh-carried and must never be
        // re-published. Loop rule 2: repeat deposits of an already handled
        // event are absorbed. A replay of one valid deposit is short-circuited
        // here without a per-packet signature verify.
        guard !relayEngine.isUplinkDuplicate(event.id) else {
            return
        }
        // Consume the per-depositor rate token BEFORE the expensive verify so
        // a flood of distinct forged/junk deposits is bounded by cheap work,
        // not by main-actor Schnorr verifications.
        guard relayEngine.allowUplinkDeposit(from: depositor) else {
            SecureLogger.debug("🌐 Gateway: rate-limited uplink deposit from \(depositor.id.prefix(8))…", category: .session)
            return
        }
        // Only now pay for cryptographic verification; receivers verify again.
        guard event.isValidSignature() else {
            SecureLogger.debug("🌐 Gateway: rejected uplink deposit from \(depositor.id.prefix(8))… (bad signature)", category: .security)
            return
        }

        let accepted: Bool
        if relaysConnected?() ?? false {
            publish(event, geohash: carrier.geohash)
            accepted = true
        } else {
            accepted = relayEngine.enqueueUplink(depositor: depositor, scope: carrier.geohash, event: event)
            if !accepted {
                SecureLogger.debug("🌐 Gateway: uplink queue quota reached for \(depositor.id.prefix(8))…", category: .session)
            }
        }

        // Only render on our own timeline what we actually accepted for
        // publish or queue: a quota-dropped deposit is never published and,
        // being directed, no other peer will ever see it, so showing it would
        // diverge our timeline permanently from what reached the channel.
        if accepted, currentGeohash?() == carrier.geohash {
            injectInbound?(event)
        }
    }

    /// Publish everything queued while relays were unreachable. Called when
    /// relay connectivity comes back.
    func flushQueuedUplinks() {
        guard isEnabled, relaysConnected?() ?? false else { return }
        relayEngine.flushQueuedUplinks { event, geohash in
            publish(event, geohash: geohash)
        }
    }

    private func publish(_ event: NostrEvent, geohash: String) {
        relayEngine.publishedEventIDs.insert(event.id)
        publishToRelays?(event, geohash)
        SecureLogger.info("🌐 Gateway: published carried event \(event.id.prefix(8))… to relays for #\(geohash)", category: .session)
    }

    // MARK: - Downlink (gateway role: internet -> mesh)

    /// Called for every event the gateway's own geohash-channel subscription
    /// delivers. Wraps it in a `fromGateway` carrier and broadcasts it on
    /// the mesh, within the airtime budget.
    func rebroadcastRelayEvent(_ event: NostrEvent, geohash: String, signatureAlreadyVerified: Bool = false) {
        guard isEnabled, broadcastToMesh != nil else { return }
        guard event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue else { return }
        // Freshness + geohash gate BEFORE spending any budget. A channel
        // (re)subscribe backfills up to an hour of history (limit 200), but
        // every receiver's `validatedEvent` drops anything older than the
        // same window — so rebroadcasting backfill would burn the whole
        // per-minute budget on events no mesh peer accepts. Also require the
        // event's own `#g` tag to match the carrier geohash.
        guard relayEngine.isFresh(event),
              event.tags.contains(where: { $0.count >= 2 && $0[0] == "g" && $0[1] == geohash }) else {
            return
        }
        // Loop rule 1: never rebroadcast mesh-carried events back onto the
        // mesh. Loop rule 2 (self-echo): never rebroadcast an event this
        // gateway itself uplinked (`publishedEventIDs`). Loop rule 2 (downlink):
        // rebroadcast each genuine inbound relay event at most once — marked
        // only AFTER it is actually sent so queue-overflow drops stay retryable.
        guard !relayEngine.meshBroadcastEventIDs.contains(event.id),
              !relayEngine.publishedEventIDs.contains(event.id),
              !relayEngine.rebroadcastEventIDs.contains(event.id),
              !relayEngine.hasPendingDownlink(event.id) else {
            return
        }
        // Verify before spending BLE airtime when not already verified by
        // NostrRelayManager's off-main inbound pipeline; receivers verify again.
        guard signatureAlreadyVerified || event.isValidSignature() else { return }

        relayEngine.enqueuePendingDownlink(event: event, scope: geohash)
        drainPendingDownlinks()
    }

    private func drainPendingDownlinks() {
        relayEngine.drainPendingDownlinks(
            direction: .fromGateway,
            send: { [weak self] payload, _ in
                self?.broadcastToMesh?(payload)
            },
            scheduleTimer: scheduleDrainTimer,
            onScheduledDrain: { [weak self] in
                self?.drainPendingDownlinks()
            }
        )
    }

    // MARK: - Downlink (receiver role: carried event arrives over mesh)

    private func handleDownlinkBroadcast(_ carrier: NostrCarrierPacket) {
        guard let event = validatedEvent(from: carrier) else { return }
        // Mark only AFTER signature verification, so a forged copy carrying a
        // real event's ID cannot poison the never-republish set, and use the
        // marking as dedup: the same broadcast relayed along several mesh
        // paths injects once (the pipeline's Nostr event-ID cache additionally
        // dedups against our own relay subscription).
        guard relayEngine.meshBroadcastEventIDs.insert(event.id) else { return }
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
        guard !relayEngine.meshBroadcastEventIDs.contains(event.id),
              !relayEngine.publishedEventIDs.contains(event.id) else {
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
        guard let event = structurallyValidEvent(from: carrier),
              event.isValidSignature() else {
            return nil
        }
        return event
    }

    /// The cheap half of `validatedEvent`: parse + size + geohash + kind +
    /// `#g` tag + freshness, with NO signature verification. Callers that can
    /// dedup or rate-limit on the carried ID run this first so the expensive
    /// Schnorr verify is reached only for events that survive the cheap gates.
    private func structurallyValidEvent(from carrier: NostrCarrierPacket) -> NostrEvent? {
        guard carrier.eventJSON.count <= NostrCarrierPacket.maxEventJSONBytes,
              Self.isValidGeohash(carrier.geohash),
              let event = carrier.event(),
              event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue,
              event.tags.contains(where: { $0.count >= 2 && $0[0] == "g" && $0[1] == carrier.geohash }),
              relayEngine.isFresh(event) else {
            return nil
        }
        return event
    }

    private static let validGeohashCharacters: Set<Character> = Set("0123456789bcdefghjkmnpqrstuvwxyz")

    static func isValidGeohash(_ geohash: String) -> Bool {
        (1...NostrCarrierPacket.maxGeohashLength).contains(geohash.count)
            && geohash.allSatisfy { validGeohashCharacters.contains($0) }
    }
}
