//
// BridgeService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import Combine
import Foundation

/// Policy engine for the mesh bridge: an opt-in stitcher of disjoint BLE
/// mesh islands that share a place. While the toggle is on, this device's
/// public mesh messages are additionally signed (with a derived, unlinkable
/// per-cell Nostr identity) as rendezvous events for the local geohash cell
/// and published to the cell's deterministic geo relays — directly when we
/// have internet, or deposited with a bridge gateway peer over a directed
/// `toBridge` carrier when we are mesh-only. Inbound rendezvous events from
/// other islands render into the mesh timeline marked as bridged.
///
/// A device with BOTH this toggle and the gateway toggle on serves the
/// island: it accepts `toBridge` deposits, publishes them, and rebroadcasts
/// remote rendezvous events onto the mesh as `fromBridge` carriers so
/// mesh-only peers see across the bridge too.
///
/// Consent model:
/// - Nothing crosses a bridge unless its author signed it for the bridge:
///   gateways carry only finished, Schnorr-signed rendezvous events, so a
///   neighbor's gateway cannot exfiltrate radio-only traffic. The per-message
///   "nearby only" flag simply skips composing a rendezvous copy.
/// - Receiving over radio (`fromBridge` carriers) is always on — it is
///   passive and leaks nothing. Subscribing over the internet (which reveals
///   the coarse cell to relays) and publishing both require the toggle.
///
/// Loop-prevention rules (adapted from `GatewayService`, unit-tested):
/// 1. An event learned from a `fromBridge` mesh broadcast is never published
///    and never rebroadcast (`meshBroadcastEventIDs`) — a second bridge
///    gateway on the same island cannot echo mesh-carried traffic.
/// 2. An event this device published (own messages or uplinked deposits,
///    `publishedEventIDs`) is never downlink-rebroadcast: it originated on
///    this island, so our own relay subscription redelivering it must not
///    double BLE airtime.
/// 3. A subscription event is rebroadcast at most once
///    (`rebroadcastEventIDs`, marked after send), and never when the island
///    already holds the radio copy (`isMessageSeenLocally` on the event's
///    mesh message ID) — remote islands' traffic is the only thing worth
///    airtime.
/// Receivers additionally dedup by timeline message ID: the wire carries no
/// public message ID, so every device derives the same content-stable one
/// (`MeshMessageIdentity`) from the origin coordinates in the event's `m`
/// tag — recomputed locally, never trusted — and the store's insert-by-ID
/// absorbs radio/bridge duplicates in either arrival order.
///
/// All dependencies are closure-injected (repo convention) so the policy
/// layer is unit-testable without relays, radios, or CoreLocation.
@MainActor
final class BridgeService: ObservableObject {
    enum Limits {
        /// Uplink deposits held while relays are unreachable.
        static let maxQueuedUplinks = 20
        static let maxQueuedUplinksPerDepositor = 5
        /// Uplink deposits accepted per depositor per minute.
        static let uplinkEventsPerMinutePerDepositor = 10
        /// Downlink mesh rebroadcasts per minute — BLE airtime is precious,
        /// and bridge traffic shares the radio with everything else.
        static let downlinkEventsPerMinute = 20
        static let maxPendingDownlinks = 30
        /// Accepted clock skew for a rendezvous event.
        static let maxEventAgeSeconds: TimeInterval = 15 * 60
        /// Bounded loop-prevention ID caches (oldest evicted).
        static let maxTrackedEventIDs = 512
        /// Presence heartbeat cadence while the bridge is active.
        static let presenceIntervalSeconds: TimeInterval = 4 * 60
        /// A rendezvous participant counts toward "via bridge" for this long
        /// after their last event.
        static let participantFreshnessSeconds: TimeInterval = 10 * 60
        /// Content cap, matching the public-message pipeline's own limit.
        static let maxContentBytes = 16_000
        /// Geohash-cell precision of the rendezvous (neighborhood, ~1.2 km).
        static let cellPrecision = 6
    }

    struct QueuedUplink {
        let depositor: PeerID
        let cell: String
        let event: NostrEvent
    }

    /// A validated rendezvous message ready for the timeline.
    struct InboundBridgeMessage {
        let messageID: String
        let senderNickname: String
        let senderPubkey: String
        let content: String
        let timestamp: Date
    }

    /// A person currently visible across the bridge (fresh, not attributed
    /// to the local island), for the people sheet.
    struct BridgedParticipant: Identifiable, Equatable {
        let pubkey: String
        let nickname: String?
        let lastSeen: Date
        var id: String { pubkey }
        /// Geohash-chat convention: nickname#last-4-of-pubkey, so two remote
        /// "anon"s stay distinguishable.
        var displayName: String {
            (nickname?.trimmedOrNilIfEmpty ?? "anon") + "#" + String(pubkey.suffix(4))
        }
    }

    static let shared = BridgeService()

    /// The user toggle. While true this device publishes its own public mesh
    /// messages to the rendezvous and subscribes to it when online.
    @Published private(set) var isEnabled: Bool
    /// Distinct remote rendezvous participants seen within the freshness
    /// window. Approximate by design: local participants are subtracted by
    /// matching their events' mesh message IDs against the local timeline,
    /// which cannot attribute silent (presence-only) local peers.
    @Published private(set) var bridgedPeerCount: Int = 0
    /// The people behind the count, newest activity first.
    @Published private(set) var bridgedParticipants: [BridgedParticipant] = []
    /// The rendezvous cell currently in use, when the bridge is active.
    @Published private(set) var activeCell: String?
    /// Per-session compose flag: while true, outgoing messages stay on the
    /// radio — no rendezvous copy is composed, so no gateway can carry them.
    @Published var nearbyOnly: Bool = false

    // MARK: Wiring (set once by the bootstrapper; fakes in tests)

    /// Publishes a signed event to the geo relays for a cell.
    var publishToRelays: (@MainActor (NostrEvent, String) -> Void)?
    /// Opens the rendezvous subscription for (cell + neighbors); events are
    /// fed back via `handleRendezvousEvent`.
    var openSubscription: (@MainActor ([String]) -> Void)?
    /// Closes the rendezvous subscription.
    var closeSubscription: (@MainActor () -> Void)?
    /// Whether any Nostr relay connection is currently working.
    var relaysConnected: (@MainActor () -> Bool)?
    /// The local neighborhood cell from CoreLocation, if permitted.
    var locationCell: (@MainActor () -> String?)?
    /// Asks the location layer for a fresh one-shot fix. The bridge must
    /// pump location itself: channel data otherwise only flows while some
    /// other feature (channels sheet, location notes) happens to be active —
    /// a field failure mode where the bridge silently never got a cell.
    var requestLocationFix: (@MainActor () -> Void)?
    /// A rendezvous cell advertised by a reachable mesh bridge peer's
    /// announce — lets a mesh-only, location-less device still compose
    /// correctly tagged events.
    var meshAdvertisedCell: (@MainActor () -> String?)?
    /// Sends an encoded `toBridge` carrier directed to a bridge peer.
    var sendToBridgePeer: (@MainActor (Data, PeerID) -> Bool)?
    /// Reachable mesh peers advertising the `.bridge` capability.
    var availableBridgePeers: (@MainActor () -> [PeerID])?
    /// Broadcasts an encoded `fromBridge` carrier on the mesh.
    var broadcastToMesh: (@MainActor (Data) -> Void)?
    /// Delivers a validated inbound bridge message to the mesh timeline.
    var injectInbound: (@MainActor (InboundBridgeMessage) -> Void)?
    /// True when the mesh timeline already holds this message ID (the radio
    /// copy) — used to skip pointless downlink airtime.
    var isMessageSeenLocally: (@MainActor (String) -> Bool)?
    /// Derives the unlinkable per-cell rendezvous identity.
    var deriveIdentity: (@MainActor (String) throws -> NostrIdentity)?
    /// Local nickname for the `n` tag.
    var myNickname: (@MainActor () -> String)?
    /// Fired on toggle changes (advertise/withdraw `.bridge` + re-announce).
    var onEnabledChanged: (@MainActor (Bool) -> Void)?
    /// Fired when the active rendezvous cell changes (including to nil) so
    /// the announce advertisement stays current.
    var onActiveCellChanged: (@MainActor (String?) -> Void)?
    /// Schedules a closure after a delay; nil arms a real `Task`. Injected so
    /// timers are deterministic in tests.
    var scheduleTimer: (@MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void)?

    // MARK: State

    /// Loop rule 1: event IDs seen in `fromBridge` mesh broadcasts.
    private var meshBroadcastEventIDs: BoundedIDSet
    /// Loop rule 2: event IDs this device published (own or deposited).
    private var publishedEventIDs: BoundedIDSet
    /// Loop rule 3: event IDs this device already rebroadcast.
    private var rebroadcastEventIDs: BoundedIDSet
    /// Timeline message IDs already injected (either arrival path).
    private var injectedMessageIDs: BoundedIDSet

    /// Cells the rendezvous subscription covers (own + neighbor ring).
    private(set) var subscribedCells: Set<String> = []
    private(set) var queuedUplinks: [QueuedUplink] = []
    private var uplinkDepositTimes: [PeerID: [Date]] = [:]
    private var downlinkSendTimes: [Date] = []
    private var pendingDownlinks: [(event: NostrEvent, cell: String)] = []
    private var downlinkDrainScheduled = false
    private var presenceTimerArmed = false
    private var lastPresenceAt = Date.distantPast

    /// pubkey -> (lastSeen, attributed-to-local-island, last known nickname).
    private var participants: [String: (lastSeen: Date, isLocal: Bool, nickname: String?)] = [:]

    private let defaults: UserDefaults
    private let now: () -> Date
    private static let enabledKey = "bridge.userEnabled"

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.meshBroadcastEventIDs = BoundedIDSet(capacity: Limits.maxTrackedEventIDs)
        self.publishedEventIDs = BoundedIDSet(capacity: Limits.maxTrackedEventIDs)
        self.rebroadcastEventIDs = BoundedIDSet(capacity: Limits.maxTrackedEventIDs)
        self.injectedMessageIDs = BoundedIDSet(capacity: Limits.maxTrackedEventIDs)
    }

    // MARK: - Toggle & lifecycle

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled {
            queuedUplinks.removeAll()
            pendingDownlinks.removeAll()
            uplinkDepositTimes.removeAll()
            participants.removeAll()
            bridgedPeerCount = 0
            bridgedParticipants = []
        }
        SecureLogger.info("🌉 Bridge mode \(enabled ? "enabled" : "disabled")", category: .session)
        refreshRendezvous()
        onEnabledChanged?(enabled)
    }

    /// Recomputes the active cell and (re)opens or closes the subscription.
    /// Call on toggle changes, location updates, and relay connectivity
    /// changes; idempotent.
    func refreshRendezvous() {
        let cell = isEnabled ? currentCell() : nil
        // No cell yet: ask for a fix — the availableChannels change re-enters
        // here once it lands.
        if isEnabled, cell == nil {
            requestLocationFix?()
        }
        guard cell != activeCell else {
            // The maintenance timer must run even cell-less: it is what
            // retries the location fix (launch races the permission
            // callback, so the first request can silently no-op).
            if isEnabled { armPresenceTimerIfNeeded() }
            return
        }
        if activeCell != nil {
            closeSubscription?()
            subscribedCells = []
        }
        activeCell = cell
        onActiveCellChanged?(cell)
        guard let cell else {
            if isEnabled { armPresenceTimerIfNeeded() }
            return
        }
        // Own cell + neighbors: islands straddling a cell edge still meet.
        // Publishes go to the own cell only; symmetric because both sides
        // subscribe to each other's cell via the neighbor ring.
        let cells = [cell] + Geohash.neighbors(of: cell)
        subscribedCells = Set(cells)
        openSubscription?(cells)
        SecureLogger.info("🌉 Bridge: rendezvous open for cell \(cell)", category: .session)
        publishPresence()
        armPresenceTimerIfNeeded()
    }

    /// The rendezvous cell: our own location when we have it, else the cell
    /// a reachable bridge gateway advertises in its announce.
    private func currentCell() -> String? {
        if let own = locationCell?(), !own.isEmpty {
            return String(own.prefix(Limits.cellPrecision))
        }
        if let advertised = meshAdvertisedCell?(), GatewayService.isValidGeohash(advertised) {
            return String(advertised.prefix(Limits.cellPrecision))
        }
        return nil
    }

    // One switch does the right thing: while bridging, a device with
    // internet automatically serves its island (accepts deposits, carries
    // remote messages onto the radio). The marginal cost over bridging
    // yourself is small — the relay connections and subscription already
    // exist for you — and a separate "serve others" lever proved to be a
    // silent trap for mesh-only neighbors.

    // MARK: - Outgoing (sender role)

    /// Composes and ships the bridged copy of an outgoing public mesh
    /// message. Call after the radio send; no-op when the bridge is off,
    /// no cell is known, or the message was flagged nearby-only upstream.
    /// `senderPeerID`/`timestamp` are the origin coordinates of the radio
    /// send — they (with the content) derive the cross-device-stable mesh
    /// message ID that receivers dedup on.
    func bridgeOutgoing(content: String, senderPeerID: PeerID, timestamp: Date) {
        guard isEnabled, !nearbyOnly, let cell = activeCell ?? currentCell() else { return }
        guard content.utf8.count <= Limits.maxContentBytes else { return }
        let timestampMs = MeshMessageIdentity.millisecondTimestamp(timestamp)
        let stableID = MeshMessageIdentity.stableID(
            senderIDHex: senderPeerID.id,
            timestampMs: timestampMs,
            content: content
        )
        guard let identity = try? deriveIdentity?(cell),
              let event = try? NostrProtocol.createBridgeMeshEvent(
                content: content,
                cell: cell,
                senderIdentity: identity,
                nickname: myNickname?(),
                meshSenderID: senderPeerID.id,
                meshTimestampMs: timestampMs
              ) else {
            SecureLogger.error("🌉 Bridge: failed to compose rendezvous event", category: .session)
            return
        }
        publishedEventIDs.insert(event.id)
        injectedMessageIDs.insert(stableID) // our own timeline already has it
        if relaysConnected?() ?? false {
            publishToRelays?(event, cell)
        } else if let carrier = NostrCarrierPacket(direction: .toBridge, geohash: cell, event: event),
                  let payload = carrier.encode(),
                  let gateway = availableBridgePeers?().first {
            if sendToBridgePeer?(payload, gateway) ?? false {
                SecureLogger.debug("🌉 Bridge: uplinked own event via gateway \(gateway.id.prefix(8))…", category: .session)
            }
        }
    }

    /// Publishes a presence heartbeat so silent participants still register
    /// across the bridge. Throttled: several triggers (enable, cell change,
    /// relay reconnect) can coincide, and same-second heartbeats are
    /// byte-identical events anyway.
    func publishPresence() {
        guard isEnabled, let cell = activeCell, relaysConnected?() ?? false else { return }
        guard now().timeIntervalSince(lastPresenceAt) >= 30 else { return }
        lastPresenceAt = now()
        guard let identity = try? deriveIdentity?(cell),
              let event = try? NostrProtocol.createBridgePresenceEvent(cell: cell, senderIdentity: identity) else { return }
        publishedEventIDs.insert(event.id)
        publishToRelays?(event, cell)
    }

    /// Maintenance heartbeat while bridging: presence, participant pruning,
    /// and a location retry. Runs with or without a cell — the cell-less
    /// case is exactly when the location retry matters.
    private func armPresenceTimerIfNeeded() {
        guard isEnabled, !presenceTimerArmed else { return }
        presenceTimerArmed = true
        let fire: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.presenceTimerArmed = false
            self.publishPresence()
            self.pruneParticipants()
            // Location refresh: migrates cells on a moving device and
            // recovers a launch that raced the permission callback.
            if self.activeCell == nil {
                self.refreshRendezvous()
            } else {
                self.requestLocationFix?()
            }
            self.armPresenceTimerIfNeeded()
        }
        if let scheduleTimer {
            scheduleTimer(Limits.presenceIntervalSeconds, fire)
        } else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Limits.presenceIntervalSeconds * 1_000_000_000))
                fire()
            }
        }
    }

    // MARK: - Subscription ingress (internet role)

    /// Entry point for every event the rendezvous subscription delivers.
    /// Handles presence accounting, timeline injection, and — when acting as
    /// the island's gateway — downlink rebroadcast.
    func handleRendezvousEvent(_ event: NostrEvent) {
        guard isEnabled else { return }
        // The subscription spans our cell + neighbors; trust only the
        // event's own signed `r` tag, and only within that ring.
        guard let cell = event.tags.first(where: { $0.count >= 2 && $0[0] == "r" })?[1],
              subscribedCells.contains(cell) else {
            return
        }
        guard let kind = classify(event, cell: cell) else { return }
        // Events we published come back from our own subscription; they are
        // presence-neutral (we never count ourselves) and never re-injected
        // or rebroadcast. Two layers: the published-ID cache (this session)
        // and pubkey self-recognition — the rendezvous identity is derived
        // deterministically, so even after a relaunch wipes the cache our
        // own relay-backfilled events are recognized (field bug: own
        // pre-restart messages re-rendered as bridged).
        guard !publishedEventIDs.contains(event.id) else { return }
        if isOwnRendezvousEvent(event, cell: cell) {
            publishedEventIDs.insert(event.id) // never downlink it either
            return
        }
        guard event.isValidSignature() else { return }

        switch kind {
        case .presence:
            recordParticipant(event.pubkey, isLocal: false, nickname: nil)
        case .message(let message):
            let isLocalRadioCopy = isMessageSeenLocally?(message.messageID) ?? false
            if isLocalRadioCopy {
                SecureLogger.debug("🌉 Bridge: radio copy of \(message.messageID.prefix(8))… already present; sender counted as local", category: .session)
            }
            recordParticipant(event.pubkey, isLocal: isLocalRadioCopy, nickname: message.senderNickname)
            inject(message)
            // Serving duty: carry remote islands' messages onto the radio for
            // mesh-only peers. Local-origin events are skipped — the island
            // already heard them (loop rule 3). The drain is jitter-delayed:
            // with every online bridger serving, the holdoff lets gateways
            // hear each other's broadcasts and skip duplicates.
            if !isLocalRadioCopy,
               !meshBroadcastEventIDs.contains(event.id),
               !rebroadcastEventIDs.contains(event.id),
               !pendingDownlinks.contains(where: { $0.event.id == event.id }) {
                pendingDownlinks.append((event, cell))
                if pendingDownlinks.count > Limits.maxPendingDownlinks {
                    pendingDownlinks.removeFirst(pendingDownlinks.count - Limits.maxPendingDownlinks)
                }
                scheduleDownlinkDrainIfNeeded(jitter: true)
            }
        }
    }

    // MARK: - Mesh carrier ingress (both roles)

    /// Entry point for received `nostrCarrier` packets with bridge
    /// directions. `directedToUs` is true for `toBridge` deposits addressed
    /// to this device; false for `fromBridge` broadcasts.
    func handleMeshCarrier(_ carrier: NostrCarrierPacket, from peerID: PeerID, directedToUs: Bool) {
        switch carrier.direction {
        case .toBridge:
            guard directedToUs else { return }
            handleUplinkDeposit(carrier, from: peerID)
        case .fromBridge:
            guard !directedToUs else { return }
            handleDownlinkBroadcast(carrier)
        case .toGateway, .fromGateway:
            return // GatewayService territory; routed there by the caller.
        }
    }

    // MARK: - Uplink (gateway role: mesh peer -> internet)

    private func handleUplinkDeposit(_ carrier: NostrCarrierPacket, from depositor: PeerID) {
        guard isEnabled else { return }
        // Cheap structural gates before any crypto, mirroring GatewayService.
        guard let event = structurallyValidEvent(from: carrier) else {
            SecureLogger.debug("🌉 Bridge: rejected deposit from \(depositor.id.prefix(8))… (failed validation)", category: .security)
            return
        }
        guard !meshBroadcastEventIDs.contains(event.id),
              !publishedEventIDs.contains(event.id),
              !queuedUplinks.contains(where: { $0.event.id == event.id }) else {
            return
        }
        guard allowUplinkDeposit(from: depositor) else {
            SecureLogger.debug("🌉 Bridge: rate-limited deposit from \(depositor.id.prefix(8))…", category: .session)
            return
        }
        guard event.isValidSignature() else {
            SecureLogger.debug("🌉 Bridge: rejected deposit from \(depositor.id.prefix(8))… (bad signature)", category: .security)
            return
        }
        if relaysConnected?() ?? false {
            publish(event, cell: carrier.geohash)
        } else {
            enqueueUplink(QueuedUplink(depositor: depositor, cell: carrier.geohash, event: event))
        }
        // No local injection: the depositor's radio broadcast already carried
        // the message to this island, including us.
    }

    /// Publish everything queued while relays were unreachable.
    func flushQueuedUplinks() {
        guard isEnabled, relaysConnected?() ?? false, !queuedUplinks.isEmpty else { return }
        let queued = queuedUplinks
        queuedUplinks.removeAll()
        for item in queued where !publishedEventIDs.contains(item.event.id) {
            publish(item.event, cell: item.cell)
        }
    }

    private func publish(_ event: NostrEvent, cell: String) {
        publishedEventIDs.insert(event.id)
        publishToRelays?(event, cell)
        SecureLogger.info("🌉 Bridge: published carried event \(event.id.prefix(8))… for cell \(cell)", category: .session)
    }

    @discardableResult
    private func enqueueUplink(_ item: QueuedUplink) -> Bool {
        let fromDepositor = queuedUplinks.filter { $0.depositor == item.depositor }.count
        guard fromDepositor < Limits.maxQueuedUplinksPerDepositor else { return false }
        if queuedUplinks.count >= Limits.maxQueuedUplinks {
            queuedUplinks.removeFirst(queuedUplinks.count - Limits.maxQueuedUplinks + 1)
        }
        queuedUplinks.append(item)
        return true
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
        if uplinkDepositTimes.count > Limits.maxTrackedEventIDs {
            uplinkDepositTimes = uplinkDepositTimes.filter { $0.value.contains { $0 >= cutoff } }
        }
        return true
    }

    // MARK: - Downlink (gateway role: internet -> mesh)

    private func drainPendingDownlinks() {
        let cutoff = now().addingTimeInterval(-60)
        downlinkSendTimes.removeAll { $0 < cutoff }
        while !pendingDownlinks.isEmpty,
              downlinkSendTimes.count < Limits.downlinkEventsPerMinute {
            let (event, cell) = pendingDownlinks.removeFirst()
            guard isFresh(event) else { continue }
            // Suppression recheck at send time: another gateway may have
            // broadcast this event during our jitter holdoff.
            guard !meshBroadcastEventIDs.contains(event.id),
                  !rebroadcastEventIDs.contains(event.id) else { continue }
            guard let carrier = NostrCarrierPacket(direction: .fromBridge, geohash: cell, event: event),
                  let payload = carrier.encode() else { continue }
            broadcastToMesh?(payload)
            SecureLogger.debug("🌉 Bridge: downlinked remote event \(event.id.prefix(8))… onto the mesh", category: .session)
            // Mark-after-send (loop rule 3): a queue-overflow drop stays
            // retryable on relay redelivery.
            rebroadcastEventIDs.insert(event.id)
            downlinkSendTimes.append(now())
        }
        scheduleDownlinkDrainIfNeeded()
    }

    private func scheduleDownlinkDrainIfNeeded(jitter: Bool = false) {
        guard !pendingDownlinks.isEmpty, !downlinkDrainScheduled else { return }
        let delay: TimeInterval
        if jitter {
            // Multi-gateway suppression window: enough spread for another
            // gateway's broadcast to land and mark the event mesh-carried.
            delay = Double.random(in: 0.2...1.5)
        } else {
            let oldest = downlinkSendTimes.min() ?? now()
            delay = max(0.05, 60 - now().timeIntervalSince(oldest))
        }
        downlinkDrainScheduled = true
        let fire: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.downlinkDrainScheduled = false
            self.drainPendingDownlinks()
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

    // MARK: - Downlink (receiver role: carried event arrives over radio)

    private func handleDownlinkBroadcast(_ carrier: NostrCarrierPacket) {
        // Reception is deliberately NOT gated on the toggle: it is passive
        // radio, and two phones side by side should not disagree about what
        // the channel said. Publishing/subscribing remain opt-in.
        guard let event = structurallyValidEvent(from: carrier),
              !publishedEventIDs.contains(event.id),
              !isOwnRendezvousEvent(event, cell: carrier.geohash),
              event.isValidSignature() else {
            return
        }
        // Mark after verification (a forged copy must not poison the cache),
        // and use the marking as multi-path dedup.
        guard meshBroadcastEventIDs.insert(event.id) else { return }
        guard case .message(let message)? = classify(event, cell: carrier.geohash) else {
            return
        }
        recordParticipant(event.pubkey, isLocal: false, nickname: message.senderNickname)
        inject(message)
    }

    // MARK: - Injection & participants

    private func inject(_ message: InboundBridgeMessage) {
        guard injectedMessageIDs.insert(message.messageID) else { return }
        guard !(isMessageSeenLocally?(message.messageID) ?? false) else { return }
        SecureLogger.info("🌉 Bridge: injected bridged message \(message.messageID.prefix(8))… from \(message.senderNickname)", category: .session)
        injectInbound?(message)
    }

    private func recordParticipant(_ pubkey: String, isLocal: Bool, nickname: String?) {
        let previous = participants[pubkey]
        // Local attribution is sticky: one radio-confirmed message marks the
        // pubkey as an islander for as long as they stay fresh. Presence
        // events carry no nickname, so a known name is never forgotten.
        participants[pubkey] = (
            lastSeen: now(),
            isLocal: (previous?.isLocal ?? false) || isLocal,
            nickname: nickname?.trimmedOrNilIfEmpty ?? previous?.nickname
        )
        recomputeBridgedCount()
    }

    private func pruneParticipants() {
        let cutoff = now().addingTimeInterval(-Limits.participantFreshnessSeconds)
        participants = participants.filter { $0.value.lastSeen >= cutoff }
        recomputeBridgedCount()
    }

    private func recomputeBridgedCount() {
        let cutoff = now().addingTimeInterval(-Limits.participantFreshnessSeconds)
        let visible = participants
            .filter { $0.value.lastSeen >= cutoff && !$0.value.isLocal }
            .map { BridgedParticipant(pubkey: $0.key, nickname: $0.value.nickname, lastSeen: $0.value.lastSeen) }
            .sorted { $0.lastSeen > $1.lastSeen }
        if visible.count != bridgedPeerCount {
            bridgedPeerCount = visible.count
        }
        if visible != bridgedParticipants {
            bridgedParticipants = visible
        }
    }

    // MARK: - Validation

    private enum RendezvousKind {
        case message(InboundBridgeMessage)
        case presence
    }

    /// Classifies a structurally acceptable rendezvous event; nil rejects.
    private func classify(_ event: NostrEvent, cell: String) -> RendezvousKind? {
        guard isFresh(event),
              event.tags.contains(where: { $0.count >= 2 && $0[0] == "r" && $0[1] == cell }),
              GatewayService.isValidGeohash(cell) else {
            return nil
        }
        switch event.kind {
        case NostrProtocol.EventKind.geohashPresence.rawValue:
            return .presence
        case NostrProtocol.EventKind.ephemeralEvent.rawValue:
            let content = event.content
            guard !content.trimmed.isEmpty, content.utf8.count <= Limits.maxContentBytes else { return nil }
            let nickname = event.tags.first(where: { $0.count >= 2 && $0[0] == "n" })?[1]
            // Recompute — never trust — the mesh message ID: the `m` tag is
            // `[stable ID, sender ID, wire timestamp ms]`. Element 1 exists
            // for v1.7.0 parsers; we ignore it and derive the ID from the
            // origin coordinates (elements 2-3) plus the event's own content,
            // so a forged tag cannot bind a chosen ID to different content
            // (see `MeshMessageIdentity` for the exact property and its
            // limits).
            let m = event.tags.first(where: { $0.count >= 2 && $0[0] == "m" })
            let messageID: String
            if let m, m.count >= 4, m[2].count == 16, m[2].allSatisfy(\.isHexDigit),
               let timestampMs = UInt64(m[3]) {
                messageID = MeshMessageIdentity.stableID(
                    senderIDHex: m[2],
                    timestampMs: timestampMs,
                    content: content
                )
            } else {
                messageID = event.id // old-format or absent tag
            }
            return .message(InboundBridgeMessage(
                messageID: messageID,
                senderNickname: nickname?.trimmedOrNilIfEmpty ?? "anon#\(event.pubkey.suffix(4))",
                senderPubkey: event.pubkey,
                content: content,
                timestamp: Date(timeIntervalSince1970: TimeInterval(event.created_at))
            ))
        default:
            return nil
        }
    }

    /// Parse + size + cell + kind + `r` tag + freshness, with NO signature
    /// verification — callers dedup/rate-limit first, Schnorr-verify last.
    private func structurallyValidEvent(from carrier: NostrCarrierPacket) -> NostrEvent? {
        guard carrier.eventJSON.count <= NostrCarrierPacket.maxEventJSONBytes,
              GatewayService.isValidGeohash(carrier.geohash),
              let event = carrier.event(),
              classify(event, cell: carrier.geohash) != nil else {
            return nil
        }
        return event
    }

    private func isFresh(_ event: NostrEvent) -> Bool {
        abs(now().timeIntervalSince1970 - TimeInterval(event.created_at)) <= Limits.maxEventAgeSeconds
    }

    /// True when the event was signed by this device's own derived
    /// rendezvous identity for the cell. Survives relaunches (unlike the
    /// published-ID cache) because the derivation is deterministic; the
    /// underlying identity cache makes this cheap.
    private func isOwnRendezvousEvent(_ event: NostrEvent, cell: String) -> Bool {
        guard let identity = try? deriveIdentity?(cell) else { return false }
        return identity.publicKeyHex.lowercased() == event.pubkey.lowercased()
    }
}
