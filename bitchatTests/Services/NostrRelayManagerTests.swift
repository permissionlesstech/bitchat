import Combine
import XCTest
@testable import bitchat

@MainActor
final class NostrRelayManagerTests: XCTestCase {
    func test_permissionPublisher_addsAndRemovesDefaultRelays() async {
        let context = makeContext(permission: .denied, favorites: [])

        XCTAssertEqual(context.manager.getRelayStatuses().count, 0)

        context.permissionSubject.send(.authorized)

        let defaultRelaysConnected = await waitUntil {
            context.manager.getRelayStatuses().count == 5 &&
            context.manager.relays.allSatisfy(\.isConnected)
        }
        XCTAssertTrue(defaultRelaysConnected)

        context.permissionSubject.send(.denied)

        let defaultRelaysRemoved = await waitUntil {
            context.manager.getRelayStatuses().isEmpty
        }
        XCTAssertTrue(defaultRelaysRemoved)
        XCTAssertEqual(context.sessionFactory.allConnections.count, 5)
        XCTAssertTrue(context.sessionFactory.allConnections.allSatisfy { $0.cancelCallCount >= 1 })
    }

    func test_connect_waitsForTorReadinessBeforeCreatingSessions() async {
        let context = makeContext(permission: .authorized, userTorEnabled: true, torEnforced: true, torIsReady: false)

        context.manager.connect()

        XCTAssertTrue(context.sessionFactory.requestedURLs.isEmpty)

        context.torWaiter.resolve(true)

        let connectedAfterTorReady = await waitUntil {
            context.sessionFactory.requestedURLs.count == 5 &&
            context.manager.relays.allSatisfy(\.isConnected)
        }
        XCTAssertTrue(connectedAfterTorReady)
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

        context.manager.ensureConnections(to: [relayOne, relayOne, relayTwo])

        let connected = await waitUntil {
            Set(context.manager.getRelayStatuses().map(\.url)) == Set([relayOne, relayTwo]) &&
            context.manager.relays.allSatisfy(\.isConnected)
        }
        XCTAssertTrue(connected)
        XCTAssertEqual(context.sessionFactory.requestedURLs, [relayOne, relayTwo])
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

    private func makeContext(
        permission: LocationChannelManager.PermissionState,
        favorites: Set<Data> = [],
        activationAllowed: Bool = true,
        userTorEnabled: Bool = false,
        torEnforced: Bool = false,
        torIsReady: Bool = true
    ) -> RelayManagerTestContext {
        let permissionSubject = CurrentValueSubject<LocationChannelManager.PermissionState, Never>(permission)
        let favoritesSubject = CurrentValueSubject<Set<Data>, Never>(favorites)
        let sessionFactory = MockRelaySessionFactory()
        let scheduler = MockRelayScheduler()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let torWaiter = MockTorWaiter(isReady: torIsReady)
        let manager = NostrRelayManager(
            dependencies: NostrRelayManagerDependencies(
                activationAllowed: { activationAllowed },
                userTorEnabled: { userTorEnabled },
                hasMutualFavorites: { !favoritesSubject.value.isEmpty },
                hasLocationPermission: { permissionSubject.value == .authorized },
                mutualFavoritesPublisher: favoritesSubject.eraseToAnyPublisher(),
                locationPermissionPublisher: permissionSubject.eraseToAnyPublisher(),
                torEnforced: { torEnforced },
                torIsReady: { torWaiter.isReady },
                torIsForeground: { true },
                awaitTorReady: torWaiter.await(completion:),
                makeSession: { sessionFactory },
                scheduleAfter: scheduler.schedule(delay:action:),
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
            torWaiter: torWaiter
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
    let torWaiter: MockTorWaiter
}

private final class MutableClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private final class MockTorWaiter {
    private var completions: [(Bool) -> Void] = []
    var isReady: Bool

    init(isReady: Bool) {
        self.isReady = isReady
    }

    func await(completion: @escaping (Bool) -> Void) {
        completions.append(completion)
    }

    func resolve(_ ready: Bool) {
        isReady = ready
        let pending = completions
        completions.removeAll()
        pending.forEach { $0(ready) }
    }
}

private final class MockRelayScheduler {
    struct ScheduledAction {
        let delay: TimeInterval
        let action: () -> Void
    }

    private(set) var scheduled: [ScheduledAction] = []

    func schedule(delay: TimeInterval, action: @escaping () -> Void) {
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

    var allConnections: [MockRelayConnection] {
        connectionsByURL.values.flatMap { $0 }
    }

    func webSocketTask(with url: URL) -> NostrRelayConnectionProtocol {
        requestedURLs.append(url.absoluteString)
        let connection = MockRelayConnection(url: url.absoluteString)
        connectionsByURL[url.absoluteString, default: []].append(connection)
        return connection
    }

    func latestConnection(for url: String) -> MockRelayConnection? {
        connectionsByURL[url]?.last
    }
}

private final class MockRelayConnection: NostrRelayConnectionProtocol {
    private let url: String
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

    init(url: String) {
        self.url = url
    }

    func resume() {
        resumeCallCount += 1
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelCallCount += 1
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void) {
        sentMessages.append(message)
        completionHandler(nil)
    }

    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        receiveHandler = completionHandler
    }

    func sendPing(pongReceiveHandler: @escaping (Error?) -> Void) {
        pongReceiveHandler(nil)
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

    private func emit(jsonObject: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        let handler = receiveHandler
        receiveHandler = nil
        handler?(.success(.data(data)))
    }
}
