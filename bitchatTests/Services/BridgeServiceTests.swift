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
    nonisolated private static let cell = "u4pruy"

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
        var sendSucceeds = true
        var locallySeenMessageIDs: Set<String> = []
        var injectedPresenceOverride: ((String) -> Bool)?
        var nickname = "tester"

        private(set) var published: [(event: NostrEvent, cell: String)] = []

        /// Published chat messages only — the fixture's own presence
        /// heartbeats (kind 20001, sent on enable) are filtered out.
        var publishedMessages: [(event: NostrEvent, cell: String)] {
            published.filter { $0.event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue }
        }
        private(set) var broadcasts: [Data] = []
        private(set) var injected: [BridgeService.InboundBridgeMessage] = []
        private(set) var removedInjectedMessageIDs: [String] = []
        private(set) var uplinkSends: [(payload: Data, peer: PeerID)] = []
        private(set) var openedSubscriptions: [[String]] = []
        private(set) var closedSubscriptions = 0
        private(set) var enabledChanges: [Bool] = []
        private(set) var locationFixRequests = 0
        private(set) var cellChanges: [String?] = []
        private(set) var scheduledTimers: [(delay: TimeInterval, work: @MainActor () -> Void)] = []

        private let clock = ClockBox()
        let identity: NostrIdentity
        let defaults: UserDefaults
        let service: BridgeService

        init(
            enabled: Bool = true,
            verifyEventSignature: @escaping (NostrEvent) -> Bool = { $0.isValidSignature() }
        ) {
            let suite = "BridgeServiceTests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            identity = try! NostrIdentity.generate()
            let clock = clock
            service = BridgeService(
                defaults: defaults,
                now: { clock.now },
                verifyEventSignature: verifyEventSignature
            )
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
            service.requestLocationFix = { [weak self] in self?.locationFixRequests += 1 }
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
            service.removeInjectedInbound = { [weak self] messageID in
                self?.removedInjectedMessageIDs.append(messageID)
            }
            service.isInjectedInboundPresent = { [weak self] messageID in
                guard let self else { return false }
                return self.injectedPresenceOverride?(messageID)
                    ?? self.injected.contains { $0.messageID == messageID }
            }
            service.isMessageSeenLocally = { [weak self] id in
                self?.locallySeenMessageIDs.contains(id) ?? false
            }
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

    nonisolated private static let remoteMeshSenderID = "feedfacecafef00d"
    nonisolated private static let remoteMeshTimestampMs: UInt64 = 1_750_000_000_000

    private func makeRemoteEvent(
        cell: String = BridgeServiceTests.cell,
        content: String = "hi \(UUID().uuidString.prefix(8))",
        meshSenderID: String = BridgeServiceTests.remoteMeshSenderID,
        meshTimestampMs: UInt64 = BridgeServiceTests.remoteMeshTimestampMs,
        identity: NostrIdentity? = nil
    ) throws -> NostrEvent {
        try NostrProtocol.createBridgeMeshEvent(
            content: content,
            cell: cell,
            senderIdentity: identity ?? NostrIdentity.generate(),
            nickname: "remote",
            meshSenderID: meshSenderID,
            meshTimestampMs: meshTimestampMs
        )
    }

    /// The dedup key receivers derive for an event built by `makeRemoteEvent`.
    private func stableID(
        content: String,
        meshSenderID: String = BridgeServiceTests.remoteMeshSenderID,
        meshTimestampMs: UInt64 = BridgeServiceTests.remoteMeshTimestampMs
    ) -> String {
        MeshMessageIdentity.stableID(senderIDHex: meshSenderID, timestampMs: meshTimestampMs, content: content)
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

    @Test func missingCellRequestsALocationFix() {
        // Field bug: the bridge waited passively for availableChannels,
        // which only flow while some other feature pumps location. Bridging
        // without a cell must ask for a fix itself.
        let fixture = Fixture(enabled: true)
        fixture.locationCell = nil
        fixture.service.refreshRendezvous()

        #expect(fixture.locationFixRequests >= 1)
        #expect(fixture.service.activeCell == nil)

        // The fix lands, channels flow, and the sink re-enters here:
        fixture.locationCell = Self.cell
        fixture.service.refreshRendezvous()
        #expect(fixture.service.activeCell == Self.cell)
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

    @Test func outgoingPublishesSignedRendezvousEventWithOriginCoordinates() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let sender = PeerID(str: "0011223344556677")
        let timestamp = Date()

        fixture.service.bridgeOutgoing(content: "hello hill", senderPeerID: sender, timestamp: timestamp)

        let published = try #require(fixture.published.last)
        #expect(published.cell == Self.cell)
        #expect(published.event.isValidSignature())
        #expect(published.event.content == "hello hill")
        #expect(published.event.tags.contains(["r", Self.cell]))
        let timestampMs = MeshMessageIdentity.millisecondTimestamp(timestamp)
        #expect(published.event.tags.contains([
            "m",
            MeshMessageIdentity.stableID(senderIDHex: sender.id, timestampMs: timestampMs, content: "hello hill"),
            sender.id,
            String(timestampMs)
        ]))
        #expect(published.event.tags.contains(["n", "tester"]))
    }

    @Test func newMeshTagStaysPerMessageUniqueForOldParsers() throws {
        // v1.7.0 parsers take m[1] unconditionally as the dedup key whenever
        // the tag has >= 2 elements. A constant m[1] (e.g. the bare sender
        // ID) would make old receivers inject-dedup away every message from
        // a sender after their first — so element 1 must be the
        // per-message-unique stable ID itself.
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let sender = PeerID(str: "0011223344556677")
        let timestamp = Date()

        fixture.service.bridgeOutgoing(content: "first", senderPeerID: sender, timestamp: timestamp)
        fixture.service.bridgeOutgoing(content: "second", senderPeerID: sender, timestamp: timestamp)

        // Old-parser extraction: m[1] of the first `m` tag with >= 2 elements.
        let oldParserKeys = fixture.publishedMessages.compactMap {
            $0.event.tags.first(where: { $0.count >= 2 && $0[0] == "m" })?[1]
        }
        #expect(oldParserKeys.count == 2)
        #expect(oldParserKeys[0] != oldParserKeys[1])
        // And old and new receivers key the same message identically: m[1]
        // equals the ID the new parser recomputes from elements 2-3.
        let timestampMs = MeshMessageIdentity.millisecondTimestamp(timestamp)
        #expect(oldParserKeys == [
            MeshMessageIdentity.stableID(senderIDHex: sender.id, timestampMs: timestampMs, content: "first"),
            MeshMessageIdentity.stableID(senderIDHex: sender.id, timestampMs: timestampMs, content: "second")
        ])
    }

    @Test func nearbyOnlySuppressesTheBridgedCopy() {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        fixture.service.nearbyOnly = true

        fixture.service.bridgeOutgoing(content: "just us", senderPeerID: PeerID(str: "0011223344556677"), timestamp: Date())

        #expect(fixture.publishedMessages.isEmpty)
        #expect(fixture.uplinkSends.isEmpty)
    }

    @Test func outgoingWithoutRelaysDepositsWithBridgePeer() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        fixture.relaysConnected = false
        fixture.bridgePeers = [PeerID(str: "abcdef0123456789")]

        fixture.service.bridgeOutgoing(content: "no internet here", senderPeerID: PeerID(str: "0011223344556677"), timestamp: Date())

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
            meshSenderID: "0011223344556677",
            meshTimestampMs: Self.remoteMeshTimestampMs
        )

        fixture.service.handleRendezvousEvent(ownOldEvent)

        #expect(fixture.injected.isEmpty)
        #expect(fixture.broadcasts.isEmpty)
        #expect(fixture.service.bridgedPeerCount == 0)
    }

    @Test func ownEventComingBackFromSubscriptionIsIgnored() {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        fixture.service.bridgeOutgoing(content: "echo me", senderPeerID: PeerID(str: "0011223344556677"), timestamp: Date())
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
        #expect(fixture.injected.first?.messageID == event.id)
        #expect(fixture.injected.first?.senderNickname == "remote#\(event.pubkey.suffix(4))")
        #expect(fixture.service.bridgedPeerCount == 1)
        // Serving duty: after the jitter holdoff, the remote event rides out
        // as a fromBridge broadcast — one switch, no gateway toggle.
        #expect(fixture.broadcasts.isEmpty)
        fixture.fireScheduledTimers()
        let broadcast = try #require(fixture.broadcasts.first)
        let carrier = try #require(NostrCarrierPacket.decode(broadcast))
        #expect(carrier.direction == .fromBridge)
    }

    @Test func jitterHoldoffSuppressesAlreadyBroadcastEvents() throws {
        // Two gateways, one island: while our drain waits out the jitter,
        // the other gateway's fromBridge broadcast arrives — ours must yield.
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let event = try makeRemoteEvent()

        fixture.service.handleRendezvousEvent(event) // queued behind jitter
        fixture.service.handleMeshCarrier(
            try carrier(event, direction: .fromBridge),
            from: PeerID(str: "aabbccdd00112233"),
            directedToUs: false
        )
        fixture.fireScheduledTimers()

        #expect(fixture.broadcasts.isEmpty)
        #expect(fixture.injected.count == 1) // rendered once, either path
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
        let content = "heard on the radio"
        // The radio copy's timeline row keys on the same derived stable ID.
        fixture.locallySeenMessageIDs = [stableID(content: content)]
        let event = try makeRemoteEvent(content: content)

        fixture.service.handleRendezvousEvent(event)

        // The island already heard this over radio: no duplicate render or
        // wasted airtime. The public hint cannot attribute the Nostr signer,
        // so it does not mutate participant state either.
        #expect(fixture.injected.isEmpty)
        #expect(fixture.broadcasts.isEmpty)
        #expect(fixture.service.bridgedPeerCount == 0)
    }

    @Test func bridgeFirstThenAuthenticatedRadioReplacesAliasesAndCancelsDownlink() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let content = "bridge arrived first"
        let radioMessageID = stableID(content: content)
        let event = try makeRemoteEvent(content: content)

        fixture.service.handleRendezvousEvent(event)
        #expect(fixture.injected.map(\.messageID) == [event.id])
        #expect(fixture.service.bridgedPeerCount == 1)

        // This entry point is called only after the BLE packet signature has
        // authenticated. The radio row must win; the public m-tag hint is not
        // trusted enough to suppress it.
        fixture.service.handleAuthenticatedRadioMessage(messageID: radioMessageID)
        fixture.fireScheduledTimers()

        #expect(fixture.removedInjectedMessageIDs == [event.id])
        #expect(fixture.broadcasts.isEmpty)
        #expect(fixture.service.bridgedPeerCount == 1)

        // A different signer copying the same public mesh coordinates after
        // radio authentication cannot put a bridge alias back into the row.
        fixture.service.handleRendezvousEvent(try makeRemoteEvent(content: content))
        #expect(fixture.injected.count == 1)
    }

    @Test func disablingBridgeDoesNotForgetAliasNeededByLaterRadioCopy() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let content = "radio arrives after opt-out"
        let event = try makeRemoteEvent(content: content)

        fixture.service.handleRendezvousEvent(event)
        fixture.service.setEnabled(false)
        fixture.service.handleAuthenticatedRadioMessage(messageID: stableID(content: content))

        #expect(fixture.removedInjectedMessageIDs == [event.id])
    }

    @Test func aliasPruningUsesExactRowLivenessWithoutDeletingHistory() throws {
        let fixture = Fixture(enabled: true, verifyEventSignature: { _ in true })
        fixture.service.refreshRendezvous()

        func event(index: Int) -> NostrEvent {
            let senderID = String(format: "%016llx", UInt64(index + 1))
            let content = "bridge overflow \(index)"
            let timestampMs = UInt64(1_750_000_000_000) + UInt64(index)
            var event = NostrEvent(
                pubkey: String(format: "%064llx", UInt64(index + 1)),
                createdAt: Date(),
                kind: .ephemeralEvent,
                tags: [
                    ["r", Self.cell],
                    ["n", "remote"],
                    ["m", "unused", senderID, String(timestampMs)]
                ],
                content: content
            )
            event.id = String(format: "%064llx", UInt64(index + 10_000))
            event.sig = String(repeating: "0", count: 128)
            return event
        }

        let oldest = event(index: 0)
        fixture.service.handleRendezvousEvent(oldest)
        for index in 1...BridgeService.Limits.maxTrackedEventIDs {
            if index.isMultiple(of: 500) { fixture.advance(61) }
            fixture.service.handleRendezvousEvent(event(index: index))
        }

        // The loop/dedup caches are intentionally smaller, but valid ingress
        // through that boundary must not delete a still-visible bridge row.
        #expect(fixture.removedInjectedMessageIDs.isEmpty)

        for index in (BridgeService.Limits.maxTrackedEventIDs + 1)..<BridgeService.Limits.maxTrackedRadioAliases {
            if index.isMultiple(of: 500) { fixture.advance(61) }
            fixture.service.handleRendezvousEvent(event(index: index))
        }

        // Timestamp-order trimming need not match arrival order. Model the
        // store having evicted a middle-arrival row, then exceed alias capacity.
        let noLongerVisibleID = event(index: 700).id
        fixture.injectedPresenceOverride = { $0 != noLongerVisibleID }
        fixture.service.handleRendezvousEvent(event(index: BridgeService.Limits.maxTrackedRadioAliases))

        // Pruning discarded only proof for a row already absent. It never
        // invokes active row deletion, and the still-visible oldest row keeps
        // its radio-replacement proof despite out-of-order timestamps.
        #expect(fixture.removedInjectedMessageIDs.isEmpty)
        fixture.service.handleAuthenticatedRadioMessage(
            messageID: stableID(
                content: oldest.content,
                meshSenderID: "0000000000000001",
                meshTimestampMs: 1_750_000_000_000
            )
        )
        #expect(fixture.removedInjectedMessageIDs == [oldest.id])
    }

    @Test func copiedRadioHintCannotMakeSignerStickyLocal() throws {
        // A remote signer can copy public radio coordinates and content. That
        // suppresses only the duplicate row; it cannot mark the signing key as
        // local and hide the signer's later bridge traffic from the people UI.
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let identity = try NostrIdentity.generate()
        let content = "island echo"
        fixture.locallySeenMessageIDs = [stableID(content: content)]

        fixture.service.handleRendezvousEvent(try makeRemoteEvent(content: content, identity: identity))
        #expect(fixture.service.bridgedPeerCount == 0)

        fixture.service.handleRendezvousEvent(try makeRemoteEvent(
            content: "not on the radio yet",
            meshTimestampMs: Self.remoteMeshTimestampMs + 1,
            identity: identity
        ))
        #expect(fixture.service.bridgedPeerCount == 1)
    }

    @Test func spoofedOriginCoordinatesCannotSuppressTheGenuineMessage() throws {
        // Attack: copy the victim's exact content + mesh sender + timestamp,
        // then sign under another Nostr key and arrive first. Public mesh
        // coordinates are only a radio-copy hint; signed event IDs own bridge
        // dedup, so the attacker cannot reserve the genuine event's slot.
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let spoof = try makeRemoteEvent(content: "the exact victim message")
        let genuine = try makeRemoteEvent(content: "the exact victim message")

        fixture.service.handleRendezvousEvent(spoof)
        fixture.service.handleRendezvousEvent(genuine)

        #expect(fixture.injected.count == 2)
        #expect(fixture.injected.map(\.messageID) == [spoof.id, genuine.id])
        #expect(fixture.injected.map(\.senderNickname) == [
            "remote#\(spoof.pubkey.suffix(4))",
            "remote#\(genuine.pubkey.suffix(4))"
        ])
    }

    @Test func forgedStableIDElementIsNeverTrusted() throws {
        // Element 1 of the `m` tag exists only for old parsers. An event
        // claiming the genuine message's stable ID there — over different
        // content — must still key on its signed event ID, so it cannot
        // pre-poison the genuine message's dedup slot.
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let genuineID = stableID(content: "the real message")
        let identity = try NostrIdentity.generate()
        let forged = try NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: Date(),
            kind: .ephemeralEvent,
            tags: [
                ["r", Self.cell],
                ["m", genuineID, Self.remoteMeshSenderID, String(Self.remoteMeshTimestampMs)]
            ],
            content: "impostor payload"
        ).sign(with: identity.schnorrSigningKey())
        let genuine = try makeRemoteEvent(content: "the real message")

        fixture.service.handleRendezvousEvent(forged)
        fixture.service.handleRendezvousEvent(genuine)

        #expect(fixture.injected.map(\.messageID) == [forged.id, genuine.id])
    }

    @Test func oldFormatMeshTagAlsoUsesAuthenticatedEventID() throws {
        // A 2-element `m` tag from an old sender is just as unauthenticated as
        // the current coordinates; the signed event ID remains authoritative.
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let identity = try NostrIdentity.generate()
        let legacy = try NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: Date(),
            kind: .ephemeralEvent,
            tags: [["r", Self.cell], ["m", UUID().uuidString]],
            content: "legacy copy"
        ).sign(with: identity.schnorrSigningKey())

        fixture.service.handleRendezvousEvent(legacy)

        #expect(fixture.injected.map(\.messageID) == [legacy.id])
    }

    @Test func duplicateSubscriptionEventInjectsOnce() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let event = try makeRemoteEvent()

        fixture.service.handleRendezvousEvent(event)
        fixture.service.handleRendezvousEvent(event)
        fixture.fireScheduledTimers()

        #expect(fixture.injected.count == 1)
        #expect(fixture.broadcasts.count == 1)
    }

    @Test func presenceCountsParticipantWithoutInjection() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()

        fixture.service.handleRendezvousEvent(try makePresenceEvent())

        #expect(fixture.injected.isEmpty)
        #expect(fixture.service.bridgedPeerCount == 1)
    }

    @Test func participantStateIsCappedUnderRotatingKeyFlood() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()

        for _ in 0..<(BridgeService.Limits.maxParticipants + 20) {
            fixture.service.handleRendezvousEvent(try makePresenceEvent())
        }

        #expect(fixture.service.bridgedPeerCount == BridgeService.Limits.maxParticipants)
        #expect(fixture.service.bridgedParticipants.count == BridgeService.Limits.maxParticipants)
    }

    @Test func relayIngressRateLimitsOneSigningKey() throws {
        let fixture = Fixture(enabled: true)
        fixture.service.refreshRendezvous()
        let identity = try NostrIdentity.generate()

        for index in 0..<(BridgeService.Limits.inboundEventsPerMinutePerSigner + 10) {
            fixture.service.handleRendezvousEvent(try makeRemoteEvent(
                content: "rate \(index)",
                meshTimestampMs: Self.remoteMeshTimestampMs + UInt64(index),
                identity: identity
            ))
        }

        #expect(fixture.injected.count == BridgeService.Limits.inboundEventsPerMinutePerSigner)
    }

    @Test func invalidIngressCannotTriggerUnboundedSignatureVerification() throws {
        var verificationCount = 0
        let fixture = Fixture(enabled: true) { _ in
            verificationCount += 1
            return false
        }
        fixture.service.refreshRendezvous()
        let event = try makeRemoteEvent()

        for _ in 0..<(BridgeService.Limits.signatureVerificationAttemptsPerMinute + 20) {
            fixture.service.handleRendezvousEvent(event)
        }

        #expect(verificationCount == BridgeService.Limits.signatureVerificationAttemptsPerMinute)
        fixture.advance(61)
        fixture.service.handleRendezvousEvent(event)
        #expect(verificationCount == BridgeService.Limits.signatureVerificationAttemptsPerMinute + 1)
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
        fixture.fireScheduledTimers() // jitter holdoff elapses

        #expect(fixture.broadcasts.count == BridgeService.Limits.downlinkEventsPerMinute)
        // Window frees: the re-armed timer drains the backlog.
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
        fixture.fireScheduledTimers()

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
            "sig": event.sig ?? ""
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

    @Test func depositRequiresBridgeToggle() throws {
        let fixture = Fixture(enabled: false)

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
        fixture.fireScheduledTimers()

        #expect(fixture.broadcasts.isEmpty)
    }
}
