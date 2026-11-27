import BitLogger
import Foundation
import Tor
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension Notification.Name {
    /// Posted after the geo relay directory successfully refreshes its entries.
    static let geoRelayDirectoryDidRefresh = Notification.Name("bitchat.geoRelayDirectoryDidRefresh")
}

/// Directory of online Nostr relays with approximate GPS locations, used for geohash routing.
struct GeoRelayDirectoryDependencies {
    var userDefaults: UserDefaults
    var notificationCenter: NotificationCenter
    var now: () -> Date
    var remoteURL: URL
    var fetchInterval: TimeInterval
    var refreshCheckInterval: TimeInterval
    var retryInitialSeconds: TimeInterval
    var retryMaxSeconds: TimeInterval
    var awaitTorReady: @Sendable () async -> Bool
    var makeFetchData: @MainActor @Sendable () -> (@Sendable (URLRequest) async throws -> Data)
    var readData: (URL) -> Data?
    var writeData: (Data, URL) throws -> Void
    var cacheURL: () -> URL?
    var bundledCSVURLs: () -> [URL]
    var currentDirectoryPath: () -> String?
    var retrySleep: (TimeInterval) async -> Void
    var activeNotificationName: Notification.Name?
    var autoStart: Bool
    var validationPolicy: GeoRelayDirectoryValidationPolicy
    var isNetworkActivationAllowed: @MainActor () -> Bool = { true }
}

struct GeoRelayDirectoryValidationPolicy: Sendable {
    let maximumBytes: Int
    let maximumRows: Int
    let maximumEntries: Int
    let minimumRemoteEntries: Int
    let minimumRetainedFraction: Double

    static let live = GeoRelayDirectoryValidationPolicy(
        maximumBytes: 512 * 1024,
        maximumRows: 5_000,
        maximumEntries: 5_000,
        minimumRemoteEntries: 50,
        minimumRetainedFraction: 0.5
    )
}

private extension GeoRelayDirectoryDependencies {
    @MainActor
    static func live() -> Self {
#if os(iOS)
        let activeNotificationName: Notification.Name? = UIApplication.didBecomeActiveNotification
#elseif os(macOS)
        let activeNotificationName: Notification.Name? = NSApplication.didBecomeActiveNotification
#else
        let activeNotificationName: Notification.Name? = nil
#endif
        let validationPolicy = GeoRelayDirectoryValidationPolicy.live

        return Self(
            userDefaults: .standard,
            notificationCenter: .default,
            now: Date.init,
            // Runtime refreshes only from bitchat's reviewed copy. Upstream
            // georelays/main is imported by a validator-backed pull request,
            // so an upstream mutation cannot immediately retarget clients.
            remoteURL: URL(string: "https://raw.githubusercontent.com/permissionlesstech/bitchat/refs/heads/main/relays/online_relays_gps.csv")!,
            fetchInterval: TransportConfig.geoRelayFetchIntervalSeconds,
            refreshCheckInterval: TransportConfig.geoRelayRefreshCheckIntervalSeconds,
            retryInitialSeconds: TransportConfig.geoRelayRetryInitialSeconds,
            retryMaxSeconds: TransportConfig.geoRelayRetryMaxSeconds,
            // Only wait for Tor when Tor is switched on. With it off, the fetch
            // is meant to go direct through the same unproxied session the relay
            // sockets already use — and `TorManager` has been shut down, so
            // awaiting readiness would spend the whole bootstrap timeout on
            // every refresh and freeze the directory on its cached copy.
            //
            // Deliberately keyed on the preference rather than live readiness:
            // if Tor is wanted but not ready, this must keep returning false so
            // the fetch is skipped instead of silently leaking the IP.
            awaitTorReady: {
                guard NetworkActivationService.persistedTorPreference() else { return true }
                return await TorManager.shared.awaitReady()
            },
            makeFetchData: {
                let session = TorURLSession.shared.session
                let maximumBytes = validationPolicy.maximumBytes
                return { request in
                    try await BoundedHTTPDataReader.fetch(
                        request: request,
                        using: session,
                        maximumBytes: maximumBytes
                    )
                }
            },
            readData: { try? Data(contentsOf: $0) },
            writeData: { data, url in
                try data.write(to: url, options: .atomic)
            },
            cacheURL: {
                do {
                    let base = try FileManager.default.url(
                        for: .applicationSupportDirectory,
                        in: .userDomainMask,
                        appropriateFor: nil,
                        create: true
                    )
                    let dir = base.appendingPathComponent("bitchat", isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    // v2 ignores caches populated from the old direct-upstream
                    // trust path and subjects every load to strict validation.
                    let legacyCache = dir.appendingPathComponent("georelays_cache.csv")
                    try? FileManager.default.removeItem(at: legacyCache)
                    return dir.appendingPathComponent("georelays_cache_v2.csv")
                } catch {
                    return nil
                }
            },
            bundledCSVURLs: {
                [
                    Bundle.main.url(forResource: "nostr_relays", withExtension: "csv"),
                    Bundle.main.url(forResource: "online_relays_gps", withExtension: "csv"),
                    Bundle.main.url(forResource: "online_relays_gps", withExtension: "csv", subdirectory: "relays")
                ].compactMap { $0 }
            },
            currentDirectoryPath: { FileManager.default.currentDirectoryPath },
            retrySleep: { delay in
                let nanoseconds = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            },
            activeNotificationName: activeNotificationName,
            autoStart: true,
            validationPolicy: validationPolicy,
            isNetworkActivationAllowed: { NetworkActivationService.shared.activationAllowed }
        )
    }
}

@MainActor
final class GeoRelayDirectory {
    private final class CleanupState {
        let notificationCenter: NotificationCenter
        var observers: [NSObjectProtocol] = []
        var refreshTimer: Timer?
        var retryTask: Task<Void, Never>?
        var fetchTask: Task<Void, Never>?
        var localLoadTask: Task<Void, Never>?

        init(notificationCenter: NotificationCenter) {
            self.notificationCenter = notificationCenter
        }

        deinit {
            observers.forEach { notificationCenter.removeObserver($0) }
            refreshTimer?.invalidate()
            retryTask?.cancel()
            fetchTask?.cancel()
            localLoadTask?.cancel()
        }
    }

    struct Entry: Hashable, Sendable {
        let host: String
        let lat: Double
        let lon: Double
    }

    private enum DetachedFetchOutcome: Sendable {
        case success(entries: [Entry], csv: Data)
        case torNotReady
        case invalidData
        case network(String)
        case cancelled
    }

    static let shared = GeoRelayDirectory()

    private struct ClosestRelaysCacheKey: Hashable {
        let geohash: String
        let count: Int

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.count == rhs.count && lhs.geohash == rhs.geohash
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(geohash)
            hasher.combine(count)
        }
    }

    private(set) var entries: [Entry] = [] {
        didSet {
            closestRelaysCache.removeAll(keepingCapacity: true)
        }
    }
    private var closestRelaysCache: [ClosestRelaysCacheKey: [String]] = [:]
    private let lastFetchKey = "georelay.lastFetchAt"
    private let dependencies: GeoRelayDirectoryDependencies
    private let cleanupState: CleanupState

    private var didCompleteLocalLoad = false
    private var retryAttempt: Int = 0
    private var isFetching: Bool = false
    /// Incremented on panic wipe so any in-flight remote fetch cannot write
    /// `georelays_cache_v2.csv`, `georelay.lastFetchAt`, or re-arm `retryTask`
    /// after `resetForPanic()` runs.
    private var panicGeneration: UInt64 = 0

    private init() {
        self.dependencies = .live()
        self.cleanupState = CleanupState(notificationCenter: dependencies.notificationCenter)
        startAsyncLocalLoad()
        if dependencies.autoStart {
            registerObservers()
            startRefreshTimer()
            prefetchIfNeeded()
        }
    }

    internal init(dependencies: GeoRelayDirectoryDependencies) {
        self.dependencies = dependencies
        self.cleanupState = CleanupState(notificationCenter: dependencies.notificationCenter)
        entries = loadLocalEntries()
        didCompleteLocalLoad = true
        if dependencies.autoStart {
            registerObservers()
            startRefreshTimer()
            prefetchIfNeeded()
        }
    }

    private func startAsyncLocalLoad() {
        let cacheURL = dependencies.cacheURL()
        let bundleURLs = dependencies.bundledCSVURLs()
        let cwd = dependencies.currentDirectoryPath()
        let policy = dependencies.validationPolicy

        cleanupState.localLoadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                Self.loadLocalEntriesOffMain(
                    cacheURL: cacheURL,
                    bundleURLs: bundleURLs,
                    currentDirectoryPath: cwd,
                    policy: policy
                )
            }.value
            guard !Task.isCancelled, let self else { return }
            self.cleanupState.localLoadTask = nil
            self.didCompleteLocalLoad = true
            if self.entries.isEmpty && !loaded.isEmpty {
                self.entries = loaded
                self.dependencies.notificationCenter.post(name: .geoRelayDirectoryDidRefresh, object: nil)
            }
        }
    }

    private func ensureLocalEntriesLoaded() {
        guard !didCompleteLocalLoad else { return }
        cleanupState.localLoadTask?.cancel()
        cleanupState.localLoadTask = nil
        didCompleteLocalLoad = true
        if entries.isEmpty {
            entries = loadLocalEntries()
        }
    }

    /// Returns up to `count` relay URLs (wss://) closest to the geohash center.
    func closestRelays(toGeohash geohash: String, count: Int = 5) -> [String] {
        if entries.isEmpty && !didCompleteLocalLoad {
            ensureLocalEntriesLoaded()
        }
        guard !entries.isEmpty, count > 0 else { return [] }
        let key = ClosestRelaysCacheKey(geohash: geohash, count: count)
        if let cached = closestRelaysCache[key] {
            return cached
        }
        let center = Geohash.decodeCenter(geohash)
        let result = closestRelays(toLat: center.lat, lon: center.lon, count: count)
        if closestRelaysCache.count >= 64 {
            closestRelaysCache.removeAll(keepingCapacity: true)
        }
        closestRelaysCache[key] = result
        return result
    }

    /// Returns up to `count` relay URLs (wss://) closest to the given coordinate.
    /// Ties break by host so every device with the same directory picks the
    /// same relay set — publishers and subscribers must agree on relays.
    func closestRelays(toLat lat: Double, lon: Double, count: Int = 5) -> [String] {
        if entries.isEmpty && !didCompleteLocalLoad {
            ensureLocalEntriesLoaded()
        }
        guard !entries.isEmpty, count > 0 else { return [] }

        let rad = Double.pi / 180.0
        let lat1Rad = lat * rad
        let cosLat1 = cos(lat1Rad)

        // Haversine distance is strictly monotonic in `a`, so ranking by `a`
        // preserves exact order while avoiding `sqrt` + `atan2` for every relay.
        return entries
            .map { entry -> (entry: Entry, score: Double) in
                let dLat = (entry.lat - lat) * rad * 0.5
                let dLon = (entry.lon - lon) * rad * 0.5
                let sinDLat = sin(dLat)
                let sinDLon = sin(dLon)
                let score = sinDLat * sinDLat + cosLat1 * cos(entry.lat * rad) * sinDLon * sinDLon
                return (entry: entry, score: score)
            }
            .sorted { ($0.score, $0.entry.host) < ($1.score, $1.entry.host) }
            .prefix(count)
            .map { "wss://\($0.entry.host)" }
    }

    // MARK: - Remote Fetch
    func prefetchIfNeeded(force: Bool = false) {
        guard !isFetching else { return }
        guard dependencies.isNetworkActivationAllowed() else { return }

        let now = dependencies.now()
        let last = dependencies.userDefaults.object(forKey: lastFetchKey) as? Date ?? .distantPast

        if !force {
            guard now.timeIntervalSince(last) >= dependencies.fetchInterval else { return }
        } else if last != .distantPast,
                  now.timeIntervalSince(last) < dependencies.retryInitialSeconds {
            // Skip forced fetches if we just refreshed moments ago.
            return
        }

        cancelRetry()
        fetchRemote()
    }

    private func fetchRemote() {
        guard !isFetching else { return }
        isFetching = true
        let generation = panicGeneration

        let request = URLRequest(
            url: dependencies.remoteURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        let awaitTorReady = dependencies.awaitTorReady
        let isNetworkActivationAllowed = dependencies.isNetworkActivationAllowed
        let makeFetchData = dependencies.makeFetchData
        let validationPolicy = dependencies.validationPolicy
        let baselineEntries = Set(entries)

        cleanupState.fetchTask?.cancel()
        cleanupState.fetchTask = Task { [weak self] in
            guard let self else { return }

            let outcome = await Self.fetchRemoteOutcome(
                request: request,
                awaitTorReady: awaitTorReady,
                isNetworkActivationAllowed: isNetworkActivationAllowed,
                makeFetchData: makeFetchData,
                validationPolicy: validationPolicy,
                baselineEntries: baselineEntries
            )

            guard !Task.isCancelled, self.panicGeneration == generation else {
                if self.panicGeneration == generation {
                    self.isFetching = false
                    self.cleanupState.fetchTask = nil
                }
                return
            }
            self.cleanupState.fetchTask = nil

            switch outcome {
            case .success(let parsed, let csv):
                self.handleFetchSuccess(entries: parsed, csv: csv)
            case .torNotReady:
                self.handleFetchFailure(.torNotReady)
            case .invalidData:
                self.handleFetchFailure(.invalidData)
            case .network(let description):
                self.handleFetchFailure(.network(description))
            case .cancelled:
                self.isFetching = false
            }
        }
    }

    nonisolated private static func fetchRemoteOutcome(
        request: URLRequest,
        awaitTorReady: @escaping @Sendable () async -> Bool,
        isNetworkActivationAllowed: @escaping @MainActor () -> Bool,
        makeFetchData: @escaping @MainActor @Sendable () -> (@Sendable (URLRequest) async throws -> Data),
        validationPolicy: GeoRelayDirectoryValidationPolicy,
        baselineEntries: Set<Entry>
    ) async -> DetachedFetchOutcome {
        let ready = await awaitTorReady()
        guard !Task.isCancelled else { return .cancelled }
        guard ready else { return .torNotReady }

        // Re-check activation gate after Tor readiness completes so a panic
        // wipe or offline transition during the wait cannot fire an outbound
        // request.
        let allowed = await isNetworkActivationAllowed()
        guard !Task.isCancelled, allowed else { return .cancelled }

        // Resolve the URLSession after Tor readiness completes so a proxy
        // transition or Tor bootstrap while awaiting cannot leave us on a
        // stale pre-wait session.
        let fetchData = await makeFetchData()
        guard !Task.isCancelled else { return .cancelled }

        return await Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return DetachedFetchOutcome.cancelled }
            do {
                let data = try await fetchData(request)
                guard !Task.isCancelled else { return .cancelled }
                guard let parsed = Self.validatedEntries(
                    from: data,
                    policy: validationPolicy,
                    minimumEntries: validationPolicy.minimumRemoteEntries,
                    baselineEntries: baselineEntries
                ) else {
                    return .invalidData
                }

                return .success(entries: parsed, csv: data)
            } catch {
                if Task.isCancelled { return .cancelled }
                return .network(error.localizedDescription)
            }
        }.value
    }

    private enum FetchFailure {
        case torNotReady
        case invalidData
        case network(String)
    }

    @MainActor
    private func handleFetchSuccess(entries parsed: [Entry], csv: Data) {
        entries = parsed
        persistCache(csv)
        dependencies.userDefaults.set(dependencies.now(), forKey: lastFetchKey)
        SecureLogger.info("GeoRelayDirectory: refreshed \(parsed.count) relays from remote", category: .session)
        isFetching = false
        retryAttempt = 0
        cancelRetry()
        // Let waiters (e.g. location notes stuck in a "no relays" state) retry.
        dependencies.notificationCenter.post(name: .geoRelayDirectoryDidRefresh, object: nil)
    }

    @MainActor
    private func handleFetchFailure(_ reason: FetchFailure) {
        switch reason {
        case .torNotReady:
            SecureLogger.warning("GeoRelayDirectory: Tor not ready; scheduling retry", category: .session)
        case .invalidData:
            SecureLogger.warning("GeoRelayDirectory: remote fetch returned invalid data; scheduling retry", category: .session)
        case .network(let errorDescription):
            SecureLogger.warning("GeoRelayDirectory: remote fetch failed with error: \(errorDescription)", category: .session)
        }
        isFetching = false
        scheduleRetry()
    }

    @MainActor
    private func scheduleRetry() {
        retryAttempt = min(retryAttempt + 1, 10)
        let base = dependencies.retryInitialSeconds
        let maxDelay = dependencies.retryMaxSeconds
        let multiplier = pow(2.0, Double(max(retryAttempt - 1, 0)))
        let calculated = base * multiplier
        let delay = min(maxDelay, max(base, calculated))

        cancelRetry()
        cleanupState.retryTask = Task { [weak self] in
            guard let self else { return }
            await self.dependencies.retrySleep(delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.prefetchIfNeeded(force: true)
            }
        }
    }

    @MainActor
    private func cancelRetry() {
        cleanupState.retryTask?.cancel()
        cleanupState.retryTask = nil
    }

    private func persistCache(_ data: Data) {
        guard let url = dependencies.cacheURL() else { return }
        do {
            try dependencies.writeData(data, url)
        } catch {
            SecureLogger.warning("GeoRelayDirectory: failed to write cache: \(error)", category: .session)
        }
    }

    // MARK: - Loading
    private func loadLocalEntries() -> [Entry] {
        // Prefer cached file if present
        if let cache = dependencies.cacheURL(),
           let data = dependencies.readData(cache),
           let entries = Self.validatedEntries(
               from: data,
               policy: dependencies.validationPolicy,
               minimumEntries: 1
           ) {
            return entries
        }

        // Try bundled resource(s)
        let bundleCandidates = dependencies.bundledCSVURLs()

        for url in bundleCandidates {
            if let data = dependencies.readData(url),
               let entries = Self.validatedEntries(
                   from: data,
                   policy: dependencies.validationPolicy,
                   minimumEntries: 1
               ) {
                return entries
            }
        }

        // Try filesystem path (development/test)
        if let cwd = dependencies.currentDirectoryPath(),
           let data = dependencies.readData(URL(fileURLWithPath: cwd).appendingPathComponent("relays/online_relays_gps.csv")),
           let entries = Self.validatedEntries(
               from: data,
               policy: dependencies.validationPolicy,
               minimumEntries: 1
           ) {
            return entries
        }

        SecureLogger.warning("GeoRelayDirectory: no local CSV found; entries empty", category: .session)
        return []
    }

    nonisolated private static func loadLocalEntriesOffMain(
        cacheURL: URL?,
        bundleURLs: [URL],
        currentDirectoryPath: String?,
        policy: GeoRelayDirectoryValidationPolicy
    ) -> [Entry] {
        if let cacheURL,
           let data = try? Data(contentsOf: cacheURL),
           let entries = validatedEntries(from: data, policy: policy, minimumEntries: 1) {
            return entries
        }

        for url in bundleURLs {
            if let data = try? Data(contentsOf: url),
               let entries = validatedEntries(from: data, policy: policy, minimumEntries: 1) {
                return entries
            }
        }

        if let cwd = currentDirectoryPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: cwd).appendingPathComponent("relays/online_relays_gps.csv")),
           let entries = validatedEntries(from: data, policy: policy, minimumEntries: 1) {
            return entries
        }

        SecureLogger.warning("GeoRelayDirectory: no local CSV found; entries empty", category: .session)
        return []
    }

    /// Parses the fixed three-column format as an all-or-nothing trust unit.
    /// One malformed or conflicting row rejects the complete dataset rather
    /// than silently shrinking or partially replacing the current directory.
    nonisolated static func validatedEntries(
        from data: Data,
        policy: GeoRelayDirectoryValidationPolicy,
        minimumEntries: Int,
        baselineEntries: Set<Entry>? = nil
    ) -> [Entry]? {
        guard !data.isEmpty, data.count <= policy.maximumBytes,
              let text = String(data: data, encoding: .utf8),
              !text.hasPrefix("\u{feff}") else {
            return nil
        }

        let lines = text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let header = lines.first,
              lines.count - 1 <= policy.maximumRows else {
            return nil
        }

        let headerParts = header
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let supportedHeaders = [
            ["relay url", "latitude", "longitude"],
            ["relay url", "lat", "lon"]
        ]
        guard supportedHeaders.contains(headerParts) else {
            return nil
        }

        var entriesByHost: [String: Entry] = [:]
        entriesByHost.reserveCapacity(min(lines.count, policy.maximumEntries))
        for line in lines.dropFirst() {
            let parts = line
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 3,
                  let host = validatedDirectoryAddress(parts[0]),
                  let latitude = Double(parts[1]), latitude.isFinite,
                  (-90.0...90.0).contains(latitude),
                  let longitude = Double(parts[2]), longitude.isFinite,
                  (-180.0...180.0).contains(longitude) else {
                return nil
            }

            let entry = Entry(host: host, lat: latitude, lon: longitude)
            if let existing = entriesByHost[host], existing != entry {
                // One endpoint cannot truthfully occupy two coordinates. Do
                // not let row ordering choose which location clients trust.
                return nil
            }
            entriesByHost[host] = entry
            guard entriesByHost.count <= policy.maximumEntries else { return nil }
        }

        let parsedEntries = Set(entriesByHost.values)
        guard parsedEntries.count >= minimumEntries else { return nil }

        if let baselineEntries {
            guard (0...1).contains(policy.minimumRetainedFraction) else { return nil }
            let requiredOverlap = Int(
                ceil(Double(baselineEntries.count) * policy.minimumRetainedFraction)
            )
            guard parsedEntries.intersection(baselineEntries).count >= requiredOverlap else {
                return nil
            }
        }

        return parsedEntries.sorted {
            ($0.host, $0.lat, $0.lon) < ($1.host, $1.lat, $1.lon)
        }
    }

    nonisolated private static func isAllowedHostLabelByte(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7A) // a-z
            || (byte >= 0x30 && byte <= 0x39) // 0-9
            || byte == 0x2D // '-'
    }

    nonisolated private static func validatedDirectoryAddress(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        // Printable ASCII only (0x20...0x7E) — rejects all non-ASCII and control chars.
        for scalar in value.unicodeScalars {
            guard scalar.value >= 0x20 && scalar.value < 0x7F else { return nil }
        }

        var remainder: Substring = value[...]
        if let schemeRange = remainder.range(of: "://") {
            let scheme = remainder[..<schemeRange.lowerBound].lowercased()
            guard scheme == "wss" || scheme == "https" else { return nil }
            remainder = remainder[schemeRange.upperBound...]
        }

        // Reject userinfo, query, fragment, whitespace, and non-root paths.
        if remainder.hasSuffix("/") {
            remainder = remainder.dropLast()
        }
        guard !remainder.isEmpty,
              !remainder.contains("/"),
              !remainder.contains("@"),
              !remainder.contains("?"),
              !remainder.contains("#"),
              !remainder.contains(" ") else {
            return nil
        }

        let hostPart: Substring
        let port: Int?
        if let colonIndex = remainder.firstIndex(of: ":") {
            hostPart = remainder[..<colonIndex]
            let portPart = remainder[remainder.index(after: colonIndex)...]
            guard !portPart.isEmpty,
                  portPart.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let parsedPort = Int(portPart),
                  (1...65_535).contains(parsedPort) else {
                return nil
            }
            port = parsedPort
        } else {
            hostPart = remainder
            port = nil
        }

        let host = hostPart.lowercased()
        guard !host.isEmpty, host.count <= 253,
              !host.hasSuffix("."),
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal") else {
            return nil
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              !labels.allSatisfy({ $0.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }),
              labels.allSatisfy({ label in
                  (1...63).contains(label.count) &&
                  label.first != "-" &&
                  label.last != "-" &&
                  label.utf8.allSatisfy(isAllowedHostLabelByte)
              }) else {
            return nil
        }

        if let port, port != 443 {
            return "\(host):\(port)"
        }
        return host
    }

    // MARK: - Observers & Timers
    private func registerObservers() {
        let center = dependencies.notificationCenter

        let torReady = center.addObserver(
            forName: .TorDidBecomeReady,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.prefetchIfNeeded(force: true)
            }
        }
        cleanupState.observers.append(torReady)

        if let activeNotificationName = dependencies.activeNotificationName {
            let didBecomeActive = center.addObserver(
                forName: activeNotificationName,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.prefetchIfNeeded()
                }
            }
            cleanupState.observers.append(didBecomeActive)
        }
    }

    private func startRefreshTimer() {
        cleanupState.refreshTimer?.invalidate()
        let interval = dependencies.refreshCheckInterval
        guard interval > 0 else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.prefetchIfNeeded()
            }
        }
        timer.tolerance = min(300.0, interval * 0.1)
        cleanupState.refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Panic-wipe hook: stop scheduled retries, clear the last-fetch timestamp,
    /// drop cached geohash lookups from memory, and remove the cached relay CSV
    /// from Application Support.
    func resetForPanic() {
        panicGeneration &+= 1
        cancelRetry()
        cleanupState.fetchTask?.cancel()
        cleanupState.fetchTask = nil
        cleanupState.localLoadTask?.cancel()
        cleanupState.localLoadTask = nil
        isFetching = false
        retryAttempt = 0
        closestRelaysCache.removeAll(keepingCapacity: false)
        dependencies.userDefaults.removeObject(forKey: lastFetchKey)
        if let cacheURL = dependencies.cacheURL() {
            try? FileManager.default.removeItem(at: cacheURL)
        }
    }

    var debugRetryAttempt: Int { retryAttempt }
    var debugHasRetryTask: Bool { cleanupState.retryTask != nil }
    var debugObserverCount: Int { cleanupState.observers.count }
    var debugClosestRelaysCacheCount: Int { closestRelaysCache.count }
}

/// Chunked, strictly byte-bounded HTTP body reader for `GeoRelayDirectory`.
/// Replaces byte-by-byte `AsyncBytes` iteration (~50k async suspensions for
/// the relay CSV) while still enforcing `maximumBytes` before unbounded memory
/// allocation and rejecting HTTP errors or unexpected redirect URLs.
private final class BoundedHTTPDataReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let expectedURL: URL?
    private let maximumBytes: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var settled = false
    private weak var task: URLSessionDataTask?

    private init(expectedURL: URL?, maximumBytes: Int) {
        self.expectedURL = expectedURL
        self.maximumBytes = maximumBytes
    }

    static func fetch(
        request: URLRequest,
        using session: URLSession,
        maximumBytes: Int
    ) async throws -> Data {
        let reader = BoundedHTTPDataReader(expectedURL: request.url, maximumBytes: maximumBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let dataTask = session.dataTask(with: request)
                reader.start(task: dataTask, continuation: continuation)
            }
        } onCancel: {
            reader.cancel()
        }
    }

    private func start(task: URLSessionDataTask, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if settled {
            lock.unlock()
            task.cancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.task = task
        self.continuation = continuation
        lock.unlock()

        task.delegate = self
        task.resume()
    }

    private func cancel() {
        let activeTask: URLSessionDataTask?
        let pendingContinuation: CheckedContinuation<Data, Error>?
        lock.lock()
        activeTask = task
        if !settled {
            settled = true
            pendingContinuation = continuation
            continuation = nil
        } else {
            pendingContinuation = nil
        }
        lock.unlock()

        activeTask?.cancel()
        pendingContinuation?.resume(throwing: CancellationError())
    }

    private func finish(with result: Result<Data, Error>) {
        let pendingContinuation: CheckedContinuation<Data, Error>?
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        settled = true
        pendingContinuation = continuation
        continuation = nil
        lock.unlock()

        pendingContinuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        _ = session
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              http.url == expectedURL else {
            completionHandler(.cancel)
            finish(with: .failure(URLError(.badServerResponse)))
            return
        }
        guard http.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            finish(with: .failure(URLError(.dataLengthExceedsMaximum)))
            return
        }
        if http.expectedContentLength > 0 {
            lock.lock()
            buffer.reserveCapacity(Int(http.expectedContentLength))
            lock.unlock()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        _ = session
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        if buffer.count + data.count > maximumBytes {
            lock.unlock()
            dataTask.cancel()
            finish(with: .failure(URLError(.dataLengthExceedsMaximum)))
            return
        }
        buffer.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        _ = session
        _ = task
        if let error {
            finish(with: .failure(error))
            return
        }
        lock.lock()
        let resultData = buffer
        lock.unlock()
        finish(with: .success(resultData))
    }
}
