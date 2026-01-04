import BitLogger
import Foundation
import Tor
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Directory of online Nostr relays with approximate GPS locations, used for geohash routing.
@MainActor
final class GeoRelayDirectory {
    struct Entry: Hashable {
        let host: String
        let lat: Double
        let lon: Double
    }

    static let shared = GeoRelayDirectory()

    private(set) var entries: [Entry] = []
    private let cacheFileName = "georelays_cache.csv"
    private let lastFetchKey = "georelay.lastFetchAt"
    private let remoteURL = URL(string: "https://raw.githubusercontent.com/permissionlesstech/georelays/refs/heads/main/nostr_relays.csv")!
    private let fetchInterval: TimeInterval = TransportConfig.geoRelayFetchIntervalSeconds

    private var refreshTimer: Timer?
    private var retryTask: Task<Void, Never>?
    private var retryAttempt: Int = 0
    private var isFetching: Bool = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        entries = loadLocalEntries()
        registerObservers()
        startRefreshTimer()
        prefetchIfNeeded()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        refreshTimer?.invalidate()
        retryTask?.cancel()
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

        let now = Date()
        let last = UserDefaults.standard.object(forKey: lastFetchKey) as? Date ?? .distantPast

        if !force {
            guard now.timeIntervalSince(last) >= fetchInterval else { return }
        } else if last != .distantPast,
                  now.timeIntervalSince(last) < TransportConfig.geoRelayRetryInitialSeconds {
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
            url: remoteURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )

        Task.detached { [weak self] in
            guard let self else { return }

            let ready = await TorManager.shared.awaitReady()
            if !ready {
                await self.handleFetchFailure(.torNotReady)
                return
            }

            do {
                let (data, _) = try await TorURLSession.shared.session.data(for: request)
                guard let text = String(data: data, encoding: .utf8) else {
                    await self.handleFetchFailure(.invalidData)
                    return
                }

                let parsed = GeoRelayDirectory.parseCSV(text)
                guard !parsed.isEmpty else {
                    await self.handleFetchFailure(.invalidData)
                    return
                }

                await self.handleFetchSuccess(entries: parsed, csv: text)
            } catch {
                await self.handleFetchFailure(.network(error))
            }
        }
    }

    private enum FetchFailure {
        case torNotReady
        case invalidData
        case network(Error)
    }

    @MainActor
    private func handleFetchSuccess(entries parsed: [Entry], csv: String) {
        entries = parsed
        persistCache(csv)
        UserDefaults.standard.set(Date(), forKey: lastFetchKey)
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
        case .network(let error):
            SecureLogger.warning("GeoRelayDirectory: remote fetch failed with error: \(error.localizedDescription)", category: .session)
        }
        isFetching = false
        scheduleRetry()
    }

    @MainActor
    private func scheduleRetry() {
        retryAttempt = min(retryAttempt + 1, 10)
        let base = TransportConfig.geoRelayRetryInitialSeconds
        let maxDelay = TransportConfig.geoRelayRetryMaxSeconds
        let multiplier = pow(2.0, Double(max(retryAttempt - 1, 0)))
        let calculated = base * multiplier
        let delay = min(maxDelay, max(base, calculated))

        cancelRetry()
        retryTask = Task { [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                self?.prefetchIfNeeded(force: true)
            }
        }
    }

    @MainActor
    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    private func persistCache(_ text: String) {
        guard let url = cacheURL() else { return }
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            SecureLogger.warning("GeoRelayDirectory: failed to write cache: \(error)", category: .session)
        }
    }

    // MARK: - Loading
    private func loadLocalEntries() -> [Entry] {
        // Prefer cached file if present
        if let cache = cacheURL(),
           let data = try? Data(contentsOf: cache),
           let text = String(data: data, encoding: .utf8) {
            let arr = Self.parseCSV(text)
            if !arr.isEmpty { return arr }
        }

        // Try bundled resource(s)
        let bundleCandidates = [
            Bundle.main.url(forResource: "nostr_relays", withExtension: "csv"),
            Bundle.main.url(forResource: "online_relays_gps", withExtension: "csv"),
            Bundle.main.url(forResource: "online_relays_gps", withExtension: "csv", subdirectory: "relays")
        ].compactMap { $0 }

        for url in bundleCandidates {
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                let arr = Self.parseCSV(text)
                if !arr.isEmpty { return arr }
            }
        }

        // Try filesystem path (development/test)
        if let cwd = FileManager.default.currentDirectoryPath as String?,
           let data = try? Data(contentsOf: URL(fileURLWithPath: cwd).appendingPathComponent("relays/online_relays_gps.csv")),
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

    private func cacheURL() -> URL? {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = base.appendingPathComponent("bitchat", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent(cacheFileName)
        } catch {
            return nil
        }
    }

    // MARK: - Observers & Timers
    private func registerObservers() {
        let center = NotificationCenter.default

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
        observers.append(torReady)

#if os(iOS)
        let didBecomeActive = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.prefetchIfNeeded()
            }
        }
        observers.append(didBecomeActive)
#elseif os(macOS)
        let didBecomeActive = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.prefetchIfNeeded()
            }
        }
        observers.append(didBecomeActive)
#endif
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TransportConfig.geoRelayRefreshCheckIntervalSeconds
        guard interval > 0 else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.prefetchIfNeeded()
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
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
