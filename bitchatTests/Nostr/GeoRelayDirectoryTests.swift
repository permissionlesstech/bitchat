import Foundation
import Tor
import XCTest
@testable import bitchat

@MainActor
final class GeoRelayDirectoryTests: XCTestCase {
    func test_parseCSV_normalizesRelaySchemesAndDeduplicatesEntries() {
        let csv = """
        relay url,lat,lon
        wss://one.example/,10,20
        https://one.example,10,20
        http://two.example/,11,21
        invalid row
        ws://three.example,not-a-lat,22
        """

        let parsed = Set(GeoRelayDirectory.parseCSV(csv))

        XCTAssertEqual(
            parsed,
            Set([
                GeoRelayDirectory.Entry(host: "one.example", lat: 10, lon: 20),
                GeoRelayDirectory.Entry(host: "two.example", lat: 11, lon: 21)
            ])
        )
    }

    func test_closestRelays_sortsByDistanceForLatLonAndGeohash() {
        let harness = makeHarness(
            cacheCSV: """
            relay url,lat,lon
            close.example,37.7749,-122.4194
            medium.example,34.0522,-118.2437
            far.example,40.7128,-74.0060
            """
        )
        let directory = GeoRelayDirectory(dependencies: harness.dependencies)

        XCTAssertEqual(
            directory.closestRelays(toLat: 37.78, lon: -122.41, count: 2),
            ["wss://close.example", "wss://medium.example"]
        )
        XCTAssertEqual(
            directory.closestRelays(toLat: 37.78, lon: -122.41, count: 10),
            ["wss://close.example", "wss://medium.example", "wss://far.example"]
        )

        let geohash = Geohash.encode(latitude: 37.78, longitude: -122.41, precision: 6)
        XCTAssertEqual(
            directory.closestRelays(toGeohash: geohash, count: 2),
            ["wss://close.example", "wss://medium.example"]
        )
    }

    func test_loadLocalEntries_prefersCacheThenBundleThenWorkingDirectory() {
        let cacheHarness = makeHarness(
            cacheCSV: """
            relay url,lat,lon
            cache.example,1,1
            """,
            bundleCSV: """
            relay url,lat,lon
            bundle.example,2,2
            """,
            workingDirectoryCSV: """
            relay url,lat,lon
            cwd.example,3,3
            """
        )
        XCTAssertEqual(
            GeoRelayDirectory(dependencies: cacheHarness.dependencies).entries,
            [GeoRelayDirectory.Entry(host: "cache.example", lat: 1, lon: 1)]
        )

        let bundleHarness = makeHarness(
            cacheCSV: "invalid",
            bundleCSV: """
            relay url,lat,lon
            bundle.example,2,2
            """,
            workingDirectoryCSV: """
            relay url,lat,lon
            cwd.example,3,3
            """
        )
        XCTAssertEqual(
            GeoRelayDirectory(dependencies: bundleHarness.dependencies).entries,
            [GeoRelayDirectory.Entry(host: "bundle.example", lat: 2, lon: 2)]
        )

        let cwdHarness = makeHarness(
            cacheCSV: nil,
            bundleCSV: "invalid",
            workingDirectoryCSV: """
            relay url,lat,lon
            cwd.example,3,3
            """
        )
        XCTAssertEqual(
            GeoRelayDirectory(dependencies: cwdHarness.dependencies).entries,
            [GeoRelayDirectory.Entry(host: "cwd.example", lat: 3, lon: 3)]
        )
    }

    func test_prefetchIfNeeded_skipsWhenFetchIntervalHasNotElapsed() async {
        let harness = makeHarness(fetchCSV: """
        relay url,lat,lon
        one.example,1,1
        """)
        harness.userDefaults.set(harness.clock.now, forKey: "georelay.lastFetchAt")
        let directory = GeoRelayDirectory(dependencies: harness.dependencies)

        directory.prefetchIfNeeded()
        try? await Task.sleep(nanoseconds: 20_000_000)

        let requestCount = await harness.fetcher.recordedRequestCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertFalse(directory.debugHasRetryTask)
    }

    func test_prefetchIfNeeded_successUpdatesEntriesPersistsCacheAndSkipsImmediateForcedRefetch() async {
        let csv = """
        relay url,lat,lon
        refreshed.example,12,34
        """
        let harness = makeHarness(fetchCSV: csv)
        let directory = GeoRelayDirectory(dependencies: harness.dependencies)

        directory.prefetchIfNeeded()
        let refreshed = await waitUntil {
            directory.entries == [GeoRelayDirectory.Entry(host: "refreshed.example", lat: 12, lon: 34)]
        }
        XCTAssertTrue(refreshed)
        let requestCount = await harness.fetcher.recordedRequestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(harness.fileStore.dataByURL[harness.cacheURL], csv.data(using: .utf8))
        XCTAssertEqual(harness.userDefaults.object(forKey: "georelay.lastFetchAt") as? Date, harness.clock.now)
        XCTAssertEqual(directory.debugRetryAttempt, 0)
        XCTAssertFalse(directory.debugHasRetryTask)

        directory.prefetchIfNeeded(force: true)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let forcedRequestCount = await harness.fetcher.recordedRequestCount()
        XCTAssertEqual(forcedRequestCount, 1)
    }

    func test_prefetchIfNeeded_runsRemoteFetchOffMainThread() async {
        var factoryThreadFlags: [Bool] = []
        let threadRecorder = MainThreadRecorder()
        let harness = makeHarness(
            fetchCSV: """
            relay url,lat,lon
            background.example,8,9
            """,
            fetchFactoryObserver: {
                factoryThreadFlags.append(isExecutingOnMainThread())
            },
            fetchObserver: {
                await threadRecorder.record(isExecutingOnMainThread())
            }
        )
        let directory = GeoRelayDirectory(dependencies: harness.dependencies)

        directory.prefetchIfNeeded()

        let refreshed = await waitUntil {
            directory.entries == [GeoRelayDirectory.Entry(host: "background.example", lat: 8, lon: 9)]
        }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(factoryThreadFlags, [true])
        let recordedValues = await threadRecorder.recordedValues()
        XCTAssertEqual(recordedValues, [false])
    }

    func test_prefetchIfNeeded_failureSchedulesRetryAndRecoversOnNextFetch() async {
        let csv = """
        relay url,lat,lon
        retry.example,5,6
        """
        let harness = makeHarness(
            fetchResults: [
                .failure(GeoRelayTestError.network),
                .success(csv.data(using: .utf8)!)
            ]
        )
        let directory = GeoRelayDirectory(dependencies: harness.dependencies)

        directory.prefetchIfNeeded()

        let recovered = await waitUntil {
            directory.entries == [GeoRelayDirectory.Entry(host: "retry.example", lat: 5, lon: 6)]
        }
        XCTAssertTrue(recovered)
        let requestCount = await harness.fetcher.recordedRequestCount()
        let retryDelays = await harness.retryRecorder.recordedDelays()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(retryDelays, [5])
        XCTAssertEqual(directory.debugRetryAttempt, 0)
        XCTAssertFalse(directory.debugHasRetryTask)
    }

    func test_observers_triggerPrefetchesForTorReadyAndAppActivation() async {
        let activeNotification = Notification.Name("GeoRelayDirectoryTests.didBecomeActive")
        let harness = makeHarness(
            fetchCSV: """
            relay url,lat,lon
            observer.example,1,2
            """,
            autoStart: true,
            activeNotificationName: activeNotification
        )
        var directory: GeoRelayDirectory? = GeoRelayDirectory(dependencies: harness.dependencies)
        let initialFetch = await waitUntil {
            await harness.fetcher.recordedRequestCount() == 1
        }
        XCTAssertTrue(initialFetch)
        XCTAssertEqual(directory?.debugObserverCount, 2)

        harness.clock.now = harness.clock.now.addingTimeInterval(6)
        harness.notificationCenter.post(name: .TorDidBecomeReady, object: nil)
        let torTriggered = await waitUntil {
            await harness.fetcher.recordedRequestCount() == 2
        }
        XCTAssertTrue(torTriggered)

        harness.clock.now = harness.clock.now.addingTimeInterval(61)
        harness.notificationCenter.post(name: activeNotification, object: nil)
        let activeTriggered = await waitUntil {
            await harness.fetcher.recordedRequestCount() == 3
        }
        XCTAssertTrue(activeTriggered)

        weak var weakDirectory: GeoRelayDirectory?
        weakDirectory = directory
        directory = nil
        XCTAssertNil(weakDirectory)
    }

    private func makeHarness(
        cacheCSV: String? = nil,
        bundleCSV: String? = nil,
        workingDirectoryCSV: String? = nil,
        fetchCSV: String? = nil,
        fetchResults: [Result<Data, Error>] = [],
        fetchFactoryObserver: (@MainActor @Sendable () -> Void)? = nil,
        fetchObserver: (@Sendable () async -> Void)? = nil,
        autoStart: Bool = false,
        activeNotificationName: Notification.Name? = nil
    ) -> GeoRelayHarness {
        let userDefaultsSuite = "GeoRelayDirectoryTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuite)!
        userDefaults.removePersistentDomain(forName: userDefaultsSuite)

        let notificationCenter = NotificationCenter()
        let clock = MutableGeoClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let fileStore = InMemoryFileStore()
        let cacheURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-cache.csv")
        let bundleURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-bundle.csv")
        let cwd = "/tmp/\(UUID().uuidString)-cwd"
        let cwdURL = URL(fileURLWithPath: cwd).appendingPathComponent("relays/online_relays_gps.csv")

        if let cacheCSV {
            fileStore.dataByURL[cacheURL] = Data(cacheCSV.utf8)
        }
        if let bundleCSV {
            fileStore.dataByURL[bundleURL] = Data(bundleCSV.utf8)
        }
        if let workingDirectoryCSV {
            fileStore.dataByURL[cwdURL] = Data(workingDirectoryCSV.utf8)
        }

        let defaultFetchData = Data((fetchCSV ?? bundleCSV ?? cacheCSV ?? "relay url,lat,lon\nfallback.example,0,0\n").utf8)
        let fetcher = FetchProbe(responses: fetchResults, defaultData: defaultFetchData)
        let retryRecorder = RetryDelayRecorder()

        let dependencies = GeoRelayDirectoryDependencies(
            userDefaults: userDefaults,
            notificationCenter: notificationCenter,
            now: { clock.now },
            remoteURL: URL(string: "https://example.com/nostr_relays.csv")!,
            fetchInterval: 60,
            refreshCheckInterval: 0,
            retryInitialSeconds: 5,
            retryMaxSeconds: 40,
            awaitTorReady: { true },
            makeFetchData: {
                fetchFactoryObserver?()
                return { request in
                    await fetchObserver?()
                    return try await fetcher.fetch(request)
                }
            },
            readData: { url in
                fileStore.dataByURL[url]
            },
            writeData: { data, url in
                fileStore.dataByURL[url] = data
            },
            cacheURL: { cacheURL },
            bundledCSVURLs: bundleCSV == nil ? { [] } : { [bundleURL] },
            currentDirectoryPath: workingDirectoryCSV == nil ? { nil } : { cwd },
            retrySleep: { delay in
                await retryRecorder.record(delay)
            },
            activeNotificationName: activeNotificationName,
            autoStart: autoStart
        )

        return GeoRelayHarness(
            dependencies: dependencies,
            clock: clock,
            fileStore: fileStore,
            fetcher: fetcher,
            retryRecorder: retryRecorder,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter,
            cacheURL: cacheURL
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}

private struct GeoRelayHarness {
    let dependencies: GeoRelayDirectoryDependencies
    let clock: MutableGeoClock
    let fileStore: InMemoryFileStore
    let fetcher: FetchProbe
    let retryRecorder: RetryDelayRecorder
    let userDefaults: UserDefaults
    let notificationCenter: NotificationCenter
    let cacheURL: URL
}

private final class MutableGeoClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private final class InMemoryFileStore {
    var dataByURL: [URL: Data] = [:]
}

private actor FetchProbe {
    private var responses: [Result<Data, Error>]
    private let defaultData: Data
    private(set) var requestCount = 0

    init(responses: [Result<Data, Error>], defaultData: Data) {
        self.responses = responses
        self.defaultData = defaultData
    }

    func fetch(_ request: URLRequest) async throws -> Data {
        _ = request
        requestCount += 1
        if !responses.isEmpty {
            return try responses.removeFirst().get()
        }
        return defaultData
    }

    func recordedRequestCount() -> Int {
        requestCount
    }
}

private actor RetryDelayRecorder {
    private(set) var delays: [TimeInterval] = []

    func record(_ delay: TimeInterval) {
        delays.append(delay)
    }

    func recordedDelays() -> [TimeInterval] {
        delays
    }
}

private actor MainThreadRecorder {
    private var values: [Bool] = []

    func record(_ value: Bool) {
        values.append(value)
    }

    func recordedValues() -> [Bool] {
        values
    }
}

private enum GeoRelayTestError: Error {
    case network
}

private func isExecutingOnMainThread() -> Bool {
    Thread.isMainThread
}
