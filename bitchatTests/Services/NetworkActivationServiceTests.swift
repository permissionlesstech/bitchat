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

        wait(for: [notified], timeout: 1.0)
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

    private func makeService(
        permission: LocationChannelManager.PermissionState,
        favorites: Set<Data>
    ) -> NetworkActivationTestContext {
        let suiteName = "NetworkActivationServiceTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        storage.removePersistentDomain(forName: suiteName)

        let permissionSubject = CurrentValueSubject<LocationChannelManager.PermissionState, Never>(permission)
        let favoritesSubject = CurrentValueSubject<Set<Data>, Never>(favorites)
        let torController = MockNetworkActivationTorController()
        let relayController = MockNetworkActivationRelayController()
        let proxyController = MockNetworkActivationProxyController()
        let notificationCenter = NotificationCenter()
        let service = NetworkActivationService(
            storage: storage,
            locationPermissionPublisher: permissionSubject.eraseToAnyPublisher(),
            mutualFavoritesPublisher: favoritesSubject.eraseToAnyPublisher(),
            permissionProvider: { permissionSubject.value },
            mutualFavoritesProvider: { favoritesSubject.value },
            torController: torController,
            relayController: relayController,
            proxyController: proxyController,
            notificationCenter: notificationCenter
        )
        return NetworkActivationTestContext(
            service: service,
            storage: storage,
            permissionSubject: permissionSubject,
            favoritesSubject: favoritesSubject,
            torController: torController,
            relayController: relayController,
            proxyController: proxyController,
            notificationCenter: notificationCenter
        )
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
private struct NetworkActivationTestContext {
    let service: NetworkActivationService
    let storage: UserDefaults
    let permissionSubject: CurrentValueSubject<LocationChannelManager.PermissionState, Never>
    let favoritesSubject: CurrentValueSubject<Set<Data>, Never>
    let torController: MockNetworkActivationTorController
    let relayController: MockNetworkActivationRelayController
    let proxyController: MockNetworkActivationProxyController
    let notificationCenter: NotificationCenter
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
