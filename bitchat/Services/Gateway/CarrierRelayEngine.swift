//
// CarrierRelayEngine.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

/// Shared uplink/downlink queueing, rate-limiting, freshness, and loop-prevention
/// state machine used by `GatewayService` and `BridgeService`.
@MainActor
final class CarrierRelayEngine {
    struct Config {
        let maxQueuedUplinks: Int
        let maxQueuedUplinksPerDepositor: Int
        let uplinkEventsPerMinutePerDepositor: Int
        let downlinkEventsPerMinute: Int
        let maxPendingDownlinks: Int
        let maxEventAgeSeconds: TimeInterval
        let maxTrackedEventIDs: Int
    }

    struct QueuedUplink {
        let depositor: PeerID
        let scope: String
        let event: NostrEvent
    }

    /// Loop rule 1: event IDs seen in downlink (`fromGateway`/`fromBridge`) mesh broadcasts.
    var meshBroadcastEventIDs: BoundedIDSet
    /// Loop rule 2: event IDs this device already published to relays.
    var publishedEventIDs: BoundedIDSet
    /// Loop rule 3: event IDs this device already rebroadcast onto the mesh.
    var rebroadcastEventIDs: BoundedIDSet

    private(set) var queuedUplinks: [QueuedUplink] = []
    private(set) var pendingDownlinks: [(event: NostrEvent, scope: String)] = []
    private var uplinkDepositTimes: [PeerID: [Date]] = [:]
    private var downlinkSendTimes: [Date] = []
    private var downlinkDrainScheduled = false

    private let config: Config
    private let now: () -> Date

    init(config: Config, now: @escaping () -> Date) {
        self.config = config
        self.now = now
        self.meshBroadcastEventIDs = BoundedIDSet(capacity: config.maxTrackedEventIDs)
        self.publishedEventIDs = BoundedIDSet(capacity: config.maxTrackedEventIDs)
        self.rebroadcastEventIDs = BoundedIDSet(capacity: config.maxTrackedEventIDs)
    }

    // MARK: - Lifecycle

    func clearQueuesOnDisable() {
        queuedUplinks.removeAll()
        pendingDownlinks.removeAll()
        uplinkDepositTimes.removeAll()
    }

    func resetForPanic() {
        queuedUplinks.removeAll(keepingCapacity: false)
        pendingDownlinks.removeAll(keepingCapacity: false)
        downlinkDrainScheduled = false
        uplinkDepositTimes.removeAll(keepingCapacity: false)
        downlinkSendTimes.removeAll(keepingCapacity: false)
        meshBroadcastEventIDs = BoundedIDSet(capacity: config.maxTrackedEventIDs)
        publishedEventIDs = BoundedIDSet(capacity: config.maxTrackedEventIDs)
        rebroadcastEventIDs = BoundedIDSet(capacity: config.maxTrackedEventIDs)
    }

    // MARK: - Freshness & Dedup

    /// True when `event.created_at` is within the accepted clock skew window.
    func isFresh(_ event: NostrEvent) -> Bool {
        abs(now().timeIntervalSince1970 - TimeInterval(event.created_at)) <= config.maxEventAgeSeconds
    }

    func isUplinkDuplicate(_ eventID: String) -> Bool {
        meshBroadcastEventIDs.contains(eventID)
            || publishedEventIDs.contains(eventID)
            || queuedUplinks.contains(where: { $0.event.id == eventID })
    }

    func hasPendingDownlink(_ eventID: String) -> Bool {
        pendingDownlinks.contains(where: { $0.event.id == eventID })
    }

    func removePendingDownlinks(where shouldRemove: ((event: NostrEvent, scope: String)) -> Bool) {
        pendingDownlinks.removeAll(where: shouldRemove)
    }

    // MARK: - Uplink Queue & Rate Limiting

    @discardableResult
    func enqueueUplink(depositor: PeerID, scope: String, event: NostrEvent) -> Bool {
        let fromDepositor = queuedUplinks.filter { $0.depositor == depositor }.count
        guard fromDepositor < config.maxQueuedUplinksPerDepositor else {
            return false
        }
        if queuedUplinks.count >= config.maxQueuedUplinks {
            queuedUplinks.removeFirst(queuedUplinks.count - config.maxQueuedUplinks + 1)
        }
        queuedUplinks.append(QueuedUplink(depositor: depositor, scope: scope, event: event))
        return true
    }

    func flushQueuedUplinks(publish: (NostrEvent, String) -> Void) {
        guard !queuedUplinks.isEmpty else { return }
        let queued = queuedUplinks
        queuedUplinks.removeAll()
        for item in queued where !publishedEventIDs.contains(item.event.id) {
            publish(item.event, item.scope)
        }
    }

    func allowUplinkDeposit(from depositor: PeerID) -> Bool {
        let currentTime = now()
        let cutoff = currentTime.addingTimeInterval(-60)
        var times = uplinkDepositTimes[depositor, default: []]
        times.removeAll { $0 < cutoff }
        guard times.count < config.uplinkEventsPerMinutePerDepositor else {
            uplinkDepositTimes[depositor] = times
            return false
        }
        times.append(currentTime)
        uplinkDepositTimes[depositor] = times
        if uplinkDepositTimes.count > config.maxTrackedEventIDs {
            uplinkDepositTimes = uplinkDepositTimes.filter { $0.value.contains { $0 >= cutoff } }
        }
        return true
    }

    // MARK: - Downlink Queue & Paced Drain

    func enqueuePendingDownlink(event: NostrEvent, scope: String) {
        pendingDownlinks.append((event, scope))
        if pendingDownlinks.count > config.maxPendingDownlinks {
            // Bandwidth guard: drop-oldest — fresher chat is worth more. Dropped
            // events are not yet marked in `rebroadcastEventIDs`, so a later
            // relay redelivery can still carry them.
            pendingDownlinks.removeFirst(pendingDownlinks.count - config.maxPendingDownlinks)
        }
    }

    func drainPendingDownlinks(
        direction: NostrCarrierPacket.Direction,
        shouldSend: (NostrEvent, String) -> Bool = { _, _ in true },
        send: (Data, NostrEvent) -> Void,
        scheduleTimer: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)?,
        onScheduledDrain: @escaping @MainActor () -> Void
    ) {
        let cutoff = now().addingTimeInterval(-60)
        downlinkSendTimes.removeAll { $0 < cutoff }
        while !pendingDownlinks.isEmpty,
              downlinkSendTimes.count < config.downlinkEventsPerMinute {
            let (event, scope) = pendingDownlinks.removeFirst()
            guard isFresh(event), shouldSend(event, scope) else { continue }
            guard let carrier = NostrCarrierPacket(direction: direction, geohash: scope, event: event),
                  let payload = carrier.encode() else { continue }
            send(payload, event)
            rebroadcastEventIDs.insert(event.id)
            downlinkSendTimes.append(now())
        }
        scheduleDownlinkDrainIfNeeded(
            jitterDelay: nil,
            scheduleTimer: scheduleTimer,
            onFire: onScheduledDrain
        )
    }

    func scheduleDownlinkDrainIfNeeded(
        jitterDelay: TimeInterval?,
        scheduleTimer: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)?,
        onFire: @escaping @MainActor () -> Void
    ) {
        guard !pendingDownlinks.isEmpty, !downlinkDrainScheduled else { return }
        let delay: TimeInterval
        if let jitterDelay {
            delay = jitterDelay
        } else {
            let oldest = downlinkSendTimes.min() ?? now()
            delay = max(0.05, 60 - now().timeIntervalSince(oldest))
        }
        downlinkDrainScheduled = true
        let fire: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.downlinkDrainScheduled = false
            onFire()
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
}
