import Foundation
import Combine
#if os(iOS) || os(macOS)
import CoreLocation
#endif

/// Stores a user-maintained list of bookmarked geohash channels.
/// - Persistence: UserDefaults (JSON string array)
/// - Semantics: geohashes are normalized to lowercase base32 and de-duplicated
final class GeohashBookmarksStore: ObservableObject {
    static let shared = GeohashBookmarksStore()

    @Published private(set) var bookmarks: [String] = []
    @Published private(set) var bookmarkNames: [String: String] = [:] // geohash -> friendly name

    private let storeKey = "locationChannel.bookmarks"
    private let namesStoreKey = "locationChannel.bookmarkNames"
    private var membership: Set<String> = []
    #if os(iOS) || os(macOS)
    private let geocoder = CLGeocoder()
    private var resolving: Set<String> = []
    #endif

    private init() {
        load()
    }

    // MARK: - Public API
    func isBookmarked(_ geohash: String) -> Bool {
        return membership.contains(Self.normalize(geohash))
    }

    func toggle(_ geohash: String) {
        let gh = Self.normalize(geohash)
        if membership.contains(gh) {
            remove(gh)
        } else {
            add(gh)
        }
    }

    func add(_ geohash: String) {
        let gh = Self.normalize(geohash)
        guard !gh.isEmpty else { return }
        guard !membership.contains(gh) else { return }
        bookmarks.insert(gh, at: 0)
        membership.insert(gh)
        persist()
        // Resolve and persist a friendly name once when added
        resolveNameIfNeeded(for: gh)
    }

    func remove(_ geohash: String) {
        let gh = Self.normalize(geohash)
        guard membership.contains(gh) else { return }
        if let idx = bookmarks.firstIndex(of: gh) { bookmarks.remove(at: idx) }
        membership.remove(gh)
        // Clean up stored name to avoid stale cache growth
        if bookmarkNames.removeValue(forKey: gh) != nil {
            persistNames()
        }
        persist()
    }

    // MARK: - Persistence
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return }
        if let arr = try? JSONDecoder().decode([String].self, from: data) {
            // Sanitize, normalize, dedupe while preserving order (first occurrence wins)
            var seen = Set<String>()
            var list: [String] = []
            for raw in arr {
                let gh = Self.normalize(raw)
                guard !gh.isEmpty else { continue }
                if !seen.contains(gh) {
                    seen.insert(gh)
                    list.append(gh)
                }
            }
            bookmarks = list
            membership = seen
        }
        // Load any saved names
        if let namesData = UserDefaults.standard.data(forKey: namesStoreKey),
           let dict = try? JSONDecoder().decode([String: String].self, from: namesData) {
            bookmarkNames = dict
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private func persistNames() {
        if let data = try? JSONEncoder().encode(bookmarkNames) {
            UserDefaults.standard.set(data, forKey: namesStoreKey)
        }
    }

    // MARK: - Helpers
    private static func normalize(_ s: String) -> String {
        let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
        return s
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "#", with: "")
            .filter { allowed.contains($0) }
    }

    // MARK: - Name Resolution
    /// Attempt to resolve and persist a friendly place name for a bookmarked geohash.
    func resolveNameIfNeeded(for geohash: String) {
        let gh = Self.normalize(geohash)
        guard !gh.isEmpty else { return }
        if bookmarkNames[gh] != nil { return }
        #if os(iOS) || os(macOS)
        if resolving.contains(gh) { return }
        resolving.insert(gh)
        // For very coarse geohashes, sample multiple points to capture multiple admin areas
        if gh.count <= 2 {
            let b = Geohash.decodeBounds(gh)
            let pts: [CLLocation] = [
                CLLocation(latitude: (b.latMin + b.latMax) / 2, longitude: (b.lonMin + b.lonMax) / 2), // center
                CLLocation(latitude: b.latMin, longitude: b.lonMin),
                CLLocation(latitude: b.latMin, longitude: b.lonMax),
                CLLocation(latitude: b.latMax, longitude: b.lonMin),
                CLLocation(latitude: b.latMax, longitude: b.lonMax)
            ]
            resolveCompositeAdminName(geohash: gh, points: pts)
        } else {
            let center = Geohash.decodeCenter(gh)
            let loc = CLLocation(latitude: center.lat, longitude: center.lon)
            geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
                guard let self = self else { return }
                defer { self.resolving.remove(gh) }
                if let pm = placemarks?.first {
                    let name = Self.nameForGeohashLength(gh.count, from: pm)
                    if let name = name, !name.isEmpty {
                        DispatchQueue.main.async {
                            self.bookmarkNames[gh] = name
                            self.persistNames()
                        }
                    }
                }
            }
        }
        #endif
    }

    #if os(iOS) || os(macOS)
    private func resolveCompositeAdminName(geohash gh: String, points: [CLLocation]) {
        var uniqueAdmins = OrderedSet<String>()
        var idx = 0
        func step() {
            if idx >= points.count {
                // Compose up to 2 names joined by ' and '
                let finalName: String? = {
                    let names = uniqueAdmins.array
                    if names.count >= 2 { return names[0] + " and " + names[1] }
                    return names.first
                }()
                if let finalName = finalName, !finalName.isEmpty {
                    DispatchQueue.main.async {
                        self.bookmarkNames[gh] = finalName
                        self.persistNames()
                    }
                }
                self.resolving.remove(gh)
                return
            }
            let loc = points[idx]
            idx += 1
            geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
                guard self != nil else { return }
                if let pm = placemarks?.first {
                    if let admin = pm.administrativeArea, !admin.isEmpty {
                        uniqueAdmins.insert(admin)
                    } else if let country = pm.country, !country.isEmpty {
                        uniqueAdmins.insert(country)
                    }
                }
                // Proceed to next point
                step()
            }
        }
        step()
    }

    // Minimal ordered-set for stable joining
    private struct OrderedSet<Element: Hashable> {
        private var set: Set<Element> = []
        private(set) var array: [Element] = []
        mutating func insert(_ element: Element) {
            if set.insert(element).inserted { array.append(element) }
        }
    }

    private static func nameForGeohashLength(_ len: Int, from pm: CLPlacemark) -> String? {
        switch len {
        case 0...2:
            // Prefer administrative area if available at this coarse level
            return pm.administrativeArea ?? pm.country
        case 3...4:
            return pm.administrativeArea ?? pm.subAdministrativeArea ?? pm.country
        case 5:
            return pm.locality ?? pm.subAdministrativeArea ?? pm.administrativeArea
        case 6...7:
            return pm.subLocality ?? pm.locality ?? pm.administrativeArea
        default:
            return pm.subLocality ?? pm.locality ?? pm.administrativeArea ?? pm.country
        }
    }
    #endif

    #if DEBUG
    /// Testing-only reset helper
    func _resetForTesting() {
        bookmarks.removeAll()
        membership.removeAll()
        bookmarkNames.removeAll()
        persist()
        persistNames()
    }
    #endif
}
