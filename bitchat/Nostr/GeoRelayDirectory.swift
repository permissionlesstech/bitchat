import Foundation

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
    private let fetchInterval: TimeInterval = TransportConfig.geoRelayFetchIntervalSeconds // 24h

    private init() {
        // Load cached or bundled data synchronously
        self.entries = self.loadLocalEntries()
        // Fire-and-forget remote refresh if stale
        prefetchIfNeeded()
    }

    /// Returns up to `count` relay URLs (wss://) closest to the geohash center.
    func closestRelays(toGeohash geohash: String, count: Int = 5) -> [String] {
        let center = Geohash.decodeCenter(geohash)
        return closestRelays(toLat: center.lat, lon: center.lon, count: count)
    }

    /// Returns up to `count` relay URLs (wss://) closest to the given coordinate.
    func closestRelays(toLat lat: Double, lon: Double, count: Int = 5) -> [String] {
        guard !entries.isEmpty else { return [] }
        let sorted = entries
            .sorted { a, b in
                haversineKm(lat, lon, a.lat, a.lon) < haversineKm(lat, lon, b.lat, b.lon)
            }
            .prefix(count)
        return sorted.map { "wss://\($0.host)" }
    }

    // MARK: - Remote Fetch
    func prefetchIfNeeded() {
        let now = Date()
        let last = UserDefaults.standard.object(forKey: lastFetchKey) as? Date ?? .distantPast
        guard now.timeIntervalSince(last) >= fetchInterval else { return }
        fetchRemote()
    }

    private func fetchRemote() {
        let req = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let task = URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self = self else { return }
            if let data = data, error == nil, let text = String(data: data, encoding: .utf8) {
                let parsed = GeoRelayDirectory.parseCSV(text)
                if !parsed.isEmpty {
                    Task { @MainActor in
                        self.entries = parsed
                        self.persistCache(text)
                        UserDefaults.standard.set(Date(), forKey: self.lastFetchKey)
                        SecureLogger.log("GeoRelayDirectory: refreshed \(parsed.count) relays from remote", category: SecureLogger.session, level: .info)
                    }
                    return
                }
            }
            SecureLogger.log("GeoRelayDirectory: remote fetch failed; keeping local entries", category: SecureLogger.session, level: .warning)
        }
        task.resume()
    }

    private func persistCache(_ text: String) {
        guard let url = cacheURL() else { return }
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            SecureLogger.log("GeoRelayDirectory: failed to write cache: \(error)", category: SecureLogger.session, level: .warning)
        }
    }

    // MARK: - Loading
    private func loadLocalEntries() -> [Entry] {
        // Prefer cached file if present
        if let cache = self.cacheURL(),
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
            if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
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
        SecureLogger.log("GeoRelayDirectory: no local CSV found; entries empty", category: SecureLogger.session, level: .warning)
        return []
    }

    nonisolated static func parseCSV(_ text: String) -> [Entry] {
        var result: Set<Entry> = []
        let lines = text.split(whereSeparator: { $0.isNewline })
        // Skip header if present
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
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dir = base.appendingPathComponent("bitchat", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent(cacheFileName)
        } catch { return nil }
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
