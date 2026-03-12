import Combine
import XCTest
@testable import bitchat

@MainActor
final class GeohashPresenceServiceTests: XCTestCase {
    func test_start_schedulesHeartbeatUsingConfiguredInterval() {
        let scheduler = MockGeohashPresenceScheduler()
        let service = makeService(scheduler: scheduler, loopMinInterval: 42, loopMaxInterval: 42)

        service.start()

        XCTAssertEqual(scheduler.intervals, [42])
    }

    func test_handleLocationChange_invalidatesExistingTimerAndSchedulesQuickRefresh() {
        let scheduler = MockGeohashPresenceScheduler()
        let service = makeService(scheduler: scheduler, loopMinInterval: 40, loopMaxInterval: 40)

        service.start()
        let originalTimer = scheduler.timers.first

        service.handleLocationChange()

        XCTAssertEqual(scheduler.intervals, [40, 5])
        XCTAssertEqual(originalTimer?.invalidateCallCount, 1)
    }

    func test_handleConnectivityChange_onlySchedulesWhenExistingTimerIsMissingOrInvalid() {
        let scheduler = MockGeohashPresenceScheduler()
        let service = makeService(scheduler: scheduler, loopMinInterval: 33, loopMaxInterval: 33)

        service.start()
        service.handleConnectivityChange()
        XCTAssertEqual(scheduler.intervals, [33])

        scheduler.timers.last?.invalidate()
        service.handleConnectivityChange()
        XCTAssertEqual(scheduler.intervals, [33, 33])
    }

    func test_performHeartbeat_broadcastsOnlyAllowedPrecisionChannels() async throws {
        let identity = try NostrIdentity.generate()
        let scheduler = MockGeohashPresenceScheduler()
        var sentGeohashes: [String] = []
        var lookedUpGeohashes: [String] = []
        var sleptNanoseconds: [UInt64] = []
        let channels = [
            GeohashChannel(level: .region, geohash: "9q"),
            GeohashChannel(level: .province, geohash: "9q8y"),
            GeohashChannel(level: .city, geohash: "9q8yy"),
            GeohashChannel(level: .neighborhood, geohash: "9q8yyk"),
            GeohashChannel(level: .block, geohash: "9q8yyk8"),
            GeohashChannel(level: .building, geohash: "9q8yyk8y")
        ]
        let service = makeService(
            scheduler: scheduler,
            availableChannels: channels,
            deriveIdentity: { _ in identity },
            relayLookup: { geohash, _ in
                lookedUpGeohashes.append(geohash)
                return ["wss://\(geohash).example"]
            },
            relaySender: { event, _ in
                let geohash = event.tags.first(where: { $0.first == "g" })?[1]
                if let geohash {
                    sentGeohashes.append(geohash)
                }
            },
            sleeper: { nanoseconds in
                sleptNanoseconds.append(nanoseconds)
            },
            loopMinInterval: 17,
            loopMaxInterval: 17,
            burstMinDelay: 0,
            burstMaxDelay: 0
        )

        service.performHeartbeat()

        let sentAllAllowedChannels = await waitUntil { sentGeohashes.count == 3 }
        XCTAssertTrue(sentAllAllowedChannels)
        XCTAssertEqual(Set(sentGeohashes), Set(["9q", "9q8y", "9q8yy"]))
        XCTAssertEqual(Set(lookedUpGeohashes), Set(["9q", "9q8y", "9q8yy"]))
        XCTAssertEqual(sleptNanoseconds.count, 3)
        XCTAssertEqual(scheduler.intervals, [17])
    }

    func test_performHeartbeat_skipsBroadcastWhenTorIsNotReady() async {
        let scheduler = MockGeohashPresenceScheduler()
        var sendCount = 0
        let service = makeService(
            scheduler: scheduler,
            torIsReady: { false },
            relaySender: { _, _ in sendCount += 1 },
            loopMinInterval: 21,
            loopMaxInterval: 21
        )

        service.performHeartbeat()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(scheduler.intervals, [21])
    }

    func test_performHeartbeat_skipsBroadcastWhenAppIsBackgrounded() async {
        let scheduler = MockGeohashPresenceScheduler()
        var sendCount = 0
        let service = makeService(
            scheduler: scheduler,
            torIsForeground: { false },
            relaySender: { _, _ in sendCount += 1 },
            loopMinInterval: 22,
            loopMaxInterval: 22
        )

        service.performHeartbeat()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(scheduler.intervals, [22])
    }

    func test_broadcastPresence_skipsSendWhenNoRelaysAreAvailable() async throws {
        let identity = try NostrIdentity.generate()
        var sendCount = 0
        let service = makeService(
            scheduler: MockGeohashPresenceScheduler(),
            deriveIdentity: { _ in identity },
            relayLookup: { _, _ in [] },
            relaySender: { _, _ in sendCount += 1 }
        )

        service.broadcastPresence(for: "9q8yy")
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(sendCount, 0)
    }

    func test_broadcastPresence_skipsSendWhenIdentityDerivationFails() async {
        enum PresenceError: Error { case failed }

        var sendCount = 0
        let service = makeService(
            scheduler: MockGeohashPresenceScheduler(),
            deriveIdentity: { _ in throw PresenceError.failed },
            relaySender: { _, _ in sendCount += 1 }
        )

        service.broadcastPresence(for: "9q8yy")
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(sendCount, 0)
    }

    private func makeService(
        scheduler: MockGeohashPresenceScheduler,
        availableChannels: [GeohashChannel] = [
            GeohashChannel(level: .city, geohash: "9q8yy")
        ],
        torIsReady: @escaping () -> Bool = { true },
        torIsForeground: @escaping () -> Bool = { true },
        deriveIdentity: @escaping (String) throws -> NostrIdentity = { _ in try NostrIdentity.generate() },
        relayLookup: @escaping (String, Int) -> [String] = { geohash, _ in ["wss://\(geohash).example"] },
        relaySender: @escaping (NostrEvent, [String]) -> Void = { _, _ in },
        sleeper: @escaping (UInt64) async -> Void = { _ in },
        loopMinInterval: TimeInterval = 40,
        loopMaxInterval: TimeInterval = 40,
        burstMinDelay: TimeInterval = 0,
        burstMaxDelay: TimeInterval = 0
    ) -> GeohashPresenceService {
        let locationSubject = PassthroughSubject<[GeohashChannel], Never>()
        let torReadySubject = PassthroughSubject<Void, Never>()
        return GeohashPresenceService(
            availableChannelsProvider: { availableChannels },
            locationChanges: locationSubject.eraseToAnyPublisher(),
            torReadyPublisher: torReadySubject.eraseToAnyPublisher(),
            torIsReady: torIsReady,
            torIsForeground: torIsForeground,
            deriveIdentity: deriveIdentity,
            relayLookup: relayLookup,
            relaySender: relaySender,
            sleeper: sleeper,
            scheduleTimer: scheduler.schedule(interval:handler:),
            loopMinInterval: loopMinInterval,
            loopMaxInterval: loopMaxInterval,
            burstMinDelay: burstMinDelay,
            burstMaxDelay: burstMaxDelay
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

private final class MockGeohashPresenceScheduler {
    private(set) var intervals: [TimeInterval] = []
    private(set) var timers: [MockGeohashPresenceTimer] = []

    func schedule(interval: TimeInterval, handler: @escaping () -> Void) -> GeohashPresenceTimerProtocol {
        intervals.append(interval)
        let timer = MockGeohashPresenceTimer(handler: handler)
        timers.append(timer)
        return timer
    }
}

private final class MockGeohashPresenceTimer: GeohashPresenceTimerProtocol {
    private let handler: () -> Void
    private(set) var isValid = true
    private(set) var invalidateCallCount = 0

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func invalidate() {
        invalidateCallCount += 1
        isValid = false
    }

    func fire() {
        handler()
    }
}
