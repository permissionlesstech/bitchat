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
            awaitTorReady: { await TorManager.shared.awaitReady() },
            makeFetchData: {
                let session = TorURLSession.shared.session
                return { request in
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse,
                          (200...299).contains(response.statusCode),
                          response.url == request.url else {
                        throw URLError(.badServerResponse)
                    }

                    let maximumBytes = validationPolicy.maximumBytes
                    guard response.expectedContentLength <= Int64(maximumBytes) else {
                        throw URLError(.dataLengthExceedsMaximum)
                    }
                    var data = Data()
                    if response.expectedContentLength > 0 {
                        data.reserveCapacity(Int(response.expectedContentLength))
                    }
                    for try await byte in bytes {
                        guard data.count < maximumBytes else {
                            throw URLError(.dataLengthExceedsMaximum)
                        }
                        data.append(byte)
                    }
                    return data
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
            validationPolicy: validationPolicy
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

        init(notificationCenter: NotificationCenter) {
            self.notificationCenter = notificationCenter
        }

        deinit {
            observers.forEach { notificationCenter.removeObserver($0) }
            refreshTimer?.invalidate()
            retryTask?.cancel()
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
    }

    static let shared = GeoRelayDirectory()

    private(set) var entries: [Entry] = []
    private let lastFetchKey = "georelay.lastFetchAt"
    private let dependencies: GeoRelayDirectoryDependencies
    private let cleanupState: CleanupState

    private var retryAttempt: Int = 0
    private var isFetching: Bool = false

    private init() {
        self.dependencies = .live()
        self.cleanupState = CleanupState(notificationCenter: dependencies.notificationCenter)
        entries = loadLocalEntries()
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
        if dependencies.autoStart {
            registerObservers()
            startRefreshTimer()
            prefetchIfNeeded()
        }
    }

    /// Returns up to `count` relay URLs (wss://) closest to the geohash center.
    func closestRelays(toGeohash geohash: String, count: Int = 5) -> [String] {
        let center = Geohash.decodeCenter(geohash)
        return closestRelays(toLat: center.lat, lon: center.lon, count: count)
    }

    /// Returns up to `count` relay URLs (wss://) closest to the given coordinate.
    /// Ties break by host so every device with the same directory picks the
    /// same relay set — publishers and subscribers must agree on relays.
    func closestRelays(toLat lat: Double, lon: Double, count: Int = 5) -> [String] {
        guard !entries.isEmpty, count > 0 else { return [] }

        return entries
            .map { (entry: $0, distance: haversineKm(lat, lon, $0.lat, $0.lon)) }
            .sorted { ($0.distance, $0.entry.host) < ($1.distance, $1.entry.host) }
            .prefix(count)
            .map { "wss://\($0.entry.host)" }
    }

    // MARK: - Remote Fetch
    func prefetchIfNeeded(force: Bool = false) {
        guard !isFetching else { return }

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

        let request = URLRequest(
            url: dependencies.remoteURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        let awaitTorReady = dependencies.awaitTorReady
        let fetchData = dependencies.makeFetchData()
        let validationPolicy = dependencies.validationPolicy
        let baselineEntries = Set(entries)

        Task { [weak self] in
            guard let self else { return }

            let outcome = await Self.fetchRemoteOutcome(
                request: request,
                awaitTorReady: awaitTorReady,
                fetchData: fetchData,
                validationPolicy: validationPolicy,
                baselineEntries: baselineEntries
            )

            switch outcome {
            case .success(let parsed, let csv):
                self.handleFetchSuccess(entries: parsed, csv: csv)
            case .torNotReady:
                self.handleFetchFailure(.torNotReady)
            case .invalidData:
                self.handleFetchFailure(.invalidData)
            case .network(let description):
                self.handleFetchFailure(.network(description))
            }
        }
    }

    nonisolated private static func fetchRemoteOutcome(
        request: URLRequest,
        awaitTorReady: @escaping @Sendable () async -> Bool,
        fetchData: @escaping @Sendable (URLRequest) async throws -> Data,
        validationPolicy: GeoRelayDirectoryValidationPolicy,
        baselineEntries: Set<Entry>
    ) async -> DetachedFetchOutcome {
        await Task.detached(priority: .utility) {
            let ready = await awaitTorReady()
            guard ready else { return .torNotReady }

            do {
                let data = try await fetchData(request)
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

    nonisolated private static func validatedDirectoryAddress(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({
                  $0.isASCII && !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }

        let candidate = value.contains("://") ? value : "wss://\(value)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "wss" || scheme == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let rawHost = components.host else {
            return nil
        }

        let host = rawHost.lowercased()
        guard !host.isEmpty, host.count <= 253,
              host.unicodeScalars.allSatisfy({ $0.isASCII }),
              !host.hasSuffix("."),
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal") else {
            return nil
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard labels.count >= 2,
              !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              labels.allSatisfy({ label in
                  (1...63).contains(label.count) &&
                  label.first != "-" &&
                  label.last != "-" &&
                  label.unicodeScalars.allSatisfy { allowed.contains($0) }
              }) else {
            return nil
        }

        if let port = components.port {
            guard (1...65_535).contains(port) else { return nil }
            if port != 443 { return "\(host):\(port)" }
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
        cleanupState.refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    var debugRetryAttempt: Int { retryAttempt }
    var debugHasRetryTask: Bool { cleanupState.retryTask != nil }
    var debugObserverCount: Int { cleanupState.observers.count }
}

// MARK: - Distance
private func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let r = 6371.0 // Earth radius in km
    let dLat = (lat2 - lat1) * .pi / 180
    let dLon = (lon2 - lon1) * .pi / 180
    let a = sin(dLat/2) * sin(dLat/2) + cos(lat1 * .pi/180) * cos(lat2 * .pi/180) * sin(dLon/2) * sin(dLon/2)
    let c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return r * c
}
