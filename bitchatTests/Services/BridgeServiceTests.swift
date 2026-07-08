//
// BridgeServiceTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("Mesh bridge policy")
@MainActor
struct BridgeServiceTests {
    private static let cell = "u4pruy"

    /// Closure-injected harness around `BridgeService` recording every side
    /// effect, with a controllable clock, location, and connectivity.
    @MainActor
    private final class Fixture {
        private final class ClockBox {
            var now = Date()
        }

        var relaysConnected = true
        var locationCell: String? = BridgeServiceTests.cell
        var meshAdvertisedCell: String?
        var bridgePeers: [PeerID] = []
        var gatewayOn = true
        var sendSucceeds = true
        var locallySeenMessageIDs: Set<String> = []
        var nickname = "tester"

        private(set) var published: [(event: NostrEvent, cell: String)] = []

        /// Published chat messages only — the fixture's own presence
        /// heartbeats (kind 20001, sent on enable) are filtered out.
        var publishedMessages: [(event: NostrEvent, cell: String)] {
            published.filter { $0.event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue }
        }
        private(set) var broadcasts: [Data] = []
        private(set) var injected: [BridgeService.InboundBridgeMessage] = []
        private(set) var uplinkSends: [(payload: Data, peer: PeerID)] = []
        private(set) var openedSubscriptions: [[String]] = []
        private(set) var closedSubscriptions = 0
        private(set) var enabledChanges: [Bool] = []
        private(set) var cellChanges: [String?] = []
        private(set) var scheduledTimers: [(delay: TimeInterval, work: @MainActor () -> Void)] = []

        private let clock = ClockBox()
        let identity: NostrIdentity
        let defaults: UserDefaults
        let service: BridgeService

        init(enabled: Bool = true) {
            let suite = "BridgeServiceTests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            identity = try! NostrIdentity.generate()
            let clock = clock
            service = BridgeService(defaults: defaults) { clock.now }
            service.publishToRelays = { [weak self] event, cell in
                self?.published.append((event, cell))
            }
            service.openSubscription = { [weak self] cells in
                self?.openedSubscriptions.append(cells)
            }
            service.closeSubscription = { [weak self] in
                self?.closedSubscriptions += 1
            }
            service.relaysConnected = { [weak self] in self?.relaysConnected ?? false }
            service.locationCell = { [weak self] in self?.locationCell }
            service.meshAdvertisedCell = { [weak self] in self?.meshAdvertisedCell }
            service.sendToBridgePeer = { [weak self] payload, peer in
                guard let self, self.sendSucceeds else { return false }
                self.uplinkSends.append((payload, peer))
                return true
            }
            service.availableBridgePeers = { [weak self] in self?.bridgePeers ?? [] }
            service.broadcastToMesh = { [weak self] payload in
                self?.broadcasts.append(payload)
            }
            service.injectInbound = { [weak self] message in
                self?.injected.append(message)
            }
            service.isMessageSeenLocally = { [weak self] id in
                self?.locallySeenMessageIDs.contains(id) ?? false
            }
            service.gatewayEnabled = { [weak self] in self?.gatewayOn ?? false }
            service.deriveIdentity = { [weak self] _ in
                guard let self else { throw NostrError.invalidEvent }
                return self.identity
            }
            service.myNickname = { [weak self] in self?.nickname ?? "" }
            service.onEnabledChanged = { [weak self] enabled in self?.enabledChanges.append(enabled) }
            service.onActiveCellChanged = { [weak self] cell in self?.cellChanges.append(cell) }
            service.scheduleTimer = { [weak self] delay, work in
                self?.scheduledTimers.append((delay, work))
            }
            if enabled {
                service.setEnabled(true)
            }
        }

        func advance(_ seconds: TimeInterval) {
            clock.now = clock.now.addingTimeInterval(seconds)
        }

        func fireScheduledTimers() {
            let due = scheduledTimers
            scheduledTimers.removeAll()
            for item in due { item.work() }
        }
    }

    // MARK: Event helpers

    private func makeRemoteEvent(
        cell: String = BridgeServiceTests.cell,
        content: String = "hi \(UUID().uuidString.prefix(8))",
        meshMessageID: String? = UUID().uuidString
    ) throws -> NostrEvent {
        let identity = try NostrIdentity.generate()
        return try NostrProtocol.createBridgeMeshEvent(
            content: content,
            cell: cell,
            senderIdentity: identity,
            nickname: "remote",
            meshMessageID: meshMessageID
        )
    }

    private func makePresenceEvent(cell: String = BridgeServiceTests.cell) throws -> NostrEvent {
        try NostrProtocol.createBridgePresenceEvent(cell: cell, senderIdentity: NostrIdentity.generate())
    }

    private func carrier(
        _ event: NostrEvent,
        direction: NostrCarrierPacket.Direction,
        cell: String = BridgeServiceTests.cell
    ) throws -> NostrCarrierPacket {
        try #require(NostrCarrierPacket(direction: direction, geohash: cell, event: event))
    }

    // MARK: - Lifecycle & rendezvous

    @Test func enablingOpensSubscriptionForCellAndNeighbors() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()

        #expect(fixture.service.activeCell == Self.cell)
        let cells = try #require(fixture.openedSubscriptions.first)
        #expect(cells.first == Self.cell)
        #expect(cells.count == 9) // own cell + 8 neighbors
        #expect(fixture.service.subscribedCells.count == 9)
    }

    @Test func noLocationFallsBackToMeshAdvertisedCell() {
        let fixture = Fixture(enabled: true)
        fixture.locationCell = nil
        fixture.meshAdvertisedCell = "u4prux"
        fixture.service.refreshRendezvous()

        #expect(fixture.service.activeCell == "u4prux")
    }

    @Test func disablingClosesSubscriptionAndClearsState() {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        fixture.service.setEnabled(false)

        #expect(fixture.closedSubscriptions >= 1)
        #expect(fixture.service.activeCell == nil)
        #expect(fixture.service.bridgedPeerCount == 0)
    }

    @Test func togglePersistsAcrossInstances() {
        let fixture = Fixture(enabled: true)
        let revived = BridgeService(defaults: fixture.defaults)
        #expect(revived.isEnabled)
    }

    // MARK: - Outgoing

    @Test func outgoingPublishesSignedRendezvousEventWithMeshMessageID() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let messageID = UUID().uuidString

        fixture.service.bridgeOutgoing(content: "hello hill", messageID: messageID)

        let published = try #require(fixture.published.last)
        #expect(published.cell == Self.cell)
        #expect(published.event.isValidSignature())
        #expect(published.event.content == "hello hill")
        #expect(published.event.tags.contains(["r", Self.cell]))
        #expect(published.event.tags.contains(["m", messageID]))
        #expect(published.event.tags.contains(["n", "tester"]))
    }

    @Test func nearbyOnlySuppressesTheBridgedCopy() {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        fixture.service.nearbyOnly = true

        fixture.service.bridgeOutgoing(content: "just us", messageID: UUID().uuidString)

        #expect(fixture.publishedMessages.isEmpty)
        #expect(fixture.uplinkSends.isEmpty)
    }

    @Test func outgoingWithoutRelaysDepositsWithBridgePeer() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        fixture.relaysConnected = false
        fixture.bridgePeers = [PeerID(str: "abcdef0123456789")]

        fixture.service.bridgeOutgoing(content: "no internet here", messageID: UUID().uuidString)

        #expect(fixture.publishedMessages.isEmpty)
        let sent = try #require(fixture.uplinkSends.first)
        let carrier = try #require(NostrCarrierPacket.decode(sent.payload))
        #expect(carrier.direction == .toBridge)
        #expect(carrier.geohash == Self.cell)
    }

    @Test func ownRelayBackfilledEventIsIgnoredAfterRestart() throws {
        // Field bug: a relaunch wipes the published-ID cache, and relay
        // backfill then re-delivered the device's own pre-restart events as
        // "bridged". Self-recognition by the deterministic rendezvous pubkey
        // must catch them with no cache state at all.
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let ownOldEvent = try NostrProtocol.createBridgeMeshEvent(
            content: "sent before the restart",
            cell: Self.cell,
            senderIdentity: fixture.identity, // == deriveIdentity(cell)
            nickname: "tester",
            meshMessageID: UUID().uuidString
        )

        fixture.service.handleRendezvousEvent(ownOldEvent)

        #expect(fixture.injected.isEmpty)
        #expect(fixture.broadcasts.isEmpty)
        #expect(fixture.service.bridgedPeerCount == 0)
    }

    @Test func ownEventComingBackFromSubscriptionIsIgnored() {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        fixture.service.bridgeOutgoing(content: "echo me", messageID: UUID().uuidString)
        let ownEvent = fixture.published[0].event

        fixture.service.handleRendezvousEvent(ownEvent)

        #expect(fixture.injected.isEmpty)
        #expect(fixture.broadcasts.isEmpty)
        #expect(fixture.service.bridgedPeerCount == 0)
    }

    // MARK: - Subscription ingress

    @Test func remoteMessageInjectsAndDownlinks() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let event = try makeRemoteEvent()

        fixture.service.handleRendezvousEvent(event)

        #expect(fixture.injected.count == 1)
        #expect(fixture.injected.first?.content == event.content)
        #expect(fixture.service.bridgedPeerCount == 1)
        // Gateway duty: remote event rides out as a fromBridge broadcast.
        let broadcast = try #require(fixture.broadcasts.first)
        let carrier = try #require(NostrCarrierPacket.decode(broadcast))
        #expect(carrier.direction == .fromBridge)
    }

    @Test func neighborCellEventIsAccepted() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let neighbor = try #require(Geohash.neighbors(of: Self.cell).first)
        let event = try makeRemoteEvent(cell: neighbor)

        fixture.service.handleRendezvousEvent(event)

        #expect(fixture.injected.count == 1)
    }

    @Test func outOfRingCellEventIsRejected() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let event = try makeRemoteEvent(cell: "9q8yyk")

        fixture.service.handleRendezvousEvent(event)

        #expect(fixture.injected.isEmpty)
        #expect(fixture.broadcasts.isEmpty)
    }

    @Test func locallySeenMessageIsNeitherInjectedNorDownlinked() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let messageID = UUID().uuidString
        fixture.locallySeenMessageIDs = [messageID]
        let event = try makeRemoteEvent(meshMessageID: messageID)

        fixture.service.handleRendezvousEvent(event)

        // The island already heard this over radio: no duplicate render, no
        // wasted airtime — but the sender still counts as a (local)
        // participant, never a bridged one.
        #expect(fixture.injected.isEmpty)
        #expect(fixture.broadcasts.isEmpty)
        #expect(fixture.service.bridgedPeerCount == 0)
    }

    @Test func duplicateSubscriptionEventInjectsOnce() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let event = try makeRemoteEvent()

        fixture.service.handleRendezvousEvent(event)
        fixture.service.handleRendezvousEvent(event)

        #expect(fixture.injected.count == 1)
        #expect(fixture.broadcasts.count == 1)
    }

    @Test func gatewayOffMeansNoDownlinkButStillInjects() throws {
        let fixture = Fixture(enabled: true)
        fixture.gatewayOn = false
        fixture.service.refreshRendezvous()
        let event = try makeRemoteEvent()

        fixture.service.handleRendezvousEvent(event)

        #expect(fixture.injected.count == 1)
        #expect(fixture.broadcasts.isEmpty)
    }

    @Test func presenceCountsParticipantWithoutInjection() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()

        fixture.service.handleRendezvousEvent(try makePresenceEvent())

        #expect(fixture.injected.isEmpty)
        #expect(fixture.service.bridgedPeerCount == 1)
    }

    @Test func staleParticipantsAgeOutOfTheCount() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        fixture.service.handleRendezvousEvent(try makePresenceEvent())
        #expect(fixture.service.bridgedPeerCount == 1)

        fixture.advance(BridgeService.Limits.participantFreshnessSeconds + 1)
        fixture.service.publishPresence() // any activity recomputes via prune path
        fixture.fireScheduledTimers()

        #expect(fixture.service.bridgedPeerCount == 0)
    }

    @Test func staleEventIsRejected() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let event = try makeRemoteEvent()
        fixture.advance(BridgeService.Limits.maxEventAgeSeconds + 60)

        fixture.service.handleRendezvousEvent(event)

        #expect(fixture.injected.isEmpty)
    }

    // MARK: - Downlink budget

    @Test func downlinkRespectsPerMinuteBudgetAndDrainsLater() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()

        for _ in 0..<(BridgeService.Limits.downlinkEventsPerMinute + 5) {
            fixture.service.handleRendezvousEvent(try makeRemoteEvent())
        }

        #expect(fixture.broadcasts.count == BridgeService.Limits.downlinkEventsPerMinute)
        // Window frees: the armed timer drains the backlog.
        fixture.advance(61)
        fixture.fireScheduledTimers()
        #expect(fixture.broadcasts.count == BridgeService.Limits.downlinkEventsPerMinute + 5)
    }

    // MARK: - Mesh carrier ingress (receiver role)

    @Test func fromBridgeBroadcastInjectsForMeshOnlyReceiver() throws {
        // Reception is not gated on the toggle: passive radio.
        let fixture = Fixture(enabled: false)
        let event = try makeRemoteEvent()

        fixture.service.handleMeshCarrier(
            try carrier(event, direction: .fromBridge),
            from: PeerID(str: "aabbccdd00112233"),
            directedToUs: false
        )

        #expect(fixture.injected.count == 1)
        #expect(fixture.service.bridgedPeerCount == 1)
    }

    @Test func fromBridgeBroadcastDedupsAcrossMeshPaths() throws {
        let fixture = Fixture(enabled: false)
        let event = try makeRemoteEvent()
        let packet = try carrier(event, direction: .fromBridge)
        let peer = PeerID(str: "aabbccdd00112233")

        fixture.service.handleMeshCarrier(packet, from: peer, directedToUs: false)
        fixture.service.handleMeshCarrier(packet, from: peer, directedToUs: false)

        #expect(fixture.injected.count == 1)
    }

    @Test func meshCarriedEventIsNeverRebroadcast() throws {
        // Loop rule 1: a second gateway hearing a fromBridge broadcast must
        // not downlink the same event when its own subscription delivers it.
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let event = try makeRemoteEvent()

        fixture.service.handleMeshCarrier(
            try carrier(event, direction: .fromBridge),
            from: PeerID(str: "aabbccdd00112233"),
            directedToUs: false
        )
        fixture.service.handleRendezvousEvent(event)

        #expect(fixture.broadcasts.isEmpty)
        #expect(fixture.injected.count == 1)
    }

    @Test func directedFromBridgeIsMalformedAndDropped() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()

        fixture.service.handleMeshCarrier(
            try carrier(makeRemoteEvent(), direction: .fromBridge),
            from: PeerID(str: "aabbccdd00112233"),
            directedToUs: true
        )

        #expect(fixture.injected.isEmpty)
    }

    @Test func tamperedCarrierEventIsRejected() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let event = try makeRemoteEvent()
        let dict: [String: Any] = [
            "id": event.id,
            "pubkey": event.pubkey,
            "created_at": event.created_at,
            "kind": event.kind,
            "tags": event.tags,
            "content": event.content + " (tampered)",
            "sig": event.sig ?? "",
        ]
        let forged = try NostrEvent(from: dict)

        fixture.service.handleMeshCarrier(
            try carrier(forged, direction: .fromBridge),
            from: PeerID(str: "aabbccdd00112233"),
            directedToUs: false
        )

        #expect(fixture.injected.isEmpty)
    }

    // MARK: - Uplink deposits (gateway role)

    @Test func validDepositIsPublishedWhenRelaysUp() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let event = try makeRemoteEvent()

        fixture.service.handleMeshCarrier(
            try carrier(event, direction: .toBridge),
            from: PeerID(str: "aabbccdd00112233"),
            directedToUs: true
        )

        #expect(fixture.published.contains { $0.event.id == event.id })
        // Deposits never inject: the depositor's radio broadcast already
        // carried the message to this island.
        #expect(fixture.injected.isEmpty)
    }

    @Test func depositQueuesWhileRelaysDownAndFlushesOnReconnect() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        fixture.relaysConnected = false
        let event = try makeRemoteEvent()

        fixture.service.handleMeshCarrier(
            try carrier(event, direction: .toBridge),
            from: PeerID(str: "aabbccdd00112233"),
            directedToUs: true
        )
        #expect(fixture.publishedMessages.isEmpty)
        #expect(fixture.service.queuedUplinks.count == 1)

        fixture.relaysConnected = true
        fixture.service.flushQueuedUplinks()
        #expect(fixture.published.contains { $0.event.id == event.id })
    }

    @Test func depositRequiresGatewayToggle() throws {
        let fixture = Fixture(enabled: true)
        fixture.gatewayOn = false
        fixture.service.refreshRendezvous()

        fixture.service.handleMeshCarrier(
            try carrier(makeRemoteEvent(), direction: .toBridge),
            from: PeerID(str: "aabbccdd00112233"),
            directedToUs: true
        )

        #expect(fixture.publishedMessages.isEmpty)
        #expect(fixture.service.queuedUplinks.isEmpty)
    }

    @Test func depositRateLimitBoundsPerDepositor() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let depositor = PeerID(str: "aabbccdd00112233")

        for _ in 0..<(BridgeService.Limits.uplinkEventsPerMinutePerDepositor + 4) {
            fixture.service.handleMeshCarrier(
                try carrier(makeRemoteEvent(), direction: .toBridge),
                from: depositor,
                directedToUs: true
            )
        }

        #expect(fixture.publishedMessages.count == BridgeService.Limits.uplinkEventsPerMinutePerDepositor)
    }

    @Test func depositedEventIsNeverDownlinkedBack() throws {
        // Loop rule 2: our own relay subscription redelivering an event we
        // uplinked must not burn airtime broadcasting it back.
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let event = try makeRemoteEvent()

        fixture.service.handleMeshCarrier(
            try carrier(event, direction: .toBridge),
            from: PeerID(str: "aabbccdd00112233"),
            directedToUs: true
        )
        fixture.service.handleRendezvousEvent(event)

        #expect(fixture.broadcasts.isEmpty)
    }
}
