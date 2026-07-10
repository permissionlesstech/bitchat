//
// GatewayServiceTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("Gateway mode policy")
@MainActor
struct GatewayServiceTests {
    nonisolated private static let geohash = "u4pruy"

    /// Closure-injected harness around `GatewayService` recording every
    /// side effect, with a controllable clock and relay connectivity.
    @MainActor
    private final class Fixture {
        private final class ClockBox {
            var now = Date()
        }

        var relaysConnected = true
        var currentGeohash: String? = GatewayServiceTests.geohash
        var gatewayPeers: [PeerID] = []
        var sendToGatewaySucceeds = true

        private(set) var published: [(event: NostrEvent, geohash: String)] = []
        private(set) var broadcasts: [Data] = []
        private(set) var injected: [NostrEvent] = []
        private(set) var uplinkSends: [(payload: Data, peer: PeerID)] = []
        private(set) var enabledChanges: [Bool] = []
        private(set) var scheduledDrains: [(delay: TimeInterval, work: @MainActor () -> Void)] = []

        private let clock = ClockBox()
        let defaults: UserDefaults
        let service: GatewayService

        init(enabled: Bool = true, suite: String = "GatewayServiceTests-\(UUID().uuidString)") {
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let clock = clock
            service = GatewayService(defaults: defaults) { clock.now }
            service.publishToRelays = { [weak self] event, geohash in
                self?.published.append((event, geohash))
            }
            service.broadcastToMesh = { [weak self] payload in
                self?.broadcasts.append(payload)
            }
            service.sendToGatewayPeer = { [weak self] payload, peer in
                guard let self, self.sendToGatewaySucceeds else { return false }
                self.uplinkSends.append((payload, peer))
                return true
            }
            service.availableGatewayPeers = { [weak self] in self?.gatewayPeers ?? [] }
            service.relaysConnected = { [weak self] in self?.relaysConnected ?? false }
            service.currentGeohash = { [weak self] in self?.currentGeohash }
            service.injectInbound = { [weak self] event in self?.injected.append(event) }
            service.onEnabledChanged = { [weak self] enabled in self?.enabledChanges.append(enabled) }
            // Capture drain timers instead of arming a real Task so the drain
            // is deterministic under the fake clock.
            service.scheduleDrainTimer = { [weak self] delay, work in
                self?.scheduledDrains.append((delay, work))
            }
            if enabled {
                service.setEnabled(true)
            }
        }

        func advance(_ seconds: TimeInterval) {
            clock.now = clock.now.addingTimeInterval(seconds)
        }

        /// Fires every currently-scheduled drain timer (simulating the window
        /// freeing), as the real Task would after its delay.
        func fireScheduledDrains() {
            let due = scheduledDrains
            scheduledDrains.removeAll()
            for item in due { item.work() }
        }
    }

    // MARK: Event helpers

    private func makeEvent(
        geohash: String = GatewayServiceTests.geohash,
        content: String = "hello \(UUID().uuidString.prefix(8))"
    ) throws -> NostrEvent {
        let identity = try NostrIdentity.generate()
        return try NostrProtocol.createEphemeralGeohashEvent(
            content: content,
            geohash: geohash,
            senderIdentity: identity,
            nickname: "tester"
        )
    }

    /// A copy of `event` with tampered content but the original ID and
    /// signature — what a forging gateway or mesh peer would produce.
    private func forge(_ event: NostrEvent) throws -> NostrEvent {
        let dict: [String: Any] = [
            "id": event.id,
            "pubkey": event.pubkey,
            "created_at": event.created_at,
            "kind": event.kind,
            "tags": event.tags,
            "content": event.content + " (tampered)",
            "sig": event.sig ?? ""
        ]
        return try NostrEvent(from: dict)
    }

    private func carrierPayload(
        _ event: NostrEvent,
        direction: NostrCarrierPacket.Direction = .toGateway,
        geohash: String = GatewayServiceTests.geohash
    ) throws -> Data {
        let packet = try #require(NostrCarrierPacket(direction: direction, geohash: geohash, event: event))
        return try #require(packet.encode())
    }

    private func deposit(
        _ event: NostrEvent,
        into fixture: Fixture,
        from depositor: PeerID = PeerID(str: "1122334455667788"),
        geohash: String = GatewayServiceTests.geohash
    ) throws {
        let payload = try carrierPayload(event, direction: .toGateway, geohash: geohash)
        fixture.service.handleMeshCarrier(payload, from: depositor, directedToUs: true)
    }

    // MARK: - Uplink verification gates

    @Test("publishes a verified deposit to the geo relays")
    func verifiedDepositPublished() throws {
        let fixture = Fixture()
        let event = try makeEvent()
        try deposit(event, into: fixture)

        #expect(fixture.published.count == 1)
        #expect(fixture.published.first?.event.id == event.id)
        #expect(fixture.published.first?.geohash == Self.geohash)
        // Viewing the same geohash: the carried message shows on our own timeline.
        #expect(fixture.injected.map(\.id) == [event.id])
    }

    @Test("rejects a forged signature")
    func forgedSignatureRejected() throws {
        let fixture = Fixture()
        let forged = try forge(try makeEvent())
        try deposit(forged, into: fixture)

        #expect(fixture.published.isEmpty)
        #expect(fixture.injected.isEmpty)
    }

    @Test("rejects wrong kind, geohash mismatch, and stale events")
    func structuralGates() throws {
        let fixture = Fixture()

        // Wrong kind (kind-1 text note instead of kind-20000 ephemeral).
        let identity = try NostrIdentity.generate()
        let note = try NostrProtocol.createGeohashTextNote(
            content: "note",
            geohash: Self.geohash,
            senderIdentity: identity
        )
        try deposit(note, into: fixture)
        #expect(fixture.published.isEmpty)

        // Carrier geohash disagreeing with the event's #g tag.
        let mismatched = try makeEvent(geohash: "9q8yyk")
        try deposit(mismatched, into: fixture, geohash: Self.geohash)
        #expect(fixture.published.isEmpty)

        // Stale event (beyond accepted clock skew).
        let stale = try makeEvent()
        fixture.advance(GatewayService.Limits.maxEventAgeSeconds + 60)
        try deposit(stale, into: fixture)
        #expect(fixture.published.isEmpty)
    }

    @Test("does nothing while the toggle is off")
    func disabledGatewayIgnoresDeposits() throws {
        let fixture = Fixture(enabled: false)
        try deposit(try makeEvent(), into: fixture)
        #expect(fixture.published.isEmpty)
        #expect(fixture.service.queuedUplinks.isEmpty)

        fixture.service.rebroadcastRelayEvent(try makeEvent(), geohash: Self.geohash)
        #expect(fixture.broadcasts.isEmpty)
    }

    // MARK: - Uplink quotas and rate limit

    @Test("rate-limits deposits per depositor per minute")
    func uplinkRateLimit() throws {
        let fixture = Fixture()
        let depositor = PeerID(str: "aabbccddeeff0011")

        for _ in 0..<GatewayService.Limits.uplinkEventsPerMinutePerDepositor {
            try deposit(try makeEvent(), into: fixture, from: depositor)
        }
        #expect(fixture.published.count == GatewayService.Limits.uplinkEventsPerMinutePerDepositor)

        // One over budget inside the window: dropped.
        try deposit(try makeEvent(), into: fixture, from: depositor)
        #expect(fixture.published.count == GatewayService.Limits.uplinkEventsPerMinutePerDepositor)

        // Another depositor is unaffected.
        try deposit(try makeEvent(), into: fixture, from: PeerID(str: "0011223344556677"))
        #expect(fixture.published.count == GatewayService.Limits.uplinkEventsPerMinutePerDepositor + 1)

        // The window slides.
        fixture.advance(61)
        try deposit(try makeEvent(), into: fixture, from: depositor)
        #expect(fixture.published.count == GatewayService.Limits.uplinkEventsPerMinutePerDepositor + 2)
    }

    @Test("bounds the offline uplink queue per depositor and in total, evicting oldest")
    func uplinkQueueQuotas() throws {
        let fixture = Fixture()
        fixture.relaysConnected = false

        let depositorA = PeerID(str: "1111111111111111")
        var firstFromA: NostrEvent?
        for i in 0..<(GatewayService.Limits.maxQueuedUplinksPerDepositor + 1) {
            let event = try makeEvent()
            if i == 0 { firstFromA = event }
            try deposit(event, into: fixture, from: depositorA)
        }
        // The sixth deposit from the same depositor is rejected.
        #expect(fixture.service.queuedUplinks.count == GatewayService.Limits.maxQueuedUplinksPerDepositor)

        // Fill the global queue with other depositors.
        var filler = GatewayService.Limits.maxQueuedUplinksPerDepositor
        var suffix = 2
        while filler < GatewayService.Limits.maxQueuedUplinks {
            let depositor = PeerID(str: String(repeating: "\(suffix)", count: 16))
            for _ in 0..<GatewayService.Limits.maxQueuedUplinksPerDepositor {
                try deposit(try makeEvent(), into: fixture, from: depositor)
            }
            filler += GatewayService.Limits.maxQueuedUplinksPerDepositor
            suffix += 1
        }
        #expect(fixture.service.queuedUplinks.count == GatewayService.Limits.maxQueuedUplinks)

        // One more from a fresh depositor evicts the oldest queued deposit.
        let newest = try makeEvent()
        try deposit(newest, into: fixture, from: PeerID(str: "9999999999999999"))
        #expect(fixture.service.queuedUplinks.count == GatewayService.Limits.maxQueuedUplinks)
        #expect(fixture.service.queuedUplinks.contains { $0.event.id == newest.id })
        #expect(!fixture.service.queuedUplinks.contains { $0.event.id == firstFromA?.id })

        // Relay connectivity returning flushes the queue.
        fixture.relaysConnected = true
        fixture.service.flushQueuedUplinks()
        #expect(fixture.published.count == GatewayService.Limits.maxQueuedUplinks)
        #expect(fixture.service.queuedUplinks.isEmpty)
    }

    @Test("absorbs repeat deposits of the same event")
    func repeatDepositAbsorbed() throws {
        let fixture = Fixture()
        let event = try makeEvent()
        try deposit(event, into: fixture)
        try deposit(event, into: fixture, from: PeerID(str: "8877665544332211"))
        #expect(fixture.published.count == 1)
    }

    @Test("a quota-dropped deposit is not rendered on the local timeline")
    func quotaDroppedDepositNotInjected() throws {
        let fixture = Fixture()
        fixture.relaysConnected = false
        let depositor = PeerID(str: "1111111111111111")

        // Fill this depositor's offline queue to its per-depositor cap; each
        // accepted deposit is rendered locally (we view that geohash).
        for _ in 0..<GatewayService.Limits.maxQueuedUplinksPerDepositor {
            try deposit(try makeEvent(), into: fixture, from: depositor)
        }
        #expect(fixture.service.queuedUplinks.count == GatewayService.Limits.maxQueuedUplinksPerDepositor)
        #expect(fixture.injected.count == GatewayService.Limits.maxQueuedUplinksPerDepositor)

        // One past the cap: dropped by the queue quota, so it is neither
        // queued nor shown — no phantom local message.
        try deposit(try makeEvent(), into: fixture, from: depositor)
        #expect(fixture.service.queuedUplinks.count == GatewayService.Limits.maxQueuedUplinksPerDepositor)
        #expect(fixture.injected.count == GatewayService.Limits.maxQueuedUplinksPerDepositor)
    }

    // MARK: - Loop prevention

    @Test("never re-publishes or re-carries an event learned from a fromGateway broadcast")
    func meshCarriedNeverRepublished() throws {
        let fixture = Fixture()
        let event = try makeEvent()
        let broadcast = try carrierPayload(event, direction: .fromGateway)

        // Another gateway rebroadcast this event onto the mesh; we saw it.
        fixture.service.handleMeshCarrier(broadcast, from: PeerID(str: "8877665544332211"), directedToUs: false)
        #expect(fixture.injected.map(\.id) == [event.id])

        // Rule: a deposit of the same event must never be published…
        try deposit(event, into: fixture)
        #expect(fixture.published.isEmpty)

        // …a relay echo of it must never be rebroadcast (we'd loop it back)…
        fixture.service.rebroadcastRelayEvent(event, geohash: Self.geohash)
        #expect(fixture.broadcasts.isEmpty)

        // …and it must never be re-uplinked from this device.
        fixture.relaysConnected = false
        fixture.gatewayPeers = [PeerID(str: "8877665544332211")]
        #expect(!fixture.service.uplinkViaMesh(event: event, geohash: Self.geohash))
        #expect(fixture.uplinkSends.isEmpty)
    }

    @Test("rebroadcasts a relay event at most once, absorbing echoes")
    func relayEventRebroadcastOnce() throws {
        let fixture = Fixture()
        let event = try makeEvent()

        fixture.service.rebroadcastRelayEvent(event, geohash: Self.geohash)
        fixture.service.rebroadcastRelayEvent(event, geohash: Self.geohash)
        #expect(fixture.broadcasts.count == 1)

        // The rebroadcast payload decodes as a fromGateway carrier for the
        // same signed event.
        let payload = try #require(fixture.broadcasts.first)
        let decoded = try #require(NostrCarrierPacket.decode(payload))
        #expect(decoded.direction == .fromGateway)
        #expect(decoded.event()?.id == event.id)
    }

    @Test("never downlink-rebroadcasts an event it uplinked and saw echo back")
    func uplinkedEventNotSelfEchoed() throws {
        let fixture = Fixture()
        let event = try makeEvent()

        // A mesh-only peer deposits an event; the gateway uplinks (publishes)
        // it to the relays (loop rule 2 records it in publishedEventIDs).
        try deposit(event, into: fixture)
        #expect(fixture.published.map(\.event.id) == [event.id])

        // The gateway's own geohash subscription now delivers that same event
        // right back (~0.15s later on device). It originated on this mesh, so
        // rebroadcasting it would double BLE airtime — the device-confirmed
        // self-echo. It must be suppressed.
        fixture.service.rebroadcastRelayEvent(event, geohash: Self.geohash)
        #expect(fixture.broadcasts.isEmpty)

        // Sanity: a genuine inbound-from-internet event (never uplinked here)
        // still downlink-rebroadcasts normally.
        let inbound = try makeEvent()
        fixture.service.rebroadcastRelayEvent(inbound, geohash: Self.geohash)
        #expect(fixture.broadcasts.count == 1)
        let payload = try #require(fixture.broadcasts.first)
        let decoded = try #require(NostrCarrierPacket.decode(payload))
        #expect(decoded.event()?.id == inbound.id)
    }

    @Test("a forged broadcast cannot poison the loop-prevention set")
    func forgedBroadcastDoesNotPoison() throws {
        let fixture = Fixture()
        let event = try makeEvent()
        let forgedPayload = try carrierPayload(try forge(event), direction: .fromGateway)

        fixture.service.handleMeshCarrier(forgedPayload, from: PeerID(str: "8877665544332211"), directedToUs: false)
        #expect(fixture.injected.isEmpty)

        // The genuine event still uplinks: the forged copy (sharing its ID)
        // was rejected before the mesh-carried marking.
        try deposit(event, into: fixture)
        #expect(fixture.published.map(\.event.id) == [event.id])
    }

    // MARK: - Downlink bandwidth guard

    @Test("caps mesh rebroadcasts per minute, queueing with drop-oldest")
    func downlinkBudget() throws {
        let fixture = Fixture()
        let overBudget = GatewayService.Limits.downlinkEventsPerMinute + 5

        var events: [NostrEvent] = []
        for _ in 0..<overBudget {
            let event = try makeEvent()
            events.append(event)
            fixture.service.rebroadcastRelayEvent(event, geohash: Self.geohash)
        }
        #expect(fixture.broadcasts.count == GatewayService.Limits.downlinkEventsPerMinute)

        // Once the window slides, the next relay event drains the backlog too.
        fixture.advance(61)
        fixture.service.rebroadcastRelayEvent(try makeEvent(), geohash: Self.geohash)
        #expect(fixture.broadcasts.count == overBudget + 1)
    }

    @Test("does not spend downlink budget on stale backfill or geohash mismatch")
    func downlinkDropsStaleAndMismatched() throws {
        let fixture = Fixture()

        // A fresh, matching event rebroadcasts.
        let fresh = try makeEvent()
        // An event whose #g tag disagrees with the carrier geohash.
        let mismatched = try makeEvent(geohash: "9q8yyk")
        // An event that will age past the receiver window before we offer it.
        let willBeStale = try makeEvent()

        fixture.service.rebroadcastRelayEvent(fresh, geohash: Self.geohash)
        #expect(fixture.broadcasts.count == 1)

        fixture.service.rebroadcastRelayEvent(mismatched, geohash: Self.geohash)
        #expect(fixture.broadcasts.count == 1) // geohash mismatch: dropped pre-budget

        fixture.advance(GatewayService.Limits.maxEventAgeSeconds + 60)
        fixture.service.rebroadcastRelayEvent(willBeStale, geohash: Self.geohash)
        #expect(fixture.broadcasts.count == 1) // stale backfill: dropped pre-budget
    }

    @Test("drains a downlink backlog on the scheduled timer when the channel goes quiet")
    func downlinkDrainsOnTimer() throws {
        let fixture = Fixture()
        let overBudget = GatewayService.Limits.downlinkEventsPerMinute + 5

        for _ in 0..<overBudget {
            fixture.service.rebroadcastRelayEvent(try makeEvent(), geohash: Self.geohash)
        }
        // Budget spent; the tail is queued and a drain timer was armed.
        #expect(fixture.broadcasts.count == GatewayService.Limits.downlinkEventsPerMinute)
        #expect(!fixture.scheduledDrains.isEmpty)

        // The channel goes quiet — no new inbound event. The window frees and
        // the timer fires on its own, draining the remaining backlog.
        fixture.advance(61)
        fixture.fireScheduledDrains()
        #expect(fixture.broadcasts.count == overBudget)
    }

    // MARK: - Receiver downlink handling

    @Test("injects a carried event once, even when broadcast twice")
    func downlinkInjectedOnce() throws {
        let fixture = Fixture(enabled: false) // receivers need no toggle
        let event = try makeEvent()
        let payload = try carrierPayload(event, direction: .fromGateway)

        fixture.service.handleMeshCarrier(payload, from: PeerID(str: "8877665544332211"), directedToUs: false)
        fixture.service.handleMeshCarrier(payload, from: PeerID(str: "7766554433221100"), directedToUs: false)
        #expect(fixture.injected.map(\.id) == [event.id])
    }

    @Test("only injects events for the geohash channel being viewed")
    func downlinkChannelScoped() throws {
        let fixture = Fixture(enabled: false)
        fixture.currentGeohash = "9q8yyk"
        let event = try makeEvent()
        let payload = try carrierPayload(event, direction: .fromGateway)

        fixture.service.handleMeshCarrier(payload, from: PeerID(str: "8877665544332211"), directedToUs: false)
        #expect(fixture.injected.isEmpty)
    }

    @Test("a directed fromGateway or broadcast toGateway carrier is malformed and dropped")
    func directionMisuseDropped() throws {
        let fixture = Fixture()
        let event = try makeEvent()

        let downlink = try carrierPayload(event, direction: .fromGateway)
        fixture.service.handleMeshCarrier(downlink, from: PeerID(str: "8877665544332211"), directedToUs: true)
        #expect(fixture.injected.isEmpty)

        let uplink = try carrierPayload(event, direction: .toGateway)
        fixture.service.handleMeshCarrier(uplink, from: PeerID(str: "8877665544332211"), directedToUs: false)
        #expect(fixture.published.isEmpty)
    }

    // MARK: - Mesh-only sender uplink

    @Test("uplinks via a mesh gateway only when relays are down and a gateway exists")
    func uplinkViaMeshConditions() throws {
        let fixture = Fixture(enabled: false)
        let gatewayPeer = PeerID(str: "8877665544332211")
        let event = try makeEvent()

        // Relays working: no mesh uplink.
        fixture.relaysConnected = true
        fixture.gatewayPeers = [gatewayPeer]
        #expect(!fixture.service.uplinkViaMesh(event: event, geohash: Self.geohash))

        // Relays down, no gateway around: no mesh uplink.
        fixture.relaysConnected = false
        fixture.gatewayPeers = []
        #expect(!fixture.service.uplinkViaMesh(event: event, geohash: Self.geohash))

        // Relays down and a gateway peer advertised: uplink goes out.
        fixture.gatewayPeers = [gatewayPeer]
        #expect(fixture.service.uplinkViaMesh(event: event, geohash: Self.geohash))
        #expect(fixture.uplinkSends.count == 1)
        #expect(fixture.uplinkSends.first?.peer == gatewayPeer)

        let sentPayload = try #require(fixture.uplinkSends.first?.payload)
        let sent = try #require(NostrCarrierPacket.decode(sentPayload))
        #expect(sent.direction == .toGateway)
        #expect(sent.geohash == Self.geohash)
        #expect(sent.event()?.id == event.id)

        // A failed transport hand-off reports false.
        fixture.sendToGatewaySucceeds = false
        #expect(!fixture.service.uplinkViaMesh(event: try makeEvent(), geohash: Self.geohash))
    }

    @Test("uplinkViaMesh backstop refuses an event this gateway already published")
    func uplinkViaMeshBackstopsPublished() throws {
        let fixture = Fixture()
        let event = try makeEvent()

        // This gateway publishes the event to relays (loop rule 2 records it
        // in publishedEventIDs).
        try deposit(event, into: fixture)
        #expect(fixture.published.map(\.event.id) == [event.id])

        // Relays then drop and a gateway peer appears. The same event must not
        // be re-uplinked from this device — the publishedEventIDs backstop in
        // uplinkViaMesh catches it even though it was never a mesh broadcast.
        fixture.relaysConnected = false
        fixture.gatewayPeers = [PeerID(str: "8877665544332211")]
        #expect(!fixture.service.uplinkViaMesh(event: event, geohash: Self.geohash))
        #expect(fixture.uplinkSends.isEmpty)
    }

    // MARK: - Toggle

    @Test("persists the toggle and reports changes")
    func togglePersistsAndNotifies() throws {
        let suite = "GatewayServiceTests-\(UUID().uuidString)"
        let fixture = Fixture(enabled: false, suite: suite)
        #expect(!fixture.service.isEnabled)

        fixture.service.setEnabled(true)
        #expect(fixture.enabledChanges == [true])
        // Setting the same value again is a no-op.
        fixture.service.setEnabled(true)
        #expect(fixture.enabledChanges == [true])

        // A fresh service over the same defaults restores the toggle.
        let revived = GatewayService(defaults: UserDefaults(suiteName: suite)!)
        #expect(revived.isEnabled)

        fixture.service.setEnabled(false)
        #expect(fixture.enabledChanges == [true, false])
        fixture.defaults.removePersistentDomain(forName: suite)
    }

    @Test("disabling the toggle drops queued work")
    func disableClearsQueues() throws {
        let fixture = Fixture()
        fixture.relaysConnected = false
        try deposit(try makeEvent(), into: fixture)
        #expect(fixture.service.queuedUplinks.count == 1)

        fixture.service.setEnabled(false)
        #expect(fixture.service.queuedUplinks.isEmpty)

        // Nothing to flush after re-enabling.
        fixture.service.setEnabled(true)
        fixture.relaysConnected = true
        fixture.service.flushQueuedUplinks()
        #expect(fixture.published.isEmpty)
    }
}
