import Combine
import XCTest
@testable import bitchat

/// Covers the reachability-gate decision logic (pure debounce) and the
/// `NetworkActivationService` wiring that suppresses Tor/relay startup when
/// there is provably no network.
@MainActor
final class NetworkReachabilityGateTests: XCTestCase {

    // MARK: - Pure debounce logic

    func test_debounce_satisfiedStaysReachable() {
        var d = ReachabilityDebounce(interval: 2.5, initial: true)
        let t0 = Date()
        // An interface remains present: no change, no pending.
        XCTAssertNil(d.observe(reachable: true, at: t0))
        XCTAssertTrue(d.committed)
        XCTAssertFalse(d.hasPendingChange)
    }

    func test_debounce_unsatisfiedSuppressesAfterInterval() {
        var d = ReachabilityDebounce(interval: 2.5, initial: true)
        let t0 = Date()
        // Path drops: not committed immediately (within debounce window).
        XCTAssertNil(d.observe(reachable: false, at: t0))
        XCTAssertTrue(d.committed)
        XCTAssertTrue(d.hasPendingChange)
        // Still within window.
        XCTAssertNil(d.flush(at: t0.addingTimeInterval(1.0)))
        XCTAssertTrue(d.committed)
        // Past the window: commit unreachable.
        XCTAssertEqual(d.flush(at: t0.addingTimeInterval(2.5)), false)
        XCTAssertFalse(d.committed)
        XCTAssertFalse(d.hasPendingChange)
    }

    func test_debounce_flapIsIgnored() {
        var d = ReachabilityDebounce(interval: 2.5, initial: true)
        let t0 = Date()
        // Drop then recover well within the window — must never commit a change.
        XCTAssertNil(d.observe(reachable: false, at: t0))
        XCTAssertTrue(d.hasPendingChange)
        XCTAssertNil(d.observe(reachable: true, at: t0.addingTimeInterval(0.5)))
        XCTAssertFalse(d.hasPendingChange, "recovery should cancel the pending drop")
        // A late flush after the original deadline is a no-op (nothing pending).
        XCTAssertNil(d.flush(at: t0.addingTimeInterval(3.0)))
        XCTAssertTrue(d.committed)
    }

    func test_debounce_recoverAfterOutageCommitsAfterInterval() {
        var d = ReachabilityDebounce(interval: 2.5, initial: false)
        let t0 = Date()
        XCTAssertNil(d.observe(reachable: true, at: t0))
        XCTAssertTrue(d.hasPendingChange)
        XCTAssertEqual(d.flush(at: t0.addingTimeInterval(2.5)), true)
        XCTAssertTrue(d.committed)
    }

    func test_debounce_duplicateObservationsPreservePendingDeadline() {
        var d = ReachabilityDebounce(interval: 2.5, initial: true)
        let t0 = Date()
        XCTAssertNil(d.observe(reachable: false, at: t0))
        // Duplicate unsatisfied updates mid-window keep the original deadline.
        XCTAssertNil(d.observe(reachable: false, at: t0.addingTimeInterval(1.0)))
        XCTAssertEqual(d.pendingRemaining(at: t0.addingTimeInterval(1.0)), 1.5)
        // A duplicate arriving past the deadline commits immediately.
        XCTAssertEqual(d.observe(reachable: false, at: t0.addingTimeInterval(2.5)), false)
        XCTAssertNil(d.pendingRemaining(at: t0.addingTimeInterval(2.5)))
    }

    func test_monitor_duplicateUpdatesDoNotPostponeOfflineCommit() async {
        let monitor = NWPathReachabilityMonitor(debounceInterval: 1.0)
        var received: [Bool] = []
        let cancellable = monitor.reachabilityPublisher.sink { received.append($0) }
        defer { cancellable.cancel() }

        let start = Date()
        monitor.ingest(reachable: false)
        try? await Task.sleep(nanoseconds: 500_000_000)
        // Duplicate unsatisfied update mid-window (e.g. interface detail change
        // while still offline) must not restart the debounce window.
        monitor.ingest(reachable: false)

        let committed = await waitUntil(timeout: 2.0) { !received.isEmpty }
        XCTAssertTrue(committed)
        XCTAssertEqual(received, [false])
        // The flush must fire at the original ~1.0s deadline, not ~1.5s
        // (a full interval after the duplicate).
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.4)
    }

    // MARK: - Service gating

    func test_start_whenUnreachable_suppressesTorAndRelays() {
        let ctx = makeService(permission: .authorized, reachable: false)
        ctx.service.start()

        XCTAssertFalse(ctx.service.activationAllowed)
        XCTAssertFalse(ctx.service.isNetworkReachable)
        XCTAssertTrue(ctx.reachability.startCalled)
        XCTAssertEqual(ctx.torController.startIfNeededCallCount, 0)
        XCTAssertEqual(ctx.torController.autoStartAllowedValues, [false])
        XCTAssertEqual(ctx.relayController.connectCallCount, 0)
        XCTAssertEqual(ctx.relayController.disconnectCallCount, 1)
    }

    func test_start_whenReachable_allowsTorAndRelays() {
        let ctx = makeService(permission: .authorized, reachable: true)
        ctx.service.start()

        XCTAssertTrue(ctx.service.activationAllowed)
        XCTAssertEqual(ctx.torController.startIfNeededCallCount, 1)
        XCTAssertEqual(ctx.relayController.connectCallCount, 1)
    }

    func test_reachabilityRecovery_resumesTorAndRelays() async {
        let ctx = makeService(permission: .authorized, reachable: false)
        ctx.service.start()
        XCTAssertFalse(ctx.service.activationAllowed)

        ctx.reachability.set(true)
        let resumed = await waitUntil { ctx.service.activationAllowed }
        XCTAssertTrue(resumed)
        XCTAssertTrue(ctx.service.isNetworkReachable)
        XCTAssertGreaterThanOrEqual(ctx.torController.startIfNeededCallCount, 1)
        XCTAssertGreaterThanOrEqual(ctx.relayController.connectCallCount, 1)
    }

    func test_reachabilityLoss_disconnectsRelaysAndStopsTor() async {
        let ctx = makeService(permission: .authorized, reachable: true)
        ctx.service.start()
        XCTAssertTrue(ctx.service.activationAllowed)
        let disconnectsBefore = ctx.relayController.disconnectCallCount

        ctx.reachability.set(false)
        let suppressed = await waitUntil { !ctx.service.activationAllowed }
        XCTAssertTrue(suppressed)
        XCTAssertFalse(ctx.service.isNetworkReachable)
        XCTAssertGreaterThan(ctx.relayController.disconnectCallCount, disconnectsBefore)
        XCTAssertTrue(ctx.torController.autoStartAllowedValues.contains(false))
        XCTAssertGreaterThanOrEqual(ctx.torController.shutdownCompletelyCallCount, 1)
    }

    // MARK: - Harness

    private func makeService(
        permission: LocationChannelManager.PermissionState,
        reachable: Bool
    ) -> Context {
        let suiteName = "NetworkReachabilityGateTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        storage.removePersistentDomain(forName: suiteName)

        let permissionSubject = CurrentValueSubject<LocationChannelManager.PermissionState, Never>(permission)
        let favoritesSubject = CurrentValueSubject<Set<Data>, Never>([])
        let reachability = ControllableReachabilityMonitor(initial: reachable)
        let torController = GateMockTorController()
        let relayController = GateMockRelayController()
        let proxyController = GateMockProxyController()
        let service = NetworkActivationService(
            storage: storage,
            locationPermissionPublisher: permissionSubject.eraseToAnyPublisher(),
            mutualFavoritesPublisher: favoritesSubject.eraseToAnyPublisher(),
            permissionProvider: { permissionSubject.value },
            mutualFavoritesProvider: { favoritesSubject.value },
            reachabilityMonitor: reachability,
            torController: torController,
            relayController: relayController,
            proxyController: proxyController,
            notificationCenter: NotificationCenter()
        )
        return Context(
            service: service,
            reachability: reachability,
            torController: torController,
            relayController: relayController
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

@MainActor
private struct Context {
    let service: NetworkActivationService
    let reachability: ControllableReachabilityMonitor
    let torController: GateMockTorController
    let relayController: GateMockRelayController
}

@MainActor
private final class ControllableReachabilityMonitor: NetworkReachabilityMonitoring {
    private let subject: CurrentValueSubject<Bool, Never>
    private(set) var startCalled = false

    init(initial: Bool) {
        subject = CurrentValueSubject(initial)
    }

    var isReachable: Bool { subject.value }
    var reachabilityPublisher: AnyPublisher<Bool, Never> {
        subject.removeDuplicates().dropFirst().eraseToAnyPublisher()
    }
    func start() { startCalled = true }
    func set(_ reachable: Bool) { subject.send(reachable) }
}

@MainActor
private final class GateMockTorController: NetworkActivationTorControlling {
    private(set) var autoStartAllowedValues: [Bool] = []
    private(set) var startIfNeededCallCount = 0
    private(set) var shutdownCompletelyCallCount = 0
    func setAutoStartAllowed(_ allowed: Bool) { autoStartAllowedValues.append(allowed) }
    func startIfNeeded() { startIfNeededCallCount += 1 }
    func shutdownCompletely() { shutdownCompletelyCallCount += 1 }
}

@MainActor
private final class GateMockRelayController: NetworkActivationRelayControlling {
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    func connect() { connectCallCount += 1 }
    func disconnect() { disconnectCallCount += 1 }
}

private final class GateMockProxyController: NetworkActivationProxyControlling {
    private(set) var proxyModes: [Bool] = []
    func setProxyMode(useTor: Bool) { proxyModes.append(useTor) }
}
