import BitLogger
import Foundation
import Tor
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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

        return Self(
            userDefaults: .standard,
            notificationCenter: .default,
            now: Date.init,
            remoteURL: URL(string: "https://raw.githubusercontent.com/permissionlesstech/georelays/refs/heads/main/nostr_relays.csv")!,
            fetchInterval: TransportConfig.geoRelayFetchIntervalSeconds,
            refreshCheckInterval: TransportConfig.geoRelayRefreshCheckIntervalSeconds,
            retryInitialSeconds: TransportConfig.geoRelayRetryInitialSeconds,
            retryMaxSeconds: TransportConfig.geoRelayRetryMaxSeconds,
            awaitTorReady: { await TorManager.shared.awaitReady() },
            makeFetchData: {
                let session = TorURLSession.shared.session
                return { request in
                    let (data, _) = try await session.data(for: request)
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
                    return dir.appendingPathComponent("georelays_cache.csv")
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
            autoStart: true
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
        case success(entries: [Entry], csv: String)
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
    func closestRelays(toLat lat: Double, lon: Double, count: Int = 5) -> [String] {
        guard !entries.isEmpty, count > 0 else { return [] }

        if entries.count <= count {
            return entries
                .sorted { a, b in
                    haversineKm(lat, lon, a.lat, a.lon) < haversineKm(lat, lon, b.lat, b.lon)
                }
                .map { "wss://\($0.host)" }
        }

        var best: [(entry: Entry, distance: Double)] = []
        best.reserveCapacity(count)

        for entry in entries {
            let distance = haversineKm(lat, lon, entry.lat, entry.lon)
            if best.count < count {
                let idx = best.firstIndex { $0.distance > distance } ?? best.count
                best.insert((entry, distance), at: idx)
            } else if let worstDistance = best.last?.distance, distance < worstDistance {
                let idx = best.firstIndex { $0.distance > distance } ?? best.count
                best.insert((entry, distance), at: idx)
                best.removeLast()
            }
        }

        return best.map { "wss://\($0.entry.host)" }
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

        Task { [weak self] in
            guard let self else { return }

            let outcome = await Self.fetchRemoteOutcome(
                request: request,
                awaitTorReady: awaitTorReady,
                fetchData: fetchData
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
        fetchData: @escaping @Sendable (URLRequest) async throws -> Data
    ) async -> DetachedFetchOutcome {
        await Task.detached(priority: .utility) {
            let ready = await awaitTorReady()
            guard ready else { return .torNotReady }

            do {
                let data = try await fetchData(request)
                guard let text = String(data: data, encoding: .utf8) else {
                    return .invalidData
                }

                let parsed = Self.parseCSV(text)
                guard !parsed.isEmpty else {
                    return .invalidData
                }

                return .success(entries: parsed, csv: text)
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
    private func handleFetchSuccess(entries parsed: [Entry], csv: String) {
        entries = parsed
        persistCache(csv)
        dependencies.userDefaults.set(dependencies.now(), forKey: lastFetchKey)
        SecureLogger.info("GeoRelayDirectory: refreshed \(parsed.count) relays from remote", category: .session)
        isFetching = false
        retryAttempt = 0
        cancelRetry()
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

    private func persistCache(_ text: String) {
        guard let url = dependencies.cacheURL() else { return }
        guard let data = text.data(using: .utf8) else { return }
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
           let text = String(data: data, encoding: .utf8) {
            let arr = Self.parseCSV(text)
            if !arr.isEmpty { return arr }
        }

        // Try bundled resource(s)
        let bundleCandidates = dependencies.bundledCSVURLs()

        for url in bundleCandidates {
            if let data = dependencies.readData(url),
               let text = String(data: data, encoding: .utf8) {
                let arr = Self.parseCSV(text)
                if !arr.isEmpty { return arr }
            }
        }

        // Try filesystem path (development/test)
        if let cwd = dependencies.currentDirectoryPath(),
           let data = dependencies.readData(URL(fileURLWithPath: cwd).appendingPathComponent("relays/online_relays_gps.csv")),
           let text = String(data: data, encoding: .utf8) {
            return Self.parseCSV(text)
        }

        SecureLogger.warning("GeoRelayDirectory: no local CSV found; entries empty", category: .session)
        return []
    }

    nonisolated static func parseCSV(_ text: String) -> [Entry] {
        var result: Set<Entry> = []
        let lines = text.split(whereSeparator: { $0.isNewline })
        for (idx, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if idx == 0 && line.lowercased().contains("relay url") { continue }
            let parts = line.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { continue }
            var host = parts[0]
            host = host.replacingOccurrences(of: "https://", with: "")
            host = host.replacingOccurrences(of: "http://", with: "")
            host = host.replacingOccurrences(of: "wss://", with: "")
            host = host.replacingOccurrences(of: "ws://", with: "")
            host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let lat = Double(parts[1]), let lon = Double(parts[2]) else { continue }
            result.insert(Entry(host: host, lat: lat, lon: lon))
        }
        return Array(result)
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
