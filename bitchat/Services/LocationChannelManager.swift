import Foundation

#if os(iOS)
import CoreLocation
import Combine

/// Manages location permissions, one-shot location retrieval, and computing geohash channels.
/// Not main-actor isolated to satisfy CLLocationManagerDelegate in Swift 6; state updates hop to MainActor.
final class LocationChannelManager: NSObject, CLLocationManagerDelegate, ObservableObject {
    static let shared = LocationChannelManager()

    enum PermissionState: Equatable {
        case notDetermined
        case denied
        case restricted
        case authorized
    }

    private let cl = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastLocation: CLLocation?
    private var refreshTimer: Timer?
    private let userDefaultsKey = "locationChannel.selected"
    private let teleportedStoreKey = "locationChannel.teleportedSet"
    private var isGeocoding: Bool = false

    // Published state for UI bindings
    @Published private(set) var permissionState: PermissionState = .notDetermined
    @Published private(set) var availableChannels: [GeohashChannel] = []
    @Published private(set) var selectedChannel: ChannelID = .mesh
    // True when the current location channel was selected via manual teleport
    @Published var teleported: Bool = false
    @Published private(set) var locationNames: [GeohashChannelLevel: String] = [:]

    // Persisted set of geohashes that were selected via teleport
    private var teleportedSet: Set<String> = []

    private override init() {
        super.init()
        cl.delegate = self
        cl.desiredAccuracy = kCLLocationAccuracyHundredMeters
        cl.distanceFilter = 1000 // meters; we're not tracking continuously
        // Load selection
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let channel = try? JSONDecoder().decode(ChannelID.self, from: data) {
            selectedChannel = channel
        }
        // Load persisted teleported set
        if let data = UserDefaults.standard.data(forKey: teleportedStoreKey),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            teleportedSet = Set(arr)
        }
        // Initialize teleported flag from persisted state if a location channel is selected
        if case .location(let ch) = selectedChannel {
            teleported = teleportedSet.contains(ch.geohash)
        }
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = cl.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }
        updatePermissionState(from: status)
    }

    // MARK: - Public API
    func enableLocationChannels() {
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
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
        case .authorizedAlways, .authorizedWhenInUse:
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

    /// Begin periodic one-shot location refreshes while a selector UI is visible.
    func beginLiveRefresh(interval: TimeInterval = 5.0) {
        guard permissionState == .authorized else { return }
        // Switch to a lightweight periodic one-shot request (polling) while the sheet is open
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.requestOneShotLocation()
        }
        // Kick off immediately
        requestOneShotLocation()
    }

    /// Stop periodic refreshes when selector UI is dismissed.
    func endLiveRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        cl.stopUpdatingLocation()
    }

    func select(_ channel: ChannelID) {
        Task { @MainActor in
            self.selectedChannel = channel
            if let data = try? JSONEncoder().encode(channel) {
                UserDefaults.standard.set(data, forKey: self.userDefaultsKey)
            }
            // Update teleported flag based on persisted state for immediate UI behavior
            switch channel {
            case .mesh:
                self.teleported = false
            case .location(let ch):
                self.teleported = self.teleportedSet.contains(ch.geohash)
            }
        }
    }

    // Mark or unmark a geohash as teleported in persistence and update current flag if relevant
    func markTeleported(for geohash: String, _ flag: Bool) {
        if flag { teleportedSet.insert(geohash) } else { teleportedSet.remove(geohash) }
        if let data = try? JSONEncoder().encode(Array(teleportedSet)) {
            UserDefaults.standard.set(data, forKey: teleportedStoreKey)
        }
        if case .location(let ch) = selectedChannel, ch.geohash == geohash {
            Task { @MainActor in self.teleported = flag }
        }
    }

    // MARK: - CoreLocation
    private func requestOneShotLocation() {
        cl.requestLocation()
    }

    // iOS < 14
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        updatePermissionState(from: status)
        if case .authorized = permissionState {
            requestOneShotLocation()
        }
    }

    // iOS 14+
    @available(iOS 14.0, *)
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
        reverseGeocodeIfNeeded(location: loc)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Surface as denied/restricted if relevant; otherwise keep previous state
        SecureLogger.log("LocationChannelManager: location error: \(error.localizedDescription)",
                         category: SecureLogger.session, level: .error)
    }

    // MARK: - Helpers
    private func updatePermissionState(from status: CLAuthorizationStatus) {
        let newState: PermissionState
        switch status {
        case .notDetermined: newState = .notDetermined
        case .restricted: newState = .restricted
        case .denied: newState = .denied
        case .authorizedAlways, .authorizedWhenInUse: newState = .authorized
        @unknown default: newState = .restricted
        }
        Task { @MainActor in self.permissionState = newState }
    }

    private func computeChannels(from coord: CLLocationCoordinate2D) {
        let levels = GeohashChannelLevel.allCases
        var result: [GeohashChannel] = []
        for level in levels {
            let gh = Geohash.encode(latitude: coord.latitude, longitude: coord.longitude, precision: level.precision)
            result.append(GeohashChannel(level: level, geohash: gh))
        }
        Task { @MainActor in
            self.availableChannels = result
            // Recompute teleported status based on persisted state OR current location vs selected channel
            switch self.selectedChannel {
            case .mesh:
                self.teleported = false
            case .location(let ch):
                let persisted = self.teleportedSet.contains(ch.geohash)
                let currentGH = Geohash.encode(latitude: coord.latitude, longitude: coord.longitude, precision: ch.level.precision)
                self.teleported = persisted || (currentGH != ch.geohash)
            }
        }
    }

    private func reverseGeocodeIfNeeded(location: CLLocation) {
        // Always cancel previous to keep latest fresh while user moves
        geocoder.cancelGeocode()
        isGeocoding = true
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self = self else { return }
            self.isGeocoding = false
            if let pm = placemarks?.first {
                let names = self.namesByLevel(from: pm)
                Task { @MainActor in self.locationNames = names }
            }
        }
    }

    private func namesByLevel(from pm: CLPlacemark) -> [GeohashChannelLevel: String] {
        var dict: [GeohashChannelLevel: String] = [:]
        // Region (country)
        if let country = pm.country, !country.isEmpty {
            dict[.region] = country
        }
        // Province (state/province or county)
        if let admin = pm.administrativeArea, !admin.isEmpty {
            dict[.province] = admin
        } else if let subAdmin = pm.subAdministrativeArea, !subAdmin.isEmpty {
            dict[.province] = subAdmin
        }
        // City (locality)
        if let locality = pm.locality, !locality.isEmpty {
            dict[.city] = locality
        } else if let subAdmin = pm.subAdministrativeArea, !subAdmin.isEmpty {
            dict[.city] = subAdmin
        } else if let admin = pm.administrativeArea, !admin.isEmpty {
            dict[.city] = admin
        }
        // Neighborhood
        if let subLocality = pm.subLocality, !subLocality.isEmpty {
            dict[.neighborhood] = subLocality
        } else if let locality = pm.locality, !locality.isEmpty {
            dict[.neighborhood] = locality
        }
        // Block: reuse neighborhood/locality granularity without exposing street level
        if let subLocality = pm.subLocality, !subLocality.isEmpty {
            dict[.block] = subLocality
        } else if let locality = pm.locality, !locality.isEmpty {
            dict[.block] = locality
        }
        return dict
    }
}

#endif
