import Foundation
import Tor
import XCTest
@testable import bitchat

@MainActor
final class GeoRelayDirectoryTests: XCTestCase {
    private func parse(_ csv: String) -> [GeoRelayDirectory.Entry] {
        GeoRelayDirectory.validatedEntries(
            from: Data(csv.utf8),
            policy: .live,
            minimumEntries: 1
        ) ?? []
    }

    func test_parseCSV_normalizesSecureRelaySchemesAndDeduplicatesEntries() {
        let csv = """
        relay url,lat,lon
        wss://one.example/,10,20
        https://one.example,10,20
        wss://one.example:443/,10,20
        two.example,11,21
        wss://two.example:443,11,21
        """

        let parsed = Set(parse(csv))

        XCTAssertEqual(
            parsed,
            Set([
                GeoRelayDirectory.Entry(host: "one.example", lat: 10, lon: 20),
                GeoRelayDirectory.Entry(host: "two.example", lat: 11, lon: 21)
            ])
        )
    }

    func test_parseCSV_rejectsWholeDatasetWhenAnyRowOrHeaderIsUnsafe() {
        let invalidCSVs = [
            "relay,lat,lon\nrelay.example,1,2\n",
            "relay url,lat,lon\nrelay.example,1\n",
            "relay url,lat,lon\nhttp://relay.example,1,2\n",
            "relay url,lat,lon\nwss://user@relay.example,1,2\n",
            "relay url,lat,lon\nwss://relay.example/path,1,2\n",
            "relay url,lat,lon\nwss://relay.example?,1,2\n",
            "relay url,lat,lon\nwss://relay.example#,1,2\n",
            "relay url,lat,lon\nrelay.example:0,1,2\n",
            "relay url,lat,lon\nrelay.example:99999,1,2\n",
            "relay url,lat,lon\nlocalhost,1,2\n",
            "relay url,lat,lon\nr\u{00e9}lay.example,1,2\n",
            "relay url,lat,lon\nrelay\u{202e}.example,1,2\n",
            "relay url,lat,lon\nrelay.example,NaN,2\n",
            "relay url,lat,lon\nrelay.example,1_0,2\n",
            "relay url,lat,lon\nrelay.example,\u{0661}\u{0660},2\n",
            "relay url,lat,lon\nrelay.example,\u{ff11}\u{ff10},2\n",
            "relay url,lat,lon\nrelay.example,91,2\n",
            "relay url,lat,lon\nrelay.example,1,181\n",
            "relay url,lat,lon\nrelay.example,1,2\nrelay.example,3,4\n"
        ]

        for csv in invalidCSVs {
            XCTAssertTrue(parse(csv).isEmpty, csv)
        }
    }

    func test_validatedEntries_enforcesByteRowEntryAndRetentionLimits() {
        let restrictive = GeoRelayDirectoryValidationPolicy(
            maximumBytes: 100,
            maximumRows: 2,
            maximumEntries: 2,
            minimumRemoteEntries: 1,
            minimumRetainedFraction: 0.5
        )
        let one = Data("relay url,lat,lon\none.example,1,2\n".utf8)
        let three = Data("relay url,lat,lon\none.example,1,2\ntwo.example,3,4\nthree.example,5,6\n".utf8)

        XCTAssertNil(GeoRelayDirectory.validatedEntries(
            from: one,
            policy: restrictive,
            minimumEntries: 2
        ))
        XCTAssertNil(GeoRelayDirectory.validatedEntries(
            from: Data(repeating: 0x41, count: 101),
            policy: restrictive,
            minimumEntries: 1
        ))
        XCTAssertNil(GeoRelayDirectory.validatedEntries(
            from: three,
            policy: restrictive,
            minimumEntries: 1
        ))
    }

    func test_validatedEntries_requiresExactBaselineEntryOverlap() throws {
        let policy = GeoRelayDirectoryValidationPolicy(
            maximumBytes: 1_000,
            maximumRows: 10,
            maximumEntries: 10,
            minimumRemoteEntries: 1,
            minimumRetainedFraction: 0.5
        )
        let baseline = Set(try XCTUnwrap(GeoRelayDirectory.validatedEntries(
            from: Data("""
            relay url,lat,lon
            one.example,1,1
            two.example,2,2
            three.example,3,3
            """.utf8),
            policy: policy,
            minimumEntries: 1
        )))
        let disjoint = Data("""
        relay url,lat,lon
        four.example,1,1
        five.example,2,2
        six.example,3,3
        """.utf8)
        let rewrittenCoordinates = Data("""
        relay url,lat,lon
        one.example,11,11
        two.example,12,12
        three.example,13,13
        """.utf8)
        let halfRetained = Data("""
        relay url,lat,lon
        wss://one.example:443/,1,1
        https://two.example/,2,2
        replacement.example,4,4
        """.utf8)

        XCTAssertNil(GeoRelayDirectory.validatedEntries(
            from: disjoint,
            policy: policy,
            minimumEntries: 1,
            baselineEntries: baseline
        ))
        XCTAssertNil(GeoRelayDirectory.validatedEntries(
            from: rewrittenCoordinates,
            policy: policy,
            minimumEntries: 1,
            baselineEntries: baseline
        ))
        XCTAssertNotNil(GeoRelayDirectory.validatedEntries(
            from: halfRetained,
            policy: policy,
            minimumEntries: 1,
            baselineEntries: baseline
        ))
    }

    func test_bundledReviewedCSV_passesStrictProductionValidation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("relays/online_relays_gps.csv")
        )

        let entries = try XCTUnwrap(GeoRelayDirectory.validatedEntries(
            from: data,
            policy: .live,
            minimumEntries: GeoRelayDirectoryValidationPolicy.live.minimumRemoteEntries
        ))
        XCTAssertGreaterThan(entries.count, 250)
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

    func test_closestRelays_breaksDistanceTiesDeterministicallyByHost() {
        // Same coordinates for all entries: selection must still be stable so
        // publishers and subscribers using the same directory agree on relays.
        let harness = makeHarness(
            cacheCSV: """
            relay url,lat,lon
            zeta.example,10,10
            alpha.example,10,10
            mike.example,10,10
            """
        )
        let directory = GeoRelayDirectory(dependencies: harness.dependencies)

        XCTAssertEqual(
            directory.closestRelays(toLat: 10, lon: 10, count: 2),
            ["wss://alpha.example", "wss://mike.example"]
        )
    }

    func test_fetchSuccess_postsDirectoryRefreshNotification() async {
        let harness = makeHarness(fetchCSV: """
        relay url,lat,lon
        notify.example,1,2
        """)
        let directory = GeoRelayDirectory(dependencies: harness.dependencies)

        var notified = 0
        let observer = harness.notificationCenter.addObserver(
            forName: .geoRelayDirectoryDidRefresh,
            object: nil,
            queue: .main
        ) { _ in
            notified += 1
        }
        defer { harness.notificationCenter.removeObserver(observer) }

        directory.prefetchIfNeeded()
        let refreshed = await waitUntil { notified == 1 }
        XCTAssertTrue(refreshed)
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

    func test_prefetchIfNeeded_rejectsSharpValidLookingTruncationBeforeCaching() async {
        let cached = """
        relay url,lat,lon
        old-one.example,1,1
        old-two.example,2,2
        old-three.example,3,3
        """
        let truncated = """
        relay url,lat,lon
        attacker.example,9,9
        """
        let recovered = """
        relay url,lat,lon
        old-one.example,1,1
        old-two.example,2,2
        new-three.example,6,6
        """
        let harness = makeHarness(
            cacheCSV: cached,
            fetchResults: [
                .success(Data(truncated.utf8)),
                .success(Data(recovered.utf8))
            ],
            validationPolicy: GeoRelayDirectoryValidationPolicy(
                maximumBytes: 64 * 1024,
                maximumRows: 1_000,
                maximumEntries: 1_000,
                minimumRemoteEntries: 1,
                minimumRetainedFraction: 0.5
            )
        )
        let directory = GeoRelayDirectory(dependencies: harness.dependencies)

        directory.prefetchIfNeeded()

        let refreshed = await waitUntil {
            directory.entries.contains(where: { $0.host == "new-three.example" })
        }
        XCTAssertTrue(refreshed)
        XCTAssertFalse(directory.entries.contains(where: { $0.host == "attacker.example" }))
        let requestCount = await harness.fetcher.recordedRequestCount()
        let retryDelays = await harness.retryRecorder.recordedDelays()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(retryDelays, [5])
        XCTAssertEqual(harness.fileStore.dataByURL[harness.cacheURL], Data(recovered.utf8))
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
        activeNotificationName: Notification.Name? = nil,
        validationPolicy: GeoRelayDirectoryValidationPolicy = GeoRelayDirectoryValidationPolicy(
            maximumBytes: 64 * 1024,
            maximumRows: 1_000,
            maximumEntries: 1_000,
            minimumRemoteEntries: 1,
            minimumRetainedFraction: 0
        )
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
            autoStart: autoStart,
            validationPolicy: validationPolicy
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
