import CoreLocation
import MapKit
import XCTest
@testable import bitchat

@MainActor
final class LocationStateManagerTests: XCTestCase {
    func test_loadPersistedState_normalizesBookmarksAndRestoresTeleportedSelection() async throws {
        let storage = makeStorage()
        let selected = ChannelID.location(GeohashChannel(level: .city, geohash: "u4pru"))
        storage.set(try JSONEncoder().encode(selected), forKey: "locationChannel.selected")
        storage.set(try JSONEncoder().encode(["u4pru"]), forKey: "locationChannel.teleportedSet")
        storage.set(try JSONEncoder().encode(["#U4PRU", "u4pru", ""]), forKey: "locationChannel.bookmarks")

        let manager = LocationStateManager(
            storage: storage,
            locationManager: MockLocationStateManaging(authorizationStatus: .denied),
            geocoder: MockLocationStateGeocoder(),
            shouldInitializeCoreLocation: true
        )

        let deniedLoaded = await waitUntil { manager.permissionState == .denied }
        XCTAssertTrue(deniedLoaded)
        XCTAssertEqual(manager.bookmarks, ["u4pru"])
        XCTAssertEqual(manager.selectedChannel, selected)
        let teleportedLoaded = await waitUntil { manager.teleported }
        XCTAssertTrue(teleportedLoaded)
    }

    func test_enableLocationChannels_requestsAuthorizationWhenStatusIsUndetermined() {
        let locationManager = MockLocationStateManaging(authorizationStatus: .notDetermined)
        let manager = LocationStateManager(
            storage: makeStorage(),
            locationManager: locationManager,
            geocoder: MockLocationStateGeocoder(),
            shouldInitializeCoreLocation: true
        )

        manager.enableLocationChannels()

        XCTAssertEqual(locationManager.requestAuthorizationCallCount, 1)
        XCTAssertEqual(locationManager.requestLocationCallCount, 0)
    }

    func test_enableLocationChannels_requestsOneShotLocationWhenAuthorized() async {
        let locationManager = MockLocationStateManaging(authorizationStatus: .authorizedAlways)
        let manager = LocationStateManager(
            storage: makeStorage(),
            locationManager: locationManager,
            geocoder: MockLocationStateGeocoder(),
            shouldInitializeCoreLocation: true
        )

        let authorizedLoaded = await waitUntil { manager.permissionState == .authorized }
        XCTAssertTrue(authorizedLoaded)

        manager.enableLocationChannels()

        XCTAssertEqual(locationManager.requestLocationCallCount, 1)
        XCTAssertEqual(manager.permissionState, .authorized)
    }

    func test_beginAndEndLiveRefresh_adjustLocationManagerMode() async {
        let locationManager = MockLocationStateManaging(authorizationStatus: .authorizedAlways)
        let manager = LocationStateManager(
            storage: makeStorage(),
            locationManager: locationManager,
            geocoder: MockLocationStateGeocoder(),
            shouldInitializeCoreLocation: true
        )

        let authorizedLoaded = await waitUntil { manager.permissionState == .authorized }
        XCTAssertTrue(authorizedLoaded)

        manager.beginLiveRefresh()

        XCTAssertEqual(locationManager.startUpdatingLocationCallCount, 1)
        XCTAssertEqual(locationManager.requestLocationCallCount, 1)
        XCTAssertEqual(locationManager.desiredAccuracy, kCLLocationAccuracyNearestTenMeters)
        XCTAssertEqual(locationManager.distanceFilter, TransportConfig.locationDistanceFilterLiveMeters)

        manager.endLiveRefresh()

        XCTAssertEqual(locationManager.stopUpdatingLocationCallCount, 1)
        XCTAssertEqual(locationManager.desiredAccuracy, kCLLocationAccuracyHundredMeters)
        XCTAssertEqual(locationManager.distanceFilter, TransportConfig.locationDistanceFilterMeters)
    }

    func test_permissionRevocation_endsLiveRefreshWithoutDiscardingExplicitState() async {
        let storage = makeStorage()
        let locationManager = MockLocationStateManaging(authorizationStatus: .authorizedAlways)
        let manager = LocationStateManager(
            storage: storage,
            locationManager: locationManager,
            geocoder: MockLocationStateGeocoder(),
            shouldInitializeCoreLocation: true
        )
        let authorized = await waitUntil { manager.permissionState == .authorized }
        XCTAssertTrue(authorized)

        manager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 21.2850, longitude: -157.8357)]
        )
        let channelsLoaded = await waitUntil { !manager.availableChannels.isEmpty }
        XCTAssertTrue(channelsLoaded)
        let cachedChannels = manager.availableChannels
        manager.addBookmark("u4pru")
        manager.markTeleported(for: "9q8yy", true)
        manager.select(.location(GeohashChannel(level: .city, geohash: "9q8yy")))
        let teleported = await waitUntil { manager.teleported }
        XCTAssertTrue(teleported)

        manager.beginLiveRefresh()
        XCTAssertEqual(locationManager.startUpdatingLocationCallCount, 1)

        manager.locationManager(CLLocationManager(), didChangeAuthorization: .restricted)

        let restricted = await waitUntil { manager.permissionState == .restricted }
        XCTAssertTrue(restricted)
        XCTAssertEqual(locationManager.stopUpdatingLocationCallCount, 1)
        XCTAssertEqual(locationManager.desiredAccuracy, kCLLocationAccuracyHundredMeters)
        XCTAssertEqual(locationManager.distanceFilter, TransportConfig.locationDistanceFilterMeters)
        XCTAssertEqual(manager.availableChannels, cachedChannels, "cached display state can remain")
        XCTAssertEqual(manager.bookmarks, ["u4pru"])
        XCTAssertTrue(manager.teleported, "an explicit remote selection survives device revocation")
    }

    func test_didUpdateLocations_computesChannelsAndReverseGeocodesFriendlyNames() async {
        let geocoder = MockLocationStateGeocoder()
        geocoder.enqueue(
            placemarks: [
                makePlacemark(
                    country: "United States",
                    administrativeArea: "Hawaii",
                    locality: "Honolulu",
                    subLocality: "Waikiki",
                    name: "Hilton Hawaiian Village"
                )
            ]
        )
        let manager = LocationStateManager(
            storage: makeStorage(),
            locationManager: MockLocationStateManaging(authorizationStatus: .authorizedAlways),
            geocoder: geocoder,
            shouldInitializeCoreLocation: true
        )
        let location = CLLocation(latitude: 21.2850, longitude: -157.8357)

        manager.locationManager(CLLocationManager(), didUpdateLocations: [location])

        let channelsAndNamesLoaded = await waitUntil {
            manager.availableChannels.count == GeohashChannelLevel.allCases.count &&
            manager.locationNames[.city] == "Honolulu" &&
            manager.locationNames[.building] == "Hilton Hawaiian Village"
        }
        XCTAssertTrue(channelsAndNamesLoaded)
        XCTAssertEqual(geocoder.cancelCallCount, 1)
        XCTAssertEqual(geocoder.reverseRequests.count, 1)
        XCTAssertEqual(manager.availableChannels.map(\.geohash.count), GeohashChannelLevel.allCases.map(\.precision))
        XCTAssertEqual(manager.locationNames[.region], "United States")
        XCTAssertEqual(manager.locationNames[.province], "Hawaii")
        XCTAssertEqual(manager.locationNames[.city], "Honolulu")
        XCTAssertEqual(manager.locationNames[.neighborhood], "Waikiki")
        XCTAssertEqual(manager.locationNames[.block], "Waikiki")
        XCTAssertEqual(manager.locationNames[.building], "Hilton Hawaiian Village")
    }

    func test_selectingInRegionChannel_clearsTeleportedPersistence() async {
        let storage = makeStorage()
        let manager = LocationStateManager(
            storage: storage,
            locationManager: MockLocationStateManaging(authorizationStatus: .authorizedAlways),
            geocoder: MockLocationStateGeocoder(),
            shouldInitializeCoreLocation: true
        )
        let coordinate = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let cityGeohash = Geohash.encode(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            precision: GeohashChannelLevel.city.precision
        )
        let channel = GeohashChannel(level: .city, geohash: cityGeohash)

        manager.locationManager(CLLocationManager(), didUpdateLocations: [CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)])
        let channelAvailable = await waitUntil { manager.availableChannels.contains(channel) }
        XCTAssertTrue(channelAvailable)

        manager.markTeleported(for: cityGeohash, true)
        manager.select(.location(channel))

        let selectionSettled = await waitUntil {
            manager.selectedChannel == .location(channel) && !manager.teleported
        }
        XCTAssertTrue(selectionSettled)

        let reloaded = LocationStateManager(
            storage: storage,
            locationManager: MockLocationStateManaging(authorizationStatus: .denied),
            geocoder: MockLocationStateGeocoder(),
            shouldInitializeCoreLocation: true
        )

        let reloadedDenied = await waitUntil { reloaded.permissionState == .denied }
        XCTAssertTrue(reloadedDenied)
        XCTAssertEqual(reloaded.selectedChannel, .location(channel))
        XCTAssertFalse(reloaded.teleported)
    }

    func test_loadPersistedState_migratesLowPrecisionBookmarkNamesOnce() throws {
        let storage = makeStorage()
        let staleNames = [
            "gc": "England",
            "u3": "Île-de-France",
            "u4pr": "Paris",
            "u4pruy": "Le Marais"
        ]
        storage.set(try JSONEncoder().encode(staleNames), forKey: "locationChannel.bookmarkNames")

        let migrated = LocationStateManager(
            storage: storage,
            locationManager: MockLocationStateManaging(authorizationStatus: .denied),
            geocoder: MockLocationStateGeocoder(),
            shouldInitializeCoreLocation: false
        )

        XCTAssertNil(migrated.bookmarkNames["gc"])
        XCTAssertNil(migrated.bookmarkNames["u3"])
        XCTAssertEqual(migrated.bookmarkNames["u4pr"], "Paris")
        XCTAssertEqual(migrated.bookmarkNames["u4pruy"], "Le Marais")
        XCTAssertEqual(storage.integer(forKey: "locationChannel.bookmarkNamesSchemaVersion"), 1)

        let persistedData = try XCTUnwrap(storage.data(forKey: "locationChannel.bookmarkNames"))
        let persistedNames = try JSONDecoder().decode([String: String].self, from: persistedData)
        XCTAssertEqual(persistedNames, [
            "u4pr": "Paris",
            "u4pruy": "Le Marais"
        ])

        let correctedNames = [
            "gc": "United Kingdom",
            "u4pr": "Paris"
        ]
        storage.set(try JSONEncoder().encode(correctedNames), forKey: "locationChannel.bookmarkNames")

        let reloaded = LocationStateManager(
            storage: storage,
            locationManager: MockLocationStateManaging(authorizationStatus: .denied),
            geocoder: MockLocationStateGeocoder(),
            shouldInitializeCoreLocation: false
        )

        XCTAssertEqual(reloaded.bookmarkNames["gc"], "United Kingdom")
        XCTAssertEqual(reloaded.bookmarkNames["u4pr"], "Paris")
    }

    func test_addBookmark_lowPrecisionPrefersCountryOverAdministrativeAreas() async {
        let geocoder = MockLocationStateGeocoder()
        geocoder.enqueue(placemarks: [makePlacemark(country: "United States", administrativeArea: "California")])
        geocoder.enqueue(placemarks: [makePlacemark(country: "United States", administrativeArea: "Nevada")])
        geocoder.enqueue(placemarks: [makePlacemark(country: "United States", administrativeArea: "California")])
        geocoder.enqueue(placemarks: [makePlacemark(country: "United States", administrativeArea: "Arizona")])
        geocoder.enqueue(placemarks: [makePlacemark(country: "United States", administrativeArea: "Nevada")])
        let manager = LocationStateManager(
            storage: makeStorage(),
            locationManager: MockLocationStateManaging(authorizationStatus: .denied),
            geocoder: geocoder,
            shouldInitializeCoreLocation: false
        )

        manager.addBookmark("9q")

        let bookmarkResolved = await waitUntil { manager.bookmarkNames["9q"] == "United States" }
        XCTAssertTrue(bookmarkResolved)
        XCTAssertEqual(geocoder.reverseRequests.count, 5)
        XCTAssertEqual(manager.bookmarks, ["9q"])
    }

    func test_addBookmark_lowPrecisionFallsBackToDistinctAdministrativeAreas() async {
        let geocoder = MockLocationStateGeocoder()
        geocoder.enqueue(placemarks: [makePlacemark(administrativeArea: "California")])
        geocoder.enqueue(placemarks: [makePlacemark(administrativeArea: "Nevada")])
        geocoder.enqueue(placemarks: [makePlacemark(administrativeArea: "California")])
        geocoder.enqueue(placemarks: [makePlacemark(administrativeArea: "Arizona")])
        geocoder.enqueue(placemarks: [makePlacemark(administrativeArea: "Nevada")])
        let manager = LocationStateManager(
            storage: makeStorage(),
            locationManager: MockLocationStateManaging(authorizationStatus: .denied),
            geocoder: geocoder,
            shouldInitializeCoreLocation: false
        )

        manager.addBookmark("9q")

        let bookmarkResolved = await waitUntil { manager.bookmarkNames["9q"] == "California and Nevada" }
        XCTAssertTrue(bookmarkResolved)
        XCTAssertEqual(geocoder.reverseRequests.count, 5)
    }

    func test_addBookmark_higherPrecisionStillPrefersAdministrativeArea() async {
        let geocoder = MockLocationStateGeocoder()
        geocoder.enqueue(placemarks: [makePlacemark(country: "United States", administrativeArea: "California")])
        let manager = LocationStateManager(
            storage: makeStorage(),
            locationManager: MockLocationStateManaging(authorizationStatus: .denied),
            geocoder: geocoder,
            shouldInitializeCoreLocation: false
        )

        manager.addBookmark("9q8")

        let bookmarkResolved = await waitUntil { manager.bookmarkNames["9q8"] == "California" }
        XCTAssertTrue(bookmarkResolved)
        XCTAssertEqual(geocoder.reverseRequests.count, 1)
    }

    private func makeStorage() -> UserDefaults {
        let suiteName = "LocationStateManagerTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        storage.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            storage.removePersistentDomain(forName: suiteName)
        }
        return storage
    }

    private func makePlacemark(
        country: String? = nil,
        administrativeArea: String? = nil,
        locality: String? = nil,
        subLocality: String? = nil,
        name: String? = nil
    ) -> CLPlacemark {
        var address: [String: Any] = [:]
        if let country {
            address["Country"] = country
        }
        if let administrativeArea {
            address["State"] = administrativeArea
        }
        if let locality {
            address["City"] = locality
        }
        if let subLocality {
            address["SubLocality"] = subLocality
        }
        if let name {
            address["Name"] = name
        }
        let placemark = MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: 21.2850, longitude: -157.8357),
            addressDictionary: address
        )
        return CLPlacemark(placemark: placemark)
    }

    private func waitUntil(
        timeout: TimeInterval = TestConstants.settleTimeout,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
