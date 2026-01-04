import BitLogger
import Foundation
import Combine

#if os(iOS) || os(macOS)
import CoreLocation

/// Unified manager for location-based channel state including:
/// - CoreLocation permissions and one-shot location retrieval
/// - Geohash channel computation from coordinates
/// - Channel selection and teleport state
/// - Bookmark persistence and friendly name resolution
///
/// Consolidates LocationChannelManager + GeohashBookmarksStore into a single source of truth.
final class LocationStateManager: NSObject, CLLocationManagerDelegate, ObservableObject {
    static let shared = LocationStateManager()

    // MARK: - Permission State

    enum PermissionState: Equatable {
        case notDetermined
        case denied
        case restricted
        case authorized
    }

    // MARK: - Private Properties (CoreLocation)

    private let cl = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastLocation: CLLocation?
    private var refreshTimer: Timer?
    private var isGeocoding: Bool = false

    // MARK: - Persistence Keys

    private let selectedChannelKey = "locationChannel.selected"
    private let teleportedStoreKey = "locationChannel.teleportedSet"
    private let bookmarksKey = "locationChannel.bookmarks"
    private let bookmarkNamesKey = "locationChannel.bookmarkNames"

    // MARK: - Published State (Channel)

    @Published private(set) var permissionState: PermissionState = .notDetermined
    @Published private(set) var availableChannels: [GeohashChannel] = []
    @Published private(set) var selectedChannel: ChannelID = .mesh
    @Published var teleported: Bool = false
    @Published private(set) var locationNames: [GeohashChannelLevel: String] = [:]

    // MARK: - Published State (Bookmarks)

    @Published private(set) var bookmarks: [String] = []
    @Published private(set) var bookmarkNames: [String: String] = [:]

    // MARK: - Private State

    private var teleportedSet: Set<String> = []
    private var bookmarkMembership: Set<String> = []
    private var resolvingNames: Set<String> = []
    private let storage: UserDefaults

    /// Returns true if running in test environment
    private static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return NSClassFromString("XCTestCase") != nil ||
               env["XCTestConfigurationFilePath"] != nil ||
               env["XCTestBundlePath"] != nil ||
               env["GITHUB_ACTIONS"] != nil ||
               env["CI"] != nil
    }

    // MARK: - Initialization

    private override init() {
        self.storage = .standard
        super.init()

        // Skip CoreLocation setup in test environments
        guard !Self.isRunningTests else {
            loadPersistedState()
            return
        }

        cl.delegate = self
        cl.desiredAccuracy = kCLLocationAccuracyHundredMeters
        cl.distanceFilter = TransportConfig.locationDistanceFilterMeters

        loadPersistedState()
        initializePermissionState()
    }

    /// Internal initializer for testing with custom storage
    init(storage: UserDefaults) {
        self.storage = storage
        super.init()
        loadPersistedState()
    }

    private func loadPersistedState() {
        // Load selected channel
        if let data = storage.data(forKey: selectedChannelKey),
           let channel = try? JSONDecoder().decode(ChannelID.self, from: data) {
            selectedChannel = channel
        }

        // Load teleported set
        if let data = storage.data(forKey: teleportedStoreKey),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            teleportedSet = Set(arr)
        }

        // Load bookmarks
        if let data = storage.data(forKey: bookmarksKey),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            var seen = Set<String>()
            var list: [String] = []
            for raw in arr {
                let gh = Self.normalizeGeohash(raw)
                guard !gh.isEmpty, !seen.contains(gh) else { continue }
                seen.insert(gh)
                list.append(gh)
            }
            bookmarks = list
            bookmarkMembership = seen
        }

        // Load bookmark names
        if let data = storage.data(forKey: bookmarkNamesKey),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            bookmarkNames = dict
        }
    }

    private func initializePermissionState() {
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, macOS 11.0, *) {
            status = cl.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }
        updatePermissionState(from: status)

        // Fall back to persisted teleport state if no location authorization
        switch status {
        case .authorizedAlways, .authorizedWhenInUse, .authorized:
            break
        case .notDetermined, .restricted, .denied:
            fallthrough
        @unknown default:
            if case .location(let ch) = selectedChannel {
                teleported = teleportedSet.contains(ch.geohash)
            }
        }
    }

    // MARK: - Public API (Permissions & Location)

    func enableLocationChannels() {
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, macOS 11.0, *) {
            status = cl.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }
        switch status {
        case .notDetermined:
            cl.requestWhenInUseAuthorization()
        case .restricted:
            Task { @MainActor in self.permissionState = .restricted }
        case .denied:
            Task { @MainActor in self.permissionState = .denied }
        case .authorizedAlways, .authorizedWhenInUse, .authorized:
            Task { @MainActor in self.permissionState = .authorized }
            requestOneShotLocation()
        @unknown default:
            Task { @MainActor in self.permissionState = .restricted }
        }
    }

    func refreshChannels() {
        if permissionState == .authorized {
            requestOneShotLocation()
        }
    }

    func beginLiveRefresh(interval: TimeInterval = TransportConfig.locationLiveRefreshInterval) {
        guard permissionState == .authorized else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
        cl.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        cl.distanceFilter = TransportConfig.locationDistanceFilterLiveMeters
        cl.startUpdatingLocation()
        requestOneShotLocation()
    }

    func endLiveRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        cl.stopUpdatingLocation()
        cl.desiredAccuracy = kCLLocationAccuracyHundredMeters
        cl.distanceFilter = TransportConfig.locationDistanceFilterMeters
    }

    // MARK: - Public API (Channel Selection)

    func select(_ channel: ChannelID) {
        Task { @MainActor in
            self.selectedChannel = channel
            if let data = try? JSONEncoder().encode(channel) {
                self.storage.set(data, forKey: self.selectedChannelKey)
            }

            switch channel {
            case .mesh:
                self.teleported = false
            case .location(let ch):
                let inRegional = self.availableChannels.contains { $0.geohash == ch.geohash }
                if inRegional {
                    self.teleported = false
                    if self.teleportedSet.contains(ch.geohash) {
                        self.teleportedSet.remove(ch.geohash)
                        self.persistTeleportedSet()
                    }
                } else {
                    self.teleported = self.teleportedSet.contains(ch.geohash)
                }
            }
        }
    }

    func markTeleported(for geohash: String, _ flag: Bool) {
        if flag {
            teleportedSet.insert(geohash)
        } else {
            teleportedSet.remove(geohash)
        }
        persistTeleportedSet()
        if case .location(let ch) = selectedChannel, ch.geohash == geohash {
            Task { @MainActor in self.teleported = flag }
        }
    }

    // MARK: - Public API (Bookmarks)

    func isBookmarked(_ geohash: String) -> Bool {
        bookmarkMembership.contains(Self.normalizeGeohash(geohash))
    }

    func toggleBookmark(_ geohash: String) {
        let gh = Self.normalizeGeohash(geohash)
        if bookmarkMembership.contains(gh) {
            removeBookmark(gh)
        } else {
            addBookmark(gh)
        }
    }

    func addBookmark(_ geohash: String) {
        let gh = Self.normalizeGeohash(geohash)
        guard !gh.isEmpty, !bookmarkMembership.contains(gh) else { return }
        bookmarks.insert(gh, at: 0)
        bookmarkMembership.insert(gh)
        persistBookmarks()
        resolveBookmarkNameIfNeeded(for: gh)
    }

    func removeBookmark(_ geohash: String) {
        let gh = Self.normalizeGeohash(geohash)
        guard bookmarkMembership.contains(gh) else { return }
        if let idx = bookmarks.firstIndex(of: gh) {
            bookmarks.remove(at: idx)
        }
        bookmarkMembership.remove(gh)
        if bookmarkNames.removeValue(forKey: gh) != nil {
            persistBookmarkNames()
        }
        persistBookmarks()
    }

    // MARK: - CLLocationManagerDelegate

    private func requestOneShotLocation() {
        cl.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        updatePermissionState(from: status)
        if case .authorized = permissionState {
            requestOneShotLocation()
        }
    }

    @available(iOS 14.0, macOS 11.0, *)
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updatePermissionState(from: manager.authorizationStatus)
        if case .authorized = permissionState {
            requestOneShotLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lastLocation = loc
        computeChannels(from: loc.coordinate)
        reverseGeocodeLocation(loc)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        SecureLogger.error("LocationStateManager: location error: \(error.localizedDescription)", category: .session)
    }

    // MARK: - Private Helpers (Permission)

    private func updatePermissionState(from status: CLAuthorizationStatus) {
        let newState: PermissionState
        switch status {
        case .notDetermined: newState = .notDetermined
        case .restricted: newState = .restricted
        case .denied: newState = .denied
        case .authorizedAlways, .authorizedWhenInUse, .authorized: newState = .authorized
        @unknown default: newState = .restricted
        }
        Task { @MainActor in self.permissionState = newState }
    }

    // MARK: - Private Helpers (Channel Computation)

    private func computeChannels(from coord: CLLocationCoordinate2D) {
        let levels = GeohashChannelLevel.allCases
        var result: [GeohashChannel] = []
        for level in levels {
            let gh = Geohash.encode(latitude: coord.latitude, longitude: coord.longitude, precision: level.precision)
            result.append(GeohashChannel(level: level, geohash: gh))
        }
        Task { @MainActor in
            self.availableChannels = result
            switch self.selectedChannel {
            case .mesh:
                self.teleported = false
            case .location(let ch):
                let inRegional = result.contains { $0.geohash == ch.geohash }
                if inRegional {
                    self.teleported = false
                    if self.teleportedSet.contains(ch.geohash) {
                        self.teleportedSet.remove(ch.geohash)
                        self.persistTeleportedSet()
                    }
                } else {
                    self.teleported = true
                }
            }
        }
    }

    // MARK: - Private Helpers (Geocoding)

    private func reverseGeocodeLocation(_ location: CLLocation) {
        geocoder.cancelGeocode()
        isGeocoding = true
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let self = self else { return }
            self.isGeocoding = false
            if let pm = placemarks?.first {
                let names = self.locationNamesByLevel(from: pm)
                Task { @MainActor in self.locationNames = names }
            }
        }
    }

    private func locationNamesByLevel(from pm: CLPlacemark) -> [GeohashChannelLevel: String] {
        var dict: [GeohashChannelLevel: String] = [:]
        if let country = pm.country, !country.isEmpty {
            dict[.region] = country
        }
        if let admin = pm.administrativeArea, !admin.isEmpty {
            dict[.province] = admin
        } else if let subAdmin = pm.subAdministrativeArea, !subAdmin.isEmpty {
            dict[.province] = subAdmin
        }
        if let locality = pm.locality, !locality.isEmpty {
            dict[.city] = locality
        } else if let subAdmin = pm.subAdministrativeArea, !subAdmin.isEmpty {
            dict[.city] = subAdmin
        } else if let admin = pm.administrativeArea, !admin.isEmpty {
            dict[.city] = admin
        }
        if let subLocality = pm.subLocality, !subLocality.isEmpty {
            dict[.neighborhood] = subLocality
        } else if let locality = pm.locality, !locality.isEmpty {
            dict[.neighborhood] = locality
        }
        if let subLocality = pm.subLocality, !subLocality.isEmpty {
            dict[.block] = subLocality
        } else if let locality = pm.locality, !locality.isEmpty {
            dict[.block] = locality
        }
        if let name = pm.name, !name.isEmpty {
            dict[.building] = name
        } else if let thoroughfare = pm.thoroughfare, !thoroughfare.isEmpty {
            dict[.building] = thoroughfare
        }
        return dict
    }

    func resolveBookmarkNameIfNeeded(for geohash: String) {
        let gh = Self.normalizeGeohash(geohash)
        guard !gh.isEmpty, bookmarkNames[gh] == nil, !resolvingNames.contains(gh) else { return }
        resolvingNames.insert(gh)

        if gh.count <= 2 {
            let b = Geohash.decodeBounds(gh)
            let pts: [CLLocation] = [
                CLLocation(latitude: (b.latMin + b.latMax) / 2, longitude: (b.lonMin + b.lonMax) / 2),
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
                defer { self.resolvingNames.remove(gh) }
                if let pm = placemarks?.first,
                   let name = Self.nameForGeohashLength(gh.count, from: pm),
                   !name.isEmpty {
                    DispatchQueue.main.async {
                        self.bookmarkNames[gh] = name
                        self.persistBookmarkNames()
                    }
                }
            }
        }
    }

    private func resolveCompositeAdminName(geohash gh: String, points: [CLLocation]) {
        var uniqueAdmins: [String] = []
        var seenAdmins = Set<String>()
        var idx = 0

        func step() {
            if idx >= points.count {
                let finalName: String? = {
                    if uniqueAdmins.count >= 2 { return uniqueAdmins[0] + " and " + uniqueAdmins[1] }
                    return uniqueAdmins.first
                }()
                if let finalName = finalName, !finalName.isEmpty {
                    DispatchQueue.main.async {
                        self.bookmarkNames[gh] = finalName
                        self.persistBookmarkNames()
                    }
                }
                self.resolvingNames.remove(gh)
                return
            }
            let loc = points[idx]
            idx += 1
            geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
                guard self != nil else { return }
                if let pm = placemarks?.first {
                    if let admin = pm.administrativeArea, !admin.isEmpty, !seenAdmins.contains(admin) {
                        seenAdmins.insert(admin)
                        uniqueAdmins.append(admin)
                    } else if let country = pm.country, !country.isEmpty, !seenAdmins.contains(country) {
                        seenAdmins.insert(country)
                        uniqueAdmins.append(country)
                    }
                }
                step()
            }
        }
        step()
    }

    private static func nameForGeohashLength(_ len: Int, from pm: CLPlacemark) -> String? {
        switch len {
        case 0...2:
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

    // MARK: - Private Helpers (Persistence)

    private func persistTeleportedSet() {
        if let data = try? JSONEncoder().encode(Array(teleportedSet)) {
            storage.set(data, forKey: teleportedStoreKey)
        }
    }

    private func persistBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            storage.set(data, forKey: bookmarksKey)
        }
    }

    private func persistBookmarkNames() {
        if let data = try? JSONEncoder().encode(bookmarkNames) {
            storage.set(data, forKey: bookmarkNamesKey)
        }
    }

    private static func normalizeGeohash(_ s: String) -> String {
        let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
        return s
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "#", with: "")
            .filter { allowed.contains($0) }
    }
}

// MARK: - Backward Compatibility Typealiases

typealias LocationChannelManager = LocationStateManager
typealias GeohashBookmarksStore = LocationStateManager

// MARK: - Backward Compatibility Extensions

extension LocationStateManager {
    /// Backward compatibility: toggle bookmark (was GeohashBookmarksStore.toggle)
    func toggle(_ geohash: String) {
        toggleBookmark(geohash)
    }

    /// Backward compatibility: add bookmark (was GeohashBookmarksStore.add)
    func add(_ geohash: String) {
        addBookmark(geohash)
    }

    /// Backward compatibility: remove bookmark (was GeohashBookmarksStore.remove)
    func remove(_ geohash: String) {
        removeBookmark(geohash)
    }
}
#endif
