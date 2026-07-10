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
/// Receivers key bridge rows by the signed Nostr event ID. The event's `m` tag
/// is only a radio-copy hint: its mesh sender/timestamp fields are public and
/// cannot authenticate the event signer, so letting them own the timeline ID
/// would allow a different signer to front-run the genuine event's dedup slot.
/// When the radio copy is already present the hint avoids duplicate rendering
/// and downlink airtime. If the bridge copy wins the race, a later
/// authenticated radio copy replaces every bridge row that claimed the same
/// hint; the untrusted hint can therefore merge a duplicate but can never
/// suppress the radio-authenticated origin.
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
        /// Keep radio-replacement aliases for every bridge row that can still
        /// be visible in the bounded mesh timeline. Retiring an alias earlier
        /// would let valid high-volume ingress delete otherwise visible
        /// history merely to preserve the radio-wins invariant.
        static let maxTrackedRadioAliases = TransportConfig.meshTimelineCap
        /// Presence heartbeat cadence while the bridge is active.
        static let presenceIntervalSeconds: TimeInterval = 4 * 60
        /// A rendezvous participant counts toward "via bridge" for this long
        /// after their last event.
        static let participantFreshnessSeconds: TimeInterval = 10 * 60
        /// Relay ingress is adversarial: bound both accepted work and the
        /// people-sheet state even when an attacker rotates signing keys.
        static let inboundEventsPerMinute = 600
        static let inboundEventsPerMinutePerSigner = 120
        /// Cheap pre-crypto gate for both valid and invalid ingress. Without
        /// it, invalid carrier events could force unbounded Schnorr work while
        /// never reaching the accepted-event limiter below.
        static let signatureVerificationAttemptsPerMinute = 720
        static let maxParticipants = 128
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
        /// Unauthenticated mesh coordinates can only be used to notice that a
        /// verified radio copy is already present; they never own bridge dedup.
        let radioMessageIDHint: String?
        let senderNickname: String
        let participantNickname: String?
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
    /// Distinct rendezvous participants seen within the freshness window.
    /// Radio-copy hints never alter signer locality: their public coordinates
    /// can suppress a duplicate row but cannot authenticate a Nostr signer.
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
    /// Removes a previously injected bridge row when an authenticated radio
    /// copy arrives later. The UI hook also discards a not-yet-flushed row.
    var removeInjectedInbound: (@MainActor (String) -> Void)?
    /// Exact liveness check for a bridge row in either the pending UI pipeline
    /// or bounded conversation store. Alias pruning may discard proof only
    /// after the corresponding row is already gone.
    var isInjectedInboundPresent: (@MainActor (String) -> Bool)?
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
    /// Signed relay/carrier events already accepted. Kept separate from the
    /// loop caches so a mesh arrival can still mark loop suppression even when
    /// the relay copy won the race.
    private var receivedEventIDs: BoundedIDSet
    /// Authenticated radio IDs observed this session. These close the
    /// bridge-first race even before the UI pipeline flushes its radio row.
    private var observedRadioMessageIDs: BoundedIDSet
    /// event ID -> untrusted radio hint. Event IDs own bridge
    /// dedup; this bounded reverse index is used only to replace bridge rows
    /// after the genuine radio packet has authenticated successfully.
    private var injectedRadioAliases: [String: String] = [:]
    private var injectedRadioAliasOrder: [String] = []

    /// Cells the rendezvous subscription covers (own + neighbor ring).
    private(set) var subscribedCells: Set<String> = []
    private(set) var queuedUplinks: [QueuedUplink] = []
    private var uplinkDepositTimes: [PeerID: [Date]] = [:]
    private var downlinkSendTimes: [Date] = []
    private var inboundEventTimes: [Date] = []
    private var inboundEventTimesBySigner: [String: [Date]] = [:]
    private var signatureVerificationTokens = Double(Limits.signatureVerificationAttemptsPerMinute)
    private var signatureVerificationLastRefillAt: Date?
    private var pendingDownlinks: [(event: NostrEvent, cell: String)] = []
    private var downlinkDrainScheduled = false
    private var presenceTimerArmed = false
    private var lastPresenceAt = Date.distantPast

    /// pubkey -> (lastSeen, last known nickname).
    private var participants: [String: (lastSeen: Date, nickname: String?)] = [:]

    private let defaults: UserDefaults
    private let now: () -> Date
    private let verifyEventSignature: (NostrEvent) -> Bool
    private static let enabledKey = "bridge.userEnabled"

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        verifyEventSignature: @escaping (NostrEvent) -> Bool = { $0.isValidSignature() }
    ) {
        self.defaults = defaults
        self.now = now
        self.verifyEventSignature = verifyEventSignature
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.meshBroadcastEventIDs = BoundedIDSet(capacity: Limits.maxTrackedEventIDs)
        self.publishedEventIDs = BoundedIDSet(capacity: Limits.maxTrackedEventIDs)
        self.rebroadcastEventIDs = BoundedIDSet(capacity: Limits.maxTrackedEventIDs)
        self.injectedMessageIDs = BoundedIDSet(capacity: Limits.maxTrackedEventIDs)
        self.receivedEventIDs = BoundedIDSet(capacity: Limits.maxTrackedEventIDs)
        self.observedRadioMessageIDs = BoundedIDSet(capacity: Limits.maxTrackedEventIDs)
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
            inboundEventTimes.removeAll()
            inboundEventTimesBySigner.removeAll()
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
        injectedMessageIDs.insert(event.id) // our own timeline already has it
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
        guard allowSignatureVerificationAttempt(), verifyEventSignature(event) else { return }
        guard receivedEventIDs.insert(event.id), allowInboundEvent(from: event.pubkey) else { return }
        guard let kind = classify(event, cell: cell) else { return }

        switch kind {
        case .presence:
            recordParticipant(event.pubkey, nickname: nil)
        case .message(let message):
            let isLocalRadioCopy = message.radioMessageIDHint.map(radioCopyAlreadyPresent) ?? false
            if isLocalRadioCopy {
                // The public m-tag proves only that identical radio content is
                // already present, not that this Nostr signer authored it.
                // Skip the duplicate row without changing signer locality.
                SecureLogger.debug("🌉 Bridge: authenticated radio copy already present; bridge alias skipped", category: .session)
            } else if inject(message) {
                recordParticipant(event.pubkey, nickname: message.participantNickname)
            }
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

    /// Called only after the BLE public-message signature has authenticated.
    /// A bridge hint is not trusted enough to drop this radio row. Instead,
    /// the radio row wins and any earlier bridge aliases are removed, which
    /// gives both arrival orders one timeline row without restoring the
    /// origin-spoof vulnerability.
    func handleAuthenticatedRadioMessage(messageID: String) {
        guard !messageID.isEmpty else { return }
        observedRadioMessageIDs.insert(messageID)

        let matching = injectedRadioAliases.filter { $0.value == messageID }
        guard !matching.isEmpty else { return }
        let eventIDs = Set(matching.keys)
        for eventID in matching.keys {
            removeInjectedInbound?(eventID)
            injectedRadioAliases.removeValue(forKey: eventID)
        }
        injectedRadioAliasOrder.removeAll { eventIDs.contains($0) }

        // A relay event can already be waiting inside the multi-gateway jitter
        // window. Remove it now so it cannot consume BLE airtime after the
        // authenticated radio packet proved this island already has a copy.
        pendingDownlinks.removeAll { item in
            guard case .message(let message)? = classify(item.event, cell: item.cell) else { return false }
            return message.radioMessageIDHint == messageID
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
        guard allowSignatureVerificationAttempt(), verifyEventSignature(event) else {
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

    /// Bounds relay/carrier work independently of the downlink airtime budget.
    /// A valid signature proves control of one key, not that the sender is
    /// entitled to unbounded main-actor state or CPU.
    private func allowInboundEvent(from signer: String) -> Bool {
        let date = now()
        let cutoff = date.addingTimeInterval(-60)
        inboundEventTimes.removeAll { $0 < cutoff }
        guard inboundEventTimes.count < Limits.inboundEventsPerMinute else { return false }

        var signerTimes = inboundEventTimesBySigner[signer, default: []]
        signerTimes.removeAll { $0 < cutoff }
        guard signerTimes.count < Limits.inboundEventsPerMinutePerSigner else {
            inboundEventTimesBySigner[signer] = signerTimes
            return false
        }

        inboundEventTimes.append(date)
        signerTimes.append(date)
        inboundEventTimesBySigner[signer] = signerTimes
        if inboundEventTimesBySigner.count > Limits.maxTrackedEventIDs {
            inboundEventTimesBySigner = inboundEventTimesBySigner.filter { entry in
                entry.value.contains { $0 >= cutoff }
            }
        }
        return true
    }

    /// Bounds expensive signature checks before signer identity is trusted.
    /// Kept independent from accepted-event accounting so invalid events do
    /// not create signer state or poison any dedup cache.
    private func allowSignatureVerificationAttempt() -> Bool {
        let date = now()
        if let lastRefillAt = signatureVerificationLastRefillAt {
            let elapsed = max(0, date.timeIntervalSince(lastRefillAt))
            let refillPerSecond = Double(Limits.signatureVerificationAttemptsPerMinute) / 60
            signatureVerificationTokens = min(
                Double(Limits.signatureVerificationAttemptsPerMinute),
                signatureVerificationTokens + elapsed * refillPerSecond
            )
        }
        signatureVerificationLastRefillAt = date
        guard signatureVerificationTokens >= 1 else { return false }
        signatureVerificationTokens -= 1
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
            // broadcast this event, or the authenticated radio copy may have
            // arrived, during our jitter holdoff.
            guard !meshBroadcastEventIDs.contains(event.id),
                  !rebroadcastEventIDs.contains(event.id) else { continue }
            if case .message(let message)? = classify(event, cell: cell),
               let radioMessageID = message.radioMessageIDHint,
               radioCopyAlreadyPresent(radioMessageID) {
                continue
            }
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
              allowSignatureVerificationAttempt(),
              verifyEventSignature(event) else {
            return
        }
        // Mark after verification (a forged copy must not poison the cache),
        // even when the relay copy won the injection race: pending gateway
        // downlinks consult this cache and must stand down.
        let firstMeshArrival = meshBroadcastEventIDs.insert(event.id)
        guard firstMeshArrival,
              receivedEventIDs.insert(event.id),
              allowInboundEvent(from: event.pubkey) else { return }
        guard case .message(let message)? = classify(event, cell: carrier.geohash) else {
            return
        }
        if inject(message) {
            recordParticipant(event.pubkey, nickname: message.participantNickname)
        }
    }

    // MARK: - Injection & participants

    @discardableResult
    private func inject(_ message: InboundBridgeMessage) -> Bool {
        guard injectedMessageIDs.insert(message.messageID) else { return false }
        guard !(message.radioMessageIDHint.map(radioCopyAlreadyPresent) ?? false) else {
            return false
        }
        SecureLogger.info("🌉 Bridge: injected bridged message \(message.messageID.prefix(8))… from \(message.senderNickname)", category: .session)
        injectInbound?(message)
        if let radioMessageID = message.radioMessageIDHint {
            recordRadioAlias(
                eventID: message.messageID,
                radioMessageID: radioMessageID
            )
        }
        return true
    }

    private func radioCopyAlreadyPresent(_ messageID: String) -> Bool {
        observedRadioMessageIDs.contains(messageID) || (isMessageSeenLocally?(messageID) ?? false)
    }

    private func recordRadioAlias(
        eventID: String,
        radioMessageID: String
    ) {
        guard injectedRadioAliases[eventID] == nil else { return }
        injectedRadioAliases[eventID] = radioMessageID
        injectedRadioAliasOrder.append(eventID)
        guard injectedRadioAliasOrder.count > Limits.maxTrackedRadioAliases,
              let isInjectedInboundPresent else { return }

        // Arrival order and signed event timestamps are independent. The
        // conversation cap trims by timestamp, so blindly evicting the oldest
        // alias could discard the proof for a still-visible row and then
        // actively delete that history. Prune only aliases whose exact row is
        // already absent; temporary overflow is safer than losing radio-wins
        // reconciliation for any visible bridge message.
        var overflow = injectedRadioAliasOrder.count - Limits.maxTrackedRadioAliases
        var retained: [String] = []
        retained.reserveCapacity(injectedRadioAliasOrder.count)
        for candidate in injectedRadioAliasOrder {
            if overflow > 0, !isInjectedInboundPresent(candidate) {
                injectedRadioAliases.removeValue(forKey: candidate)
                overflow -= 1
            } else {
                retained.append(candidate)
            }
        }
        injectedRadioAliasOrder = retained
    }

    private func recordParticipant(_ pubkey: String, nickname: String?) {
        let cutoff = now().addingTimeInterval(-Limits.participantFreshnessSeconds)
        participants = participants.filter { $0.value.lastSeen >= cutoff }
        if participants[pubkey] == nil, participants.count >= Limits.maxParticipants,
           let oldest = participants.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
            participants.removeValue(forKey: oldest)
        }
        let previous = participants[pubkey]
        // Presence events carry no nickname, so a known name is never
        // forgotten. Radio hints deliberately do not mutate this record.
        participants[pubkey] = (
            lastSeen: now(),
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
            .filter { $0.value.lastSeen >= cutoff }
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
            // The `m` tag is `[stable ID, sender ID, wire timestamp ms]` for
            // radio/bridge duplicate detection. Those coordinates are public
            // and not cryptographically bound to this Nostr signer, so they
            // are never allowed to own bridge dedup. A copied tag can at most
            // make the attacker's own event look like a radio duplicate; it
            // cannot reserve the genuine signed event's timeline ID.
            let m = event.tags.first(where: { $0.count >= 2 && $0[0] == "m" })
            let radioMessageIDHint: String?
            if let m, m.count >= 4, m[2].count == 16, m[2].allSatisfy(\.isHexDigit),
               let timestampMs = UInt64(m[3]) {
                radioMessageIDHint = MeshMessageIdentity.stableID(
                    senderIDHex: m[2],
                    timestampMs: timestampMs,
                    content: content
                )
            } else {
                radioMessageIDHint = nil
            }
            let baseNickname = nickname?.trimmedOrNilIfEmpty ?? "anon"
            return .message(InboundBridgeMessage(
                messageID: event.id,
                radioMessageIDHint: radioMessageIDHint,
                senderNickname: baseNickname + "#" + String(event.pubkey.suffix(4)),
                participantNickname: nickname?.trimmedOrNilIfEmpty,
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
