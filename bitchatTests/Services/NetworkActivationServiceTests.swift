import Combine
import XCTest
@testable import bitchat

@MainActor
final class NetworkActivationServiceTests: XCTestCase {
    private let torPreferenceKey = "networkActivationService.userTorEnabled"

    func test_start_leavesNetworkDisabledWithoutPermissionOrFavorites() {
        let context = makeService(permission: .denied, favorites: [])

        context.service.start()

        XCTAssertFalse(context.service.activationAllowed)
        XCTAssertEqual(context.torController.autoStartAllowedValues, [false])
        XCTAssertEqual(context.proxyController.proxyModes, [false])
        XCTAssertEqual(context.torController.startIfNeededCallCount, 0)
        XCTAssertEqual(context.torController.shutdownCompletelyCallCount, 1)
        XCTAssertEqual(context.relayController.connectCallCount, 0)
        XCTAssertEqual(context.relayController.disconnectCallCount, 1)
    }

    func test_start_enablesTorAndRelaysWhenAuthorized() {
        let context = makeService(permission: .authorized, favorites: [])

        context.service.start()

        XCTAssertTrue(context.service.activationAllowed)
        XCTAssertEqual(context.torController.autoStartAllowedValues, [true])
        XCTAssertEqual(context.proxyController.proxyModes, [true])
        XCTAssertEqual(context.torController.startIfNeededCallCount, 1)
        XCTAssertEqual(context.relayController.connectCallCount, 1)
        XCTAssertEqual(context.relayController.disconnectCallCount, 0)
    }

    func test_start_respectsStoredTorPreferenceForDirectMode() {
        let context = makeService(permission: .authorized, favorites: [])
        context.storage.set(false, forKey: torPreferenceKey)

        context.service.start()

        XCTAssertTrue(context.service.activationAllowed)
        XCTAssertFalse(context.service.userTorEnabled)
        XCTAssertEqual(context.torController.autoStartAllowedValues, [false])
        XCTAssertEqual(context.proxyController.proxyModes, [false])
        XCTAssertEqual(context.torController.startIfNeededCallCount, 0)
        XCTAssertEqual(context.torController.shutdownCompletelyCallCount, 1)
        XCTAssertEqual(context.relayController.connectCallCount, 1)
    }

    func test_setUserTorEnabled_postsNotificationAndReconnectsOnTransportSwitch() {
        let context = makeService(permission: .authorized, favorites: [])
        let notified = expectation(description: "Tor preference notification")
        let token = context.notificationCenter.addObserver(
            forName: .TorUserPreferenceChanged,
            object: nil,
            queue: nil
        ) { note in
            XCTAssertEqual(note.userInfo?["enabled"] as? Bool, false)
            notified.fulfill()
        }

        context.service.start()
        context.service.setUserTorEnabled(false)

        wait(for: [notified], timeout: TestConstants.negativeWaitWindow)
        context.notificationCenter.removeObserver(token)

        XCTAssertFalse(context.service.userTorEnabled)
        XCTAssertEqual(context.storage.object(forKey: torPreferenceKey) as? Bool, false)
        XCTAssertEqual(Array(context.proxyController.proxyModes.suffix(2)), [true, false])
        XCTAssertEqual(Array(context.torController.autoStartAllowedValues.suffix(2)), [true, false])
        XCTAssertEqual(context.relayController.disconnectCallCount, 1)
        XCTAssertEqual(context.relayController.connectCallCount, 2)
    }

    func test_mutualFavoritesPublisher_reactivatesNetwork() async {
        let context = makeService(permission: .denied, favorites: [])

        context.service.start()
        XCTAssertFalse(context.service.activationAllowed)

        context.favoritesSubject.send([Data([0x01])])
        let becameActive = await waitUntil { context.service.activationAllowed }
        XCTAssertTrue(becameActive)

        XCTAssertTrue(context.service.activationAllowed)
        XCTAssertTrue(context.torController.autoStartAllowedValues.contains(true))
        XCTAssertTrue(context.proxyController.proxyModes.contains(true))
        XCTAssertGreaterThanOrEqual(context.torController.startIfNeededCallCount, 1)
        XCTAssertGreaterThanOrEqual(context.relayController.connectCallCount, 1)
    }

    func test_stopForPanic_synchronouslyStopsAndIgnoresPublisherUpdates() async {
        let context = makeService(permission: .authorized, favorites: [])

        context.service.start()
        context.service.stopForPanic()
        let connectCountAfterStop = context.relayController.connectCallCount
        let startCountAfterStop = context.torController.startIfNeededCallCount

        context.favoritesSubject.send([Data([0x01])])
        context.reachability.set(false)
        context.reachability.set(true)
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertFalse(context.service.activationAllowed)
        XCTAssertEqual(context.reachability.stopCallCount, 1)
        XCTAssertEqual(context.torController.autoStartAllowedValues.last, false)
        XCTAssertEqual(context.proxyController.proxyModes.last, false)
        XCTAssertGreaterThanOrEqual(
            context.torController.shutdownCompletelyCallCount,
            1
        )
        XCTAssertGreaterThanOrEqual(
            context.relayController.disconnectCallCount,
            1
        )
        XCTAssertEqual(
            context.relayController.connectCallCount,
            connectCountAfterStop
        )
        XCTAssertEqual(
            context.torController.startIfNeededCallCount,
            startCountAfterStop
        )
    }

    func test_start_afterPanicStop_reestablishesSubscriptions() {
        let context = makeService(permission: .authorized, favorites: [])

        context.service.start()
        context.service.stopForPanic()
        context.service.start()

        XCTAssertTrue(context.service.activationAllowed)
        XCTAssertEqual(context.reachability.startCallCount, 2)
        XCTAssertEqual(context.relayController.connectCallCount, 2)
    }

    /// Teleporting into a geohash needs no location permission, so someone who
    /// denied location and has no mutual favorites could previously sit in a
    /// channel that never connected: the gate suppressed Tor and the relays,
    /// and nothing explained why.
    func test_start_enablesNetworkForALocationChannelWithoutPermissionOrFavorites() {
        let context = makeService(
            permission: .denied,
            favorites: [],
            selectedChannel: .location(GeohashChannel(level: .city, geohash: "u4pruy"))
        )

        context.service.start()

        XCTAssertTrue(context.service.activationAllowed)
        XCTAssertEqual(context.torController.startIfNeededCallCount, 1)
        XCTAssertEqual(context.relayController.connectCallCount, 1)
    }

    func test_selectedChannelPublisher_activatesOnEnteringALocationChannel() async {
        let channelSubject = CurrentValueSubject<ChannelID, Never>(.mesh)
        let context = makeService(
            permission: .denied,
            favorites: [],
            selectedChannelSubject: channelSubject
        )

        context.service.start()
        XCTAssertFalse(context.service.activationAllowed)

        channelSubject.send(.location(GeohashChannel(level: .city, geohash: "u4pruy")))

        let activated = await waitUntil { context.service.activationAllowed }
        XCTAssertTrue(activated)
    }

    /// Leaving the channel must close the gate again, or the exception would
    /// quietly become permanent for the rest of the session.
    func test_selectedChannelPublisher_deactivatesOnReturningToMesh() async {
        let channelSubject = CurrentValueSubject<ChannelID, Never>(
            .location(GeohashChannel(level: .city, geohash: "u4pruy"))
        )
        let context = makeService(
            permission: .denied,
            favorites: [],
            selectedChannelSubject: channelSubject
        )

        context.service.start()
        XCTAssertTrue(context.service.activationAllowed)

        channelSubject.send(.mesh)

        let deactivated = await waitUntil { !context.service.activationAllowed }
        XCTAssertTrue(deactivated)
    }

    private func makeService(
        permission: LocationChannelManager.PermissionState,
        favorites: Set<Data>,
        selectedChannel: ChannelID = .mesh,
        selectedChannelSubject: CurrentValueSubject<ChannelID, Never>? = nil
    ) -> NetworkActivationTestContext {
        let suiteName = "NetworkActivationServiceTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        storage.removePersistentDomain(forName: suiteName)

        let permissionSubject = CurrentValueSubject<LocationChannelManager.PermissionState, Never>(permission)
        let favoritesSubject = CurrentValueSubject<Set<Data>, Never>(favorites)
        let channelSubject = selectedChannelSubject
            ?? CurrentValueSubject<ChannelID, Never>(selectedChannel)
        let torController = MockNetworkActivationTorController()
        let relayController = MockNetworkActivationRelayController()
        let proxyController = MockNetworkActivationProxyController()
        let reachability = MockNetworkActivationReachability()
        let notificationCenter = NotificationCenter()
        let service = NetworkActivationService(
            storage: storage,
            locationPermissionPublisher: permissionSubject.eraseToAnyPublisher(),
            mutualFavoritesPublisher: favoritesSubject.eraseToAnyPublisher(),
            permissionProvider: { permissionSubject.value },
            mutualFavoritesProvider: { favoritesSubject.value },
            selectedChannelPublisher: channelSubject.eraseToAnyPublisher(),
            locationChannelSelectedProvider: {
                if case .location = channelSubject.value { return true }
                return false
            },
            reachabilityMonitor: reachability,
            torController: torController,
            relayController: relayController,
            proxyController: proxyController,
            notificationCenter: notificationCenter
        )
        return NetworkActivationTestContext(
            service: service,
            storage: storage,
            favoritesSubject: favoritesSubject,
            reachability: reachability,
            torController: torController,
            relayController: relayController,
            proxyController: proxyController,
            notificationCenter: notificationCenter
        )
    }

    private func waitUntil(
        timeout: TimeInterval = TestConstants.settleTimeout,
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
private struct NetworkActivationTestContext {
    let service: NetworkActivationService
    let storage: UserDefaults
    let favoritesSubject: CurrentValueSubject<Set<Data>, Never>
    let reachability: MockNetworkActivationReachability
    let torController: MockNetworkActivationTorController
    let relayController: MockNetworkActivationRelayController
    let proxyController: MockNetworkActivationProxyController
    let notificationCenter: NotificationCenter
}

@MainActor
private final class MockNetworkActivationReachability:
    NetworkReachabilityMonitoring {
    private let subject = CurrentValueSubject<Bool, Never>(true)
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    var isReachable: Bool { subject.value }
    var reachabilityPublisher: AnyPublisher<Bool, Never> {
        subject.removeDuplicates().dropFirst().eraseToAnyPublisher()
    }

    func start() {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }

    func set(_ reachable: Bool) {
        subject.send(reachable)
    }
}

@MainActor
private final class MockNetworkActivationTorController: NetworkActivationTorControlling {
    private(set) var autoStartAllowedValues: [Bool] = []
    private(set) var startIfNeededCallCount = 0
    private(set) var shutdownCompletelyCallCount = 0

    func setAutoStartAllowed(_ allowed: Bool) {
        autoStartAllowedValues.append(allowed)
    }

    func startIfNeeded() {
        startIfNeededCallCount += 1
    }

    func shutdownCompletely() {
        shutdownCompletelyCallCount += 1
    }
}

@MainActor
private final class MockNetworkActivationRelayController: NetworkActivationRelayControlling {
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0

    func connect() {
        connectCallCount += 1
    }

    func disconnect() {
        disconnectCallCount += 1
    }
}

private final class MockNetworkActivationProxyController: NetworkActivationProxyControlling {
    private(set) var proxyModes: [Bool] = []

    func setProxyMode(useTor: Bool) {
        proxyModes.append(useTor)
    }
}
