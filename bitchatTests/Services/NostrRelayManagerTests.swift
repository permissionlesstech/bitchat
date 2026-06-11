import Combine
import XCTest
@testable import bitchat

@MainActor
final class NostrRelayManagerTests: XCTestCase {
    private let expectedDefaultRelayCount = 4

    func test_connect_directMode_connectsExistingDefaultRelaysWhenActivationBecomesAllowed() async {
        let context = makeContext(permission: .authorized, activationAllowed: false)

        XCTAssertTrue(context.sessionFactory.requestedURLs.isEmpty)
        context.activationAllowed.value = true

        context.manager.connect()

        let connected = await waitUntil {
            context.sessionFactory.requestedURLs.count == self.expectedDefaultRelayCount &&
            context.manager.relays.allSatisfy(\.isConnected)
        }
        XCTAssertTrue(connected)
    }

    func test_permissionPublisher_addsAndRemovesDefaultRelays() async {
        let context = makeContext(permission: .denied, favorites: [])

        XCTAssertEqual(context.manager.getRelayStatuses().count, 0)

        context.permissionSubject.send(.authorized)

        let defaultRelaysConnected = await waitUntil {
            context.manager.getRelayStatuses().count == self.expectedDefaultRelayCount &&
            context.manager.relays.allSatisfy(\.isConnected)
        }
        XCTAssertTrue(defaultRelaysConnected)

        context.permissionSubject.send(.denied)

        let defaultRelaysRemoved = await waitUntil {
            context.manager.getRelayStatuses().isEmpty
        }
        XCTAssertTrue(defaultRelaysRemoved)
        XCTAssertEqual(context.sessionFactory.allConnections.count, expectedDefaultRelayCount)
        XCTAssertTrue(context.sessionFactory.allConnections.allSatisfy { $0.cancelCallCount >= 1 })
    }

    func test_connect_waitsForTorReadinessBeforeCreatingSessions() async {
        let context = makeContext(permission: .authorized, userTorEnabled: true, torEnforced: true, torIsReady: false)

        context.manager.connect()

        XCTAssertTrue(context.sessionFactory.requestedURLs.isEmpty)

        context.torWaiter.resolve(true)

        let connectedAfterTorReady = await waitUntil {
            context.sessionFactory.requestedURLs.count == self.expectedDefaultRelayCount &&
            context.manager.relays.allSatisfy(\.isConnected)
        }
        XCTAssertTrue(connectedAfterTorReady)
    }

    func test_connect_coalescesRepeatedCallsWhileWaitingForTor() async {
        let context = makeContext(permission: .authorized, userTorEnabled: true, torEnforced: true, torIsReady: false)

        context.manager.connect()
        context.manager.connect()
        context.manager.connect()

        XCTAssertEqual(context.torWaiter.awaitCallCount, 1)
        XCTAssertTrue(context.sessionFactory.requestedURLs.isEmpty)

        context.torWaiter.resolve(true)

        let connectedAfterTorReady = await waitUntil {
            context.sessionFactory.requestedURLs.count == self.expectedDefaultRelayCount &&
            context.manager.relays.allSatisfy(\.isConnected)
        }
        XCTAssertTrue(connectedAfterTorReady)
    }

    func test_connect_whenTorReadinessFailsDoesNotCreateSessions() async {
        let context = makeContext(permission: .authorized, userTorEnabled: true, torEnforced: true, torIsReady: false)

        context.manager.connect()
        context.torWaiter.resolve(false)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(context.sessionFactory.requestedURLs.isEmpty)
        XCTAssertFalse(context.manager.isConnected)
    }

    func test_connect_retriesTorWaitAndConnectsWhenTorBecomesReady() async {
        let context = makeContext(permission: .authorized, userTorEnabled: true, torEnforced: true, torIsReady: false)

        context.manager.connect()
        XCTAssertEqual(context.torWaiter.awaitCallCount, 1)

        context.torWaiter.resolve(false)

        // A failed wait re-queues the same targets and waits again instead of dropping them.
        XCTAssertEqual(context.torWaiter.awaitCallCount, 2)
        XCTAssertTrue(context.sessionFactory.requestedURLs.isEmpty)

        context.torWaiter.resolve(true)

        let connected = await waitUntil {
            context.sessionFactory.requestedURLs.count == self.expectedDefaultRelayCount &&
            context.manager.relays.allSatisfy(\.isConnected)
        }
        XCTAssertTrue(connected)
    }

    func test_subscribe_unblocksDeferredEOSEWhenTorWaitAttemptsExhausted() async {
        let relayURL = "wss://tor-eose-unblock.example"
        let context = makeContext(permission: .denied, userTorEnabled: true, torEnforced: true, torIsReady: false)
        var eoseCount = 0

        context.manager.subscribe(
            filter: makeFilter(),
            id: "tor-sub-unblock",
            relayUrls: [relayURL],
            handler: { _ in },
            onEOSE: { eoseCount += 1 }
        )

        for _ in 0..<TransportConfig.nostrTorReadyMaxWaitAttempts {
            context.torWaiter.resolve(false)
        }

        // Fail-closed (no sessions), but the EOSE caller is unblocked.
        XCTAssertEqual(eoseCount, 1)
        XCTAssertTrue(context.sessionFactory.requestedURLs.isEmpty)
    }

    func test_sendEvent_survivesFailedTorWaitAndSendsWhenTorRecovers() async throws {
        let relayURL = "wss://tor-send-retry.example"
        let context = makeContext(permission: .denied, userTorEnabled: true, torEnforced: true, torIsReady: false)
        let event = try makeSignedEvent(content: "queued through tor stall")

        context.manager.sendEvent(event, to: [relayURL])

        XCTAssertEqual(context.manager.debugPendingMessageQueueCount, 1)
        XCTAssertTrue(context.sessionFactory.requestedURLs.isEmpty)

        context.torWaiter.resolve(false)
        XCTAssertEqual(context.manager.debugPendingMessageQueueCount, 1)

        context.torWaiter.resolve(true)

        let sent = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count == 1 &&
            context.manager.debugPendingMessageQueueCount == 0
        }
        XCTAssertTrue(sent)
    }

    func test_sendEvent_pendingQueueDropsOldestBeyondCap() async throws {
        let relayURL = "wss://tor-send-cap.example"
        let context = makeContext(permission: .denied, userTorEnabled: true, torEnforced: true, torIsReady: false)
        let identity = try NostrIdentity.generate()

        for i in 0...(TransportConfig.nostrPendingSendQueueCap + 4) {
            let event = NostrEvent(
                pubkey: identity.publicKeyHex,
                createdAt: Date(),
                kind: .textNote,
                tags: [],
                content: "cap-\(i)"
            )
            context.manager.sendEvent(try event.sign(with: identity.schnorrSigningKey()), to: [relayURL])
        }

        XCTAssertEqual(context.manager.debugPendingMessageQueueCount, TransportConfig.nostrPendingSendQueueCap)
    }

    func test_sendEvent_waitsForTorReadinessBeforeSending() async throws {
        let relayURL = "wss://tor-ready.example"
        let context = makeContext(permission: .denied, userTorEnabled: true, torEnforced: true, torIsReady: false)
        let event = try makeSignedEvent(content: "deferred")

        context.manager.sendEvent(event, to: [relayURL])

        XCTAssertTrue(context.sessionFactory.requestedURLs.isEmpty)

        context.torWaiter.resolve(true)

        let sentAfterTorReady = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count == 1 &&
            context.manager.relays.first(where: { $0.url == relayURL })?.messagesSent == 1
        }
        XCTAssertTrue(sentAfterTorReady)
    }

    func test_sendEvent_queuesUntilRelayIsMarkedConnected() async throws {
        let relayURL = "wss://connect-before-send.example"
        let context = makeContext(permission: .denied)
        let event = try makeSignedEvent(content: "wait for connected")

        context.manager.sendEvent(event, to: [relayURL])

        XCTAssertEqual(context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count, 0)
        XCTAssertEqual(context.manager.debugPendingMessageQueueCount, 1)

        let sentAfterConnected = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count == 1 &&
            context.manager.debugPendingMessageQueueCount == 0 &&
            context.manager.relays.first(where: { $0.url == relayURL })?.messagesSent == 1
        }
        XCTAssertTrue(sentAfterConnected)
    }

    func test_sendEvent_queuesWhileBackgroundedAndFlushesWhenForegrounded() async throws {
        let relayURL = "wss://queue-flush.example"
        let context = makeContext(
            permission: .denied,
            userTorEnabled: true,
            torEnforced: true,
            torIsReady: true,
            torIsForeground: false
        )
        let event = try makeSignedEvent(content: "queued")

        context.manager.sendEvent(event, to: [relayURL])
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(context.sessionFactory.requestedURLs.isEmpty)
        context.torForeground.value = true
        context.manager.ensureConnections(to: [relayURL])

        let flushed = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count == 1 &&
            context.manager.relays.first(where: { $0.url == relayURL })?.messagesSent == 1
        }
        XCTAssertTrue(flushed)
    }

    func test_sendEvent_sendFailureDoesNotIncrementMessageCount() async throws {
        let relayURL = "wss://send-failure.example"
        let context = makeContext(permission: .denied)
        context.sessionFactory.sendErrorByURL[relayURL] = NSError(domain: "send", code: 1)
        let event = try makeSignedEvent(content: "send failure")

        context.manager.sendEvent(event, to: [relayURL])

        let attempted = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count == 1
        }
        XCTAssertTrue(attempted)

        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(context.manager.relays.first(where: { $0.url == relayURL })?.messagesSent, 0)
    }

    func test_sendEvent_queueIsPrunedWhenDefaultRelaysAreRevoked() async throws {
        let context = makeContext(
            permission: .authorized,
            userTorEnabled: true,
            torEnforced: true,
            torIsReady: true,
            torIsForeground: false
        )
        let event = try makeSignedEvent(content: "queued default")

        context.manager.sendEvent(event)

        let queued = await waitUntil {
            context.manager.debugPendingMessageQueueCount == 1
        }
        XCTAssertTrue(queued)

        context.permissionSubject.send(.denied)

        let cleared = await waitUntil {
            context.manager.debugPendingMessageQueueCount == 0 &&
            context.manager.relays.isEmpty
        }
        XCTAssertTrue(cleared)
    }

    func test_connect_doesNothingWhenActivationIsDisallowed() {
        let context = makeContext(permission: .authorized, activationAllowed: false)

        context.manager.connect()

        XCTAssertTrue(context.sessionFactory.requestedURLs.isEmpty)
        XCTAssertFalse(context.manager.isConnected)
    }

    func test_ensureConnections_deduplicatesRelayURLs() async {
        let relayOne = "wss://relay-one.example"
        let relayTwo = "wss://relay-two.example"
        let context = makeContext(permission: .denied)

        context.manager.ensureConnections(to: [relayOne, "wss://relay-one.example:443/", "WSS://RELAY-TWO.EXAMPLE:443"])

        let connected = await waitUntil {
            Set(context.manager.getRelayStatuses().map(\.url)) == Set([relayOne, relayTwo]) &&
            context.manager.relays.allSatisfy(\.isConnected)
        }
        XCTAssertTrue(connected)
        XCTAssertEqual(context.sessionFactory.requestedURLs, [relayOne, relayTwo])
    }

    func test_ensureConnections_coalescesTargetsWhileWaitingForTor() async {
        let relayOne = "wss://tor-one.example"
        let relayTwo = "wss://tor-two.example"
        let context = makeContext(permission: .denied, userTorEnabled: true, torEnforced: true, torIsReady: false)

        context.manager.ensureConnections(to: [relayOne])
        context.manager.ensureConnections(to: [relayTwo, relayOne])

        XCTAssertEqual(context.torWaiter.awaitCallCount, 1)
        XCTAssertTrue(context.sessionFactory.requestedURLs.isEmpty)

        context.torWaiter.resolve(true)

        let connected = await waitUntil {
            Set(context.sessionFactory.requestedURLs) == Set([relayOne, relayTwo]) &&
            context.manager.relays.allSatisfy(\.isConnected)
        }
        XCTAssertTrue(connected)
    }

    func test_subscribe_coalescesRapidDuplicateRequests() async {
        let relayURL = "wss://subscribe.example"
        let context = makeContext(permission: .denied)
        let filter = makeFilter()

        context.manager.subscribe(filter: filter, id: "sub", relayUrls: [relayURL], handler: { _ in })

        let firstSent = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count == 1
        }
        XCTAssertTrue(firstSent)

        context.clock.now = context.clock.now.addingTimeInterval(0.5)
        context.manager.subscribe(filter: filter, id: "sub", relayUrls: [relayURL], handler: { _ in })

        XCTAssertEqual(context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count, 1)
    }

    func test_subscribe_coalescesDuplicateRequestsBeforeTorReadyAndDefersEOSE() async throws {
        let relayURL = "wss://tor-subscribe-coalesce.example"
        let context = makeContext(permission: .denied, userTorEnabled: true, torEnforced: true, torIsReady: false)
        var eoseCount = 0

        context.manager.subscribe(
            filter: makeFilter(),
            id: "tor-sub",
            relayUrls: [relayURL],
            handler: { _ in },
            onEOSE: { eoseCount += 1 }
        )
        context.manager.subscribe(
            filter: makeFilter(),
            id: "tor-sub",
            relayUrls: [relayURL],
            handler: { _ in },
            onEOSE: { eoseCount += 1 }
        )

        XCTAssertEqual(context.torWaiter.awaitCallCount, 1)
        XCTAssertEqual(context.manager.debugPendingSubscriptionCount(for: relayURL), 1)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(eoseCount, 0)

        context.torWaiter.resolve(true)

        let subscribed = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count == 1
        }
        XCTAssertTrue(subscribed)

        try context.sessionFactory.latestConnection(for: relayURL)?.emitEOSE(subscriptionID: "tor-sub")
        let eoseCompleted = await waitUntil { eoseCount == 1 }
        XCTAssertTrue(eoseCompleted)
    }

    func test_subscribe_sameActiveRequestDoesNotRequeue() async {
        let relayURL = "wss://active-subscribe.example"
        let context = makeContext(permission: .denied)
        let filter = makeFilter()

        context.manager.subscribe(filter: filter, id: "sub", relayUrls: [relayURL], handler: { _ in })

        let firstSent = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count == 1
        }
        XCTAssertTrue(firstSent)

        context.clock.now = context.clock.now.addingTimeInterval(2.0)
        context.manager.subscribe(filter: filter, id: "sub", relayUrls: [relayURL], handler: { _ in })
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count, 1)
        XCTAssertEqual(context.manager.debugPendingSubscriptionCount(for: relayURL), 0)
    }

    func test_subscribe_waitsForTorReadinessAndPreservesEOSECallback() async throws {
        let relayURL = "wss://tor-subscribe.example"
        let context = makeContext(permission: .denied, userTorEnabled: true, torEnforced: true, torIsReady: false)
        var eoseCount = 0

        context.manager.subscribe(
            filter: makeFilter(),
            id: "tor-eose",
            relayUrls: [relayURL],
            handler: { _ in },
            onEOSE: { eoseCount += 1 }
        )

        XCTAssertTrue(context.sessionFactory.requestedURLs.isEmpty)

        context.torWaiter.resolve(true)
        let subscribed = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count == 1
        }
        XCTAssertTrue(subscribed)

        try context.sessionFactory.latestConnection(for: relayURL)?.emitEOSE(subscriptionID: "tor-eose")
        let eoseCompleted = await waitUntil { eoseCount == 1 }
        XCTAssertTrue(eoseCompleted)
    }

    func test_subscribe_withoutAllowedRelays_callsEOSEImmediatelyAndDoesNotFlushLater() async {
        let context = makeContext(permission: .denied)
        var eoseCount = 0

        context.manager.subscribe(
            filter: makeFilter(),
            id: "blocked-defaults",
            handler: { _ in },
            onEOSE: { eoseCount += 1 }
        )

        XCTAssertEqual(eoseCount, 1)
        XCTAssertTrue(context.sessionFactory.requestedURLs.isEmpty)

        context.permissionSubject.send(.authorized)
        let connected = await waitUntil {
            context.sessionFactory.allConnections.count == self.expectedDefaultRelayCount &&
            context.manager.relays.allSatisfy(\.isConnected)
        }
        XCTAssertTrue(connected)
        XCTAssertTrue(context.sessionFactory.allConnections.allSatisfy { $0.sentStrings.isEmpty })
    }

    func test_permissionRevocation_clearsQueuedDefaultSubscriptions() async {
        let context = makeContext(
            permission: .authorized,
            userTorEnabled: true,
            torEnforced: true,
            torIsReady: true,
            torIsForeground: false
        )
        let defaultRelay = "wss://relay.damus.io"

        context.manager.subscribe(filter: makeFilter(), id: "queued-default", handler: { _ in })

        let queued = await waitUntil {
            context.manager.debugPendingSubscriptionCount(for: defaultRelay) == 1
        }
        XCTAssertTrue(queued)

        context.permissionSubject.send(.denied)

        let cleared = await waitUntil {
            context.manager.debugPendingSubscriptionCount(for: defaultRelay) == 0 &&
            context.manager.relays.isEmpty
        }
        XCTAssertTrue(cleared)
    }

    func test_unsubscribe_allowsResubscribeWithSameID() async {
        let relayURL = "wss://subscribe.example"
        let context = makeContext(permission: .denied)
        let filter = makeFilter()

        context.manager.subscribe(filter: filter, id: "sub", relayUrls: [relayURL], handler: { _ in })
        let initialSubscribeSent = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count == 1
        }
        XCTAssertTrue(initialSubscribeSent)

        context.manager.unsubscribe(id: "sub")
        let closeSent = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count == 2
        }
        XCTAssertTrue(closeSent)

        context.clock.now = context.clock.now.addingTimeInterval(0.2)
        context.manager.subscribe(filter: filter, id: "sub", relayUrls: [relayURL], handler: { _ in })

        let resubscribed = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count == 3
        }
        XCTAssertTrue(resubscribed)
    }

    func test_receiveEvent_deliversHandlerAndTracksReceivedCount() async throws {
        let relayURL = "wss://events.example"
        let context = makeContext(permission: .denied)
        let filter = makeFilter()
        let event = try makeSignedEvent(content: "hello")
        var receivedEvent: NostrEvent?

        context.manager.subscribe(filter: filter, id: "events", relayUrls: [relayURL]) { event in
            receivedEvent = event
        }
        let subscriptionSent = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count == 1
        }
        XCTAssertTrue(subscriptionSent)

        try context.sessionFactory.latestConnection(for: relayURL)?.emitEventMessage(subscriptionID: "events", event: event)

        let delivered = await waitUntil {
            receivedEvent?.id == event.id &&
            context.manager.relays.first(where: { $0.url == relayURL })?.messagesReceived == 1
        }
        XCTAssertTrue(delivered)
        XCTAssertEqual(receivedEvent?.id, event.id)
    }

    func test_receiveEvent_deduplicatesSameSubscriptionEventAcrossRelays() async throws {
        let firstRelayURL = "wss://events-one.example"
        let secondRelayURL = "wss://events-two.example"
        let context = makeContext(permission: .denied)
        let event = try makeSignedEvent(content: "duplicate")
        var receivedIDs: [String] = []

        context.manager.subscribe(
            filter: makeFilter(),
            id: "events",
            relayUrls: [firstRelayURL, secondRelayURL]
        ) { event in
            receivedIDs.append(event.id)
        }
        let subscriptionsSent = await waitUntil {
            context.sessionFactory.latestConnection(for: firstRelayURL)?.sentStrings.count == 1 &&
            context.sessionFactory.latestConnection(for: secondRelayURL)?.sentStrings.count == 1
        }
        XCTAssertTrue(subscriptionsSent)

        try context.sessionFactory.latestConnection(for: firstRelayURL)?.emitEventMessage(subscriptionID: "events", event: event)
        try context.sessionFactory.latestConnection(for: secondRelayURL)?.emitEventMessage(subscriptionID: "events", event: event)

        let countedOnBothRelays = await waitUntil {
            context.manager.relays.first(where: { $0.url == firstRelayURL })?.messagesReceived == 1 &&
            context.manager.relays.first(where: { $0.url == secondRelayURL })?.messagesReceived == 1
        }
        XCTAssertTrue(countedOnBothRelays)
        XCTAssertEqual(receivedIDs, [event.id])
        XCTAssertEqual(context.manager.debugDuplicateInboundEventDropCount, 1)
        XCTAssertEqual(context.manager.debugDuplicateInboundEventDropCount(forSubscriptionID: "events"), 1)
    }

    func test_receiveEvent_duplicateFanInDeliversOnceAndCountsDrops() async throws {
        let relayURLs = (0..<8).map { "wss://fan-in-\($0).example" }
        let context = makeContext(permission: .denied)
        let event = try makeSignedEvent(content: "fan-in")
        var receivedIDs: [String] = []

        context.manager.subscribe(
            filter: makeFilter(),
            id: "presence",
            relayUrls: relayURLs
        ) { event in
            receivedIDs.append(event.id)
        }
        let subscriptionsSent = await waitUntil {
            relayURLs.allSatisfy { relayURL in
                context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count == 1
            }
        }
        XCTAssertTrue(subscriptionsSent)

        for relayURL in relayURLs {
            try context.sessionFactory.latestConnection(for: relayURL)?.emitEventMessage(
                subscriptionID: "presence",
                event: event
            )
        }

        let countedOnEveryRelay = await waitUntil {
            relayURLs.allSatisfy { relayURL in
                context.manager.relays.first(where: { $0.url == relayURL })?.messagesReceived == 1
            }
        }
        XCTAssertTrue(countedOnEveryRelay)
        XCTAssertEqual(receivedIDs, [event.id])
        XCTAssertEqual(context.manager.debugDuplicateInboundEventDropCount, relayURLs.count - 1)
        XCTAssertEqual(
            context.manager.debugDuplicateInboundEventDropCount(forSubscriptionID: "presence"),
            relayURLs.count - 1
        )
    }

    func test_receiveEvent_invalidSignatureDoesNotPoisonDuplicateCache() async throws {
        let firstRelayURL = "wss://invalid-first-one.example"
        let secondRelayURL = "wss://invalid-first-two.example"
        let context = makeContext(permission: .denied)
        let event = try makeSignedEvent(content: "valid-after-invalid")
        let invalidEvent = invalidSignatureCopy(of: event)
        var receivedIDs: [String] = []

        context.manager.subscribe(
            filter: makeFilter(),
            id: "events",
            relayUrls: [firstRelayURL, secondRelayURL]
        ) { event in
            receivedIDs.append(event.id)
        }
        let subscriptionsSent = await waitUntil {
            context.sessionFactory.latestConnection(for: firstRelayURL)?.sentStrings.count == 1 &&
            context.sessionFactory.latestConnection(for: secondRelayURL)?.sentStrings.count == 1
        }
        XCTAssertTrue(subscriptionsSent)

        try context.sessionFactory.latestConnection(for: firstRelayURL)?.emitEventMessage(subscriptionID: "events", event: invalidEvent)
        try context.sessionFactory.latestConnection(for: secondRelayURL)?.emitEventMessage(subscriptionID: "events", event: event)

        let countedOnBothRelays = await waitUntil {
            context.manager.relays.first(where: { $0.url == firstRelayURL })?.messagesReceived == 1 &&
            context.manager.relays.first(where: { $0.url == secondRelayURL })?.messagesReceived == 1
        }
        XCTAssertTrue(countedOnBothRelays)
        XCTAssertEqual(receivedIDs, [event.id])
        XCTAssertEqual(context.manager.debugDuplicateInboundEventDropCount, 0)
        XCTAssertEqual(context.manager.debugDuplicateInboundEventDropCount(forSubscriptionID: "events"), 0)
    }

    func test_receiveEvent_withoutHandlerStillTracksReceivedCount() async throws {
        let relayURL = "wss://missing-handler.example"
        let context = makeContext(permission: .denied)
        let event = try makeSignedEvent(content: "unhandled")

        context.manager.ensureConnections(to: [relayURL])
        let connected = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL) != nil &&
            context.manager.relays.first(where: { $0.url == relayURL })?.isConnected == true
        }
        XCTAssertTrue(connected)

        try context.sessionFactory.latestConnection(for: relayURL)?.emitEventMessage(subscriptionID: "missing", event: event)

        let counted = await waitUntil {
            context.manager.relays.first(where: { $0.url == relayURL })?.messagesReceived == 1
        }
        XCTAssertTrue(counted)
    }

    func test_noticeAndMalformedMessages_keepReceiveLoopAliveForLaterEvents() async throws {
        let relayURL = "wss://parser.example"
        let context = makeContext(permission: .denied)
        var receivedIDs: [String] = []
        let firstEvent = try makeSignedEvent(content: "after notice")
        let secondEvent = try makeSignedEvent(content: "after malformed")

        context.manager.subscribe(filter: makeFilter(), id: "parser", relayUrls: [relayURL]) { event in
            receivedIDs.append(event.id)
        }
        let subscribed = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count == 1
        }
        XCTAssertTrue(subscribed)

        try context.sessionFactory.latestConnection(for: relayURL)?.emitNotice(message: "ignored")
        try? await Task.sleep(nanoseconds: 20_000_000)
        try context.sessionFactory.latestConnection(for: relayURL)?.emitEventMessage(subscriptionID: "parser", event: firstEvent)

        let firstDelivered = await waitUntil {
            receivedIDs == [firstEvent.id]
        }
        XCTAssertTrue(firstDelivered)

        try context.sessionFactory.latestConnection(for: relayURL)?.emitRawString("not-json")
        try? await Task.sleep(nanoseconds: 20_000_000)
        try context.sessionFactory.latestConnection(for: relayURL)?.emitEventMessage(subscriptionID: "parser", event: secondEvent)

        let secondDelivered = await waitUntil {
            receivedIDs == [firstEvent.id, secondEvent.id]
        }
        XCTAssertTrue(secondDelivered)
    }

    func test_okMessages_clearPendingGiftWrapIDs() async throws {
        let relayURL = "wss://ok.example"
        let context = makeContext(permission: .denied)
        let successID = "gift-wrap-success"
        let failureID = "gift-wrap-failure"

        context.manager.ensureConnections(to: [relayURL])
        let connected = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL) != nil &&
            context.manager.relays.first(where: { $0.url == relayURL })?.isConnected == true
        }
        XCTAssertTrue(connected)

        NostrRelayManager.registerPendingGiftWrap(id: successID)
        try context.sessionFactory.latestConnection(for: relayURL)?.emitOK(eventID: successID, success: true, reason: "ok")
        let successCleared = await waitUntil {
            !NostrRelayManager.pendingGiftWrapIDs.contains(successID)
        }
        XCTAssertTrue(successCleared)

        NostrRelayManager.registerPendingGiftWrap(id: failureID)
        try context.sessionFactory.latestConnection(for: relayURL)?.emitOK(eventID: failureID, success: false, reason: "rejected")
        let failureCleared = await waitUntil {
            !NostrRelayManager.pendingGiftWrapIDs.contains(failureID)
        }
        XCTAssertTrue(failureCleared)
    }

    func test_eoseCallback_waitsForAllTargetedRelays() async throws {
        let relayOne = "wss://one.example"
        let relayTwo = "wss://two.example"
        let context = makeContext(permission: .denied)
        var eoseCount = 0

        context.manager.subscribe(
            filter: makeFilter(),
            id: "eose",
            relayUrls: [relayOne, relayTwo],
            handler: { _ in },
            onEOSE: { eoseCount += 1 }
        )

        let bothConnected = await waitUntil {
            context.sessionFactory.latestConnection(for: relayOne)?.sentStrings.count == 1 &&
            context.sessionFactory.latestConnection(for: relayTwo)?.sentStrings.count == 1
        }
        XCTAssertTrue(bothConnected)

        try context.sessionFactory.latestConnection(for: relayOne)?.emitEOSE(subscriptionID: "eose")
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(eoseCount, 0)

        try context.sessionFactory.latestConnection(for: relayTwo)?.emitEOSE(subscriptionID: "eose")

        let eoseCompleted = await waitUntil { eoseCount == 1 }
        XCTAssertTrue(eoseCompleted)
    }

    func test_eoseTimeout_invokesCallbackOnceAndIgnoresLateEOSE() async throws {
        let relayURL = "wss://timeout.example"
        let context = makeContext(permission: .denied)
        var eoseCount = 0

        context.manager.subscribe(
            filter: makeFilter(),
            id: "timeout",
            relayUrls: [relayURL],
            handler: { _ in },
            onEOSE: { eoseCount += 1 }
        )

        let subscribed = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.count == 1
        }
        XCTAssertTrue(subscribed)

        // The fallback is scheduled but has not fired yet.
        XCTAssertEqual(context.scheduler.scheduled.first?.delay, TransportConfig.nostrSubscriptionEOSEFallbackSeconds)
        XCTAssertEqual(eoseCount, 0)

        context.scheduler.runNext()
        let timedOut = await waitUntil { eoseCount == 1 }
        XCTAssertTrue(timedOut)

        try context.sessionFactory.latestConnection(for: relayURL)?.emitEOSE(subscriptionID: "timeout")
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(eoseCount, 1)
    }

    func test_eose_completesWhenRelayDisconnectsBeforeEOSE() async throws {
        let relayOne = "wss://eose-drop-one.example"
        let relayTwo = "wss://eose-drop-two.example"
        let context = makeContext(permission: .denied)
        var eoseCount = 0

        context.manager.subscribe(
            filter: makeFilter(),
            id: "eose-drop",
            relayUrls: [relayOne, relayTwo],
            handler: { _ in },
            onEOSE: { eoseCount += 1 }
        )

        let subscribed = await waitUntil {
            context.sessionFactory.latestConnection(for: relayOne)?.sentStrings.count == 1 &&
            context.sessionFactory.latestConnection(for: relayTwo)?.sentStrings.count == 1
        }
        XCTAssertTrue(subscribed)

        try context.sessionFactory.latestConnection(for: relayOne)?.emitEOSE(subscriptionID: "eose-drop")
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(eoseCount, 0)

        context.sessionFactory.latestConnection(for: relayTwo)?.fail(
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        )
        let completed = await waitUntil { eoseCount == 1 }
        XCTAssertTrue(completed)
    }

    func test_reconnect_replaysActiveSubscriptionsAndDeliversEvents() async throws {
        let relayURL = "wss://replay.example"
        let context = makeContext(permission: .denied)
        var received: [NostrEvent] = []

        context.manager.subscribe(
            filter: makeFilter(),
            id: "replay-sub",
            relayUrls: [relayURL],
            handler: { received.append($0) }
        )
        let subscribed = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.contains { $0.contains("replay-sub") } == true
        }
        XCTAssertTrue(subscribed)

        // Drop the socket; the relay forgets the subscription with it.
        context.sessionFactory.latestConnection(for: relayURL)?.fail(
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        )
        let retryScheduled = await waitUntil { !context.scheduler.scheduled.isEmpty }
        XCTAssertTrue(retryScheduled)
        context.scheduler.runNext()

        let replayed = await waitUntil {
            let connections = context.sessionFactory.connectionsByURL[relayURL] ?? []
            return connections.count == 2 &&
                connections.last?.sentStrings.contains { $0.contains("replay-sub") } == true
        }
        XCTAssertTrue(replayed)

        let event = try makeSignedEvent(content: "after reconnect")
        try context.sessionFactory.latestConnection(for: relayURL)?.emitEventMessage(subscriptionID: "replay-sub", event: event)
        let delivered = await waitUntil { received.count == 1 }
        XCTAssertTrue(delivered)
    }

    func test_disconnectThenConnect_restoresSubscriptions() async {
        let relayURL = "wss://restore.example"
        let context = makeContext(permission: .denied)

        context.manager.subscribe(filter: makeFilter(), id: "restore-sub", relayUrls: [relayURL], handler: { _ in })
        let subscribed = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.contains { $0.contains("restore-sub") } == true
        }
        XCTAssertTrue(subscribed)

        // Background → foreground: connections reset, subscriptions must survive.
        context.manager.disconnect()
        context.manager.connect()

        let resubscribed = await waitUntil {
            let connections = context.sessionFactory.connectionsByURL[relayURL] ?? []
            return connections.count == 2 &&
                connections.last?.sentStrings.contains { $0.contains("restore-sub") } == true
        }
        XCTAssertTrue(resubscribed)
    }

    func test_subscriptionSendFailure_retriesOnReconnect() async {
        let relayURL = "wss://flaky-send.example"
        let context = makeContext(permission: .denied)
        context.sessionFactory.sendErrorByURL[relayURL] = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        context.manager.subscribe(filter: makeFilter(), id: "flaky-sub", relayUrls: [relayURL], handler: { _ in })
        let attempted = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL)?.sentStrings.isEmpty == false
        }
        XCTAssertTrue(attempted)

        // The REQ send failed; the subscription must survive for the next connection.
        context.sessionFactory.sendErrorByURL[relayURL] = nil
        context.sessionFactory.latestConnection(for: relayURL)?.fail(
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        )
        let retryScheduled = await waitUntil { !context.scheduler.scheduled.isEmpty }
        XCTAssertTrue(retryScheduled)
        context.scheduler.runNext()

        let resubscribed = await waitUntil {
            let connections = context.sessionFactory.connectionsByURL[relayURL] ?? []
            return connections.count == 2 &&
                connections.last?.sentStrings.contains { $0.contains("flaky-sub") } == true
        }
        XCTAssertTrue(resubscribed)
    }

    func test_permanentFailure_decaysAfterCooldownAndRetries() async {
        let relayURL = "wss://cooldown.example"
        let context = makeContext(permission: .denied)
        context.sessionFactory.pingErrorByURL[relayURL] = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotFindHost,
            userInfo: [NSLocalizedDescriptionKey: "DNS failure"]
        )

        context.manager.ensureConnections(to: [relayURL])
        let failed = await waitUntil {
            context.manager.relays.first(where: { $0.url == relayURL })?.reconnectAttempts == TransportConfig.nostrRelayMaxReconnectAttempts
        }
        XCTAssertTrue(failed)

        // Within the cooldown the relay is skipped.
        let countBefore = context.sessionFactory.requestedURLs.count
        context.manager.ensureConnections(to: [relayURL])
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(context.sessionFactory.requestedURLs.count, countBefore)

        // After the cooldown it gets another chance and recovers.
        context.sessionFactory.pingErrorByURL[relayURL] = nil
        context.clock.now = context.clock.now.addingTimeInterval(TransportConfig.nostrRelayFailureCooldownSeconds + 1)
        context.manager.ensureConnections(to: [relayURL])
        let retried = await waitUntil {
            context.sessionFactory.requestedURLs.count == countBefore + 1 &&
            context.manager.relays.first(where: { $0.url == relayURL })?.isConnected == true
        }
        XCTAssertTrue(retried)
    }

    func test_receiveFailure_schedulesReconnectWithBackoff() async {
        let relayURL = "wss://retry.example"
        let context = makeContext(permission: .denied)

        context.manager.ensureConnections(to: [relayURL])
        let firstConnected = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL) != nil
        }
        XCTAssertTrue(firstConnected)

        let firstConnection = context.sessionFactory.latestConnection(for: relayURL)
        firstConnection?.fail(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))

        let retryScheduled = await waitUntil {
            context.scheduler.scheduled.count == 1 &&
            context.manager.relays.first(where: { $0.url == relayURL })?.reconnectAttempts == 1
        }
        XCTAssertTrue(retryScheduled)
        XCTAssertEqual(context.scheduler.scheduled.first?.delay, TransportConfig.nostrRelayInitialBackoffSeconds)

        let initialRequestCount = context.sessionFactory.requestedURLs.count
        context.scheduler.runNext()

        let retried = await waitUntil {
            context.sessionFactory.requestedURLs.count == initialRequestCount + 1
        }
        XCTAssertTrue(retried)
    }

    func test_receiveFailure_whenActivationBecomesDisallowedDoesNotScheduleReconnect() async {
        let relayURL = "wss://no-retry.example"
        let context = makeContext(permission: .denied)

        context.manager.ensureConnections(to: [relayURL])
        let connected = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL) != nil &&
            context.manager.relays.first(where: { $0.url == relayURL })?.isConnected == true
        }
        XCTAssertTrue(connected)

        context.activationAllowed.value = false
        context.sessionFactory.latestConnection(for: relayURL)?.fail(
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        )

        let disconnected = await waitUntil {
            context.manager.relays.first(where: { $0.url == relayURL })?.isConnected == false
        }
        XCTAssertTrue(disconnected)
        XCTAssertTrue(context.scheduler.scheduled.isEmpty)
        XCTAssertEqual(context.sessionFactory.requestedURLs.count, 1)
    }

    func test_disconnect_invalidatesScheduledReconnectGeneration() async {
        let relayURL = "wss://disconnect.example"
        let context = makeContext(permission: .denied)

        context.manager.ensureConnections(to: [relayURL])
        let firstConnected = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL) != nil
        }
        XCTAssertTrue(firstConnected)

        context.sessionFactory.latestConnection(for: relayURL)?.fail(
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        )
        let retryScheduled = await waitUntil { context.scheduler.scheduled.count == 1 }
        XCTAssertTrue(retryScheduled)

        let requestCountBeforeDisconnect = context.sessionFactory.requestedURLs.count
        context.manager.disconnect()
        context.scheduler.runNext()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(context.sessionFactory.requestedURLs.count, requestCountBeforeDisconnect)
    }

    func test_retryConnection_cancelsActiveConnectionBeforeReconnecting() async {
        let relayURL = "wss://retry-now.example"
        let context = makeContext(permission: .denied)

        context.manager.ensureConnections(to: [relayURL])
        let connected = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL) != nil &&
            context.manager.relays.first(where: { $0.url == relayURL })?.isConnected == true
        }
        XCTAssertTrue(connected)

        guard let firstConnection = context.sessionFactory.latestConnection(for: relayURL) else {
            XCTFail("Expected initial connection")
            return
        }
        let initialRequestCount = context.sessionFactory.requestedURLs.count

        context.manager.retryConnection(to: relayURL)

        let reconnected = await waitUntil {
            guard let latest = context.sessionFactory.latestConnection(for: relayURL) else { return false }
            return context.sessionFactory.requestedURLs.count == initialRequestCount + 1 &&
                latest !== firstConnection
        }
        XCTAssertTrue(reconnected)
        XCTAssertEqual(firstConnection.cancelCallCount, 1)
    }

    func test_retryConnection_whenTorReadinessFailsDoesNotReconnect() async {
        let relayURL = "wss://retry-tor.example"
        let context = makeContext(permission: .denied, userTorEnabled: true, torEnforced: true, torIsReady: true)

        context.manager.ensureConnections(to: [relayURL])
        let connected = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL) != nil &&
            context.manager.relays.first(where: { $0.url == relayURL })?.isConnected == true
        }
        XCTAssertTrue(connected)

        guard let firstConnection = context.sessionFactory.latestConnection(for: relayURL) else {
            XCTFail("Expected initial connection")
            return
        }

        let initialRequestCount = context.sessionFactory.requestedURLs.count
        context.torWaiter.isReady = false
        context.manager.retryConnection(to: relayURL)

        XCTAssertEqual(firstConnection.cancelCallCount, 1)
        XCTAssertEqual(context.sessionFactory.requestedURLs.count, initialRequestCount)

        context.torWaiter.resolve(false)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(context.sessionFactory.requestedURLs.count, initialRequestCount)
    }

    func test_resetAllConnections_clearsRelayStateAndReconnects() async {
        let relayURL = "wss://reset.example"
        let context = makeContext(permission: .denied)

        context.manager.ensureConnections(to: [relayURL])
        let connected = await waitUntil {
            context.sessionFactory.latestConnection(for: relayURL) != nil &&
            context.manager.relays.first(where: { $0.url == relayURL })?.isConnected == true
        }
        XCTAssertTrue(connected)

        context.sessionFactory.latestConnection(for: relayURL)?.fail(
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        )
        let failed = await waitUntil {
            context.manager.relays.first(where: { $0.url == relayURL })?.reconnectAttempts == 1 &&
            context.manager.relays.first(where: { $0.url == relayURL })?.lastError != nil
        }
        XCTAssertTrue(failed)

        let requestCountBeforeReset = context.sessionFactory.requestedURLs.count
        context.manager.resetAllConnections()

        let reset = await waitUntil {
            context.sessionFactory.requestedURLs.count == requestCountBeforeReset + 1 &&
            context.manager.relays.first(where: { $0.url == relayURL })?.isConnected == true &&
            context.manager.relays.first(where: { $0.url == relayURL })?.reconnectAttempts == 0 &&
            context.manager.relays.first(where: { $0.url == relayURL })?.nextReconnectTime == nil &&
            context.manager.relays.first(where: { $0.url == relayURL })?.lastError == nil
        }
        XCTAssertTrue(reset)
    }

    func test_debugFlushMessageQueue_flushesAllConnectedRelays() async throws {
        let relayOne = "wss://flush-one.example"
        let relayTwo = "wss://flush-two.example"
        let context = makeContext(
            permission: .denied,
            userTorEnabled: true,
            torEnforced: true,
            torIsReady: true,
            torIsForeground: false
        )
        let event = try makeSignedEvent(content: "flush-all")

        context.manager.sendEvent(event, to: [relayOne, relayTwo])
        let queued = await waitUntil {
            context.manager.debugPendingMessageQueueCount == 1
        }
        XCTAssertTrue(queued)

        context.torForeground.value = true
        context.manager.ensureConnections(to: [relayOne, relayTwo])
        context.manager.debugFlushMessageQueue()

        let flushed = await waitUntil {
            context.manager.debugPendingMessageQueueCount == 0 &&
            context.sessionFactory.latestConnection(for: relayOne)?.sentStrings.count == 1 &&
            context.sessionFactory.latestConnection(for: relayTwo)?.sentStrings.count == 1
        }
        XCTAssertTrue(flushed)
    }

    func test_dnsPingFailure_marksRelayPermanentCallsEOSEImmediatelyAndManualRetryReconnects() async {
        let relayURL = "wss://dns-failure.example"
        let context = makeContext(permission: .denied)
        context.sessionFactory.pingErrorByURL[relayURL] = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotFindHost,
            userInfo: [NSLocalizedDescriptionKey: "DNS failure"]
        )

        context.manager.subscribe(filter: makeFilter(), id: "dns-sub", relayUrls: [relayURL], handler: { _ in })
        let permanentlyFailed = await waitUntil {
            context.manager.relays.first(where: { $0.url == relayURL })?.reconnectAttempts == TransportConfig.nostrRelayMaxReconnectAttempts &&
            context.scheduler.scheduled.isEmpty
        }
        XCTAssertTrue(permanentlyFailed)

        var immediateEOSE = 0
        context.manager.subscribe(
            filter: makeFilter(),
            id: "dns-eose",
            relayUrls: [relayURL],
            handler: { _ in },
            onEOSE: { immediateEOSE += 1 }
        )
        XCTAssertEqual(immediateEOSE, 1)

        context.sessionFactory.pingErrorByURL[relayURL] = nil
        let requestCountBeforeRetry = context.sessionFactory.requestedURLs.count
        context.manager.retryConnection(to: relayURL)

        let reconnected = await waitUntil {
            context.sessionFactory.requestedURLs.count == requestCountBeforeRetry + 1 &&
            context.manager.relays.first(where: { $0.url == relayURL })?.isConnected == true &&
            context.manager.relays.first(where: { $0.url == relayURL })?.reconnectAttempts == 0
        }
        XCTAssertTrue(reconnected)
    }

    private func makeContext(
        permission: LocationChannelManager.PermissionState,
        favorites: Set<Data> = [],
        activationAllowed: Bool = true,
        userTorEnabled: Bool = false,
        torEnforced: Bool = false,
        torIsReady: Bool = true,
        torIsForeground: Bool = true
    ) -> RelayManagerTestContext {
        let permissionSubject = CurrentValueSubject<LocationChannelManager.PermissionState, Never>(permission)
        let favoritesSubject = CurrentValueSubject<Set<Data>, Never>(favorites)
        let sessionFactory = MockRelaySessionFactory()
        let scheduler = MockRelayScheduler()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let torWaiter = MockTorWaiter(isReady: torIsReady)
        let torForeground = MutableBool(value: torIsForeground)
        let activationFlag = MutableBool(value: activationAllowed)
        let manager = NostrRelayManager(
            dependencies: NostrRelayManagerDependencies(
                activationAllowed: { activationFlag.value },
                userTorEnabled: { userTorEnabled },
                hasMutualFavorites: { !favoritesSubject.value.isEmpty },
                hasLocationPermission: { permissionSubject.value == .authorized },
                mutualFavoritesPublisher: favoritesSubject.eraseToAnyPublisher(),
                locationPermissionPublisher: permissionSubject.eraseToAnyPublisher(),
                torEnforced: { torEnforced },
                torIsReady: { torWaiter.isReady },
                torIsForeground: { torForeground.value },
                awaitTorReady: torWaiter.await(completion:),
                makeSession: { sessionFactory },
                scheduleAfter: { delay, action in
                    scheduler.schedule(delay: delay, action: action)
                },
                now: { clock.now }
            )
        )
        return RelayManagerTestContext(
            manager: manager,
            permissionSubject: permissionSubject,
            favoritesSubject: favoritesSubject,
            sessionFactory: sessionFactory,
            scheduler: scheduler,
            clock: clock,
            activationAllowed: activationFlag,
            torWaiter: torWaiter,
            torForeground: torForeground
        )
    }

    private func makeFilter() -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [NostrProtocol.EventKind.textNote.rawValue]
        filter.limit = 10
        return filter
    }

    private func makeSignedEvent(content: String) throws -> NostrEvent {
        let identity = try NostrIdentity.generate()
        let event = NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: Date(),
            kind: .textNote,
            tags: [],
            content: content
        )
        return try event.sign(with: identity.schnorrSigningKey())
    }

    private func invalidSignatureCopy(of event: NostrEvent) -> NostrEvent {
        var invalid = event
        invalid.sig = String(repeating: "0", count: 128)
        return invalid
    }

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

@MainActor
private struct RelayManagerTestContext {
    let manager: NostrRelayManager
    let permissionSubject: CurrentValueSubject<LocationChannelManager.PermissionState, Never>
    let favoritesSubject: CurrentValueSubject<Set<Data>, Never>
    let sessionFactory: MockRelaySessionFactory
    let scheduler: MockRelayScheduler
    let clock: MutableClock
    let activationAllowed: MutableBool
    let torWaiter: MockTorWaiter
    let torForeground: MutableBool
}

private final class MutableClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private final class MutableBool {
    var value: Bool

    init(value: Bool) {
        self.value = value
    }
}

private final class MockTorWaiter {
    private var completions: [(Bool) -> Void] = []
    private(set) var awaitCallCount = 0
    var isReady: Bool

    init(isReady: Bool) {
        self.isReady = isReady
    }

    func await(completion: @escaping (Bool) -> Void) {
        awaitCallCount += 1
        completions.append(completion)
    }

    func resolve(_ ready: Bool) {
        isReady = ready
        let pending = completions
        completions.removeAll()
        pending.forEach { $0(ready) }
    }
}

private final class MockRelayScheduler: @unchecked Sendable {
    struct ScheduledAction {
        let delay: TimeInterval
        let action: @Sendable () -> Void
    }

    private(set) var scheduled: [ScheduledAction] = []

    func schedule(delay: TimeInterval, action: @escaping @Sendable () -> Void) {
        scheduled.append(ScheduledAction(delay: delay, action: action))
    }

    func runNext() {
        guard !scheduled.isEmpty else { return }
        let next = scheduled.removeFirst()
        next.action()
    }
}

private final class MockRelaySessionFactory: NostrRelaySessionProtocol {
    private(set) var requestedURLs: [String] = []
    private(set) var connectionsByURL: [String: [MockRelayConnection]] = [:]
    var pingErrorByURL: [String: Error?] = [:]
    var sendErrorByURL: [String: Error?] = [:]

    var allConnections: [MockRelayConnection] {
        connectionsByURL.values.flatMap { $0 }
    }

    func webSocketTask(with url: URL) -> NostrRelayConnectionProtocol {
        requestedURLs.append(url.absoluteString)
        let connection = MockRelayConnection(
            url: url.absoluteString,
            pingError: pingErrorByURL[url.absoluteString] ?? nil,
            sendError: sendErrorByURL[url.absoluteString] ?? nil
        )
        connectionsByURL[url.absoluteString, default: []].append(connection)
        return connection
    }

    func latestConnection(for url: String) -> MockRelayConnection? {
        connectionsByURL[url]?.last
    }
}

private final class MockRelayConnection: NostrRelayConnectionProtocol {
    private let url: String
    private let pingError: Error?
    private let sendError: Error?
    private var receiveHandler: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    private(set) var resumeCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var sentMessages: [URLSessionWebSocketTask.Message] = []

    var sentStrings: [String] {
        sentMessages.compactMap {
            switch $0 {
            case .string(let string): string
            case .data(let data): String(data: data, encoding: .utf8)
            @unknown default: nil
            }
        }
    }

    init(url: String, pingError: Error? = nil, sendError: Error? = nil) {
        self.url = url
        self.pingError = pingError
        self.sendError = sendError
    }

    func resume() {
        resumeCallCount += 1
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelCallCount += 1
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void) {
        sentMessages.append(message)
        completionHandler(sendError)
    }

    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        receiveHandler = completionHandler
    }

    func sendPing(pongReceiveHandler: @escaping (Error?) -> Void) {
        pongReceiveHandler(pingError)
    }

    func fail(error: Error) {
        let handler = receiveHandler
        receiveHandler = nil
        handler?(.failure(error))
    }

    func emitEventMessage(subscriptionID: String, event: NostrEvent) throws {
        let eventData = try JSONEncoder().encode(event)
        let eventJSONObject = try JSONSerialization.jsonObject(with: eventData) as! [String: Any]
        let payload: [Any] = ["EVENT", subscriptionID, eventJSONObject]
        try emit(jsonObject: payload)
    }

    func emitEOSE(subscriptionID: String) throws {
        try emit(jsonObject: ["EOSE", subscriptionID])
    }

    func emitOK(eventID: String, success: Bool, reason: String) throws {
        try emit(jsonObject: ["OK", eventID, success, reason])
    }

    func emitNotice(message: String) throws {
        try emit(jsonObject: ["NOTICE", message])
    }

    func emitRawString(_ string: String) throws {
        let handler = receiveHandler
        receiveHandler = nil
        handler?(.success(.string(string)))
    }

    private func emit(jsonObject: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        let handler = receiveHandler
        receiveHandler = nil
        handler?(.success(.data(data)))
    }
}
