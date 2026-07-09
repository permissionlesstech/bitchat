import Combine
import CoreLocation
import XCTest
@testable import bitchat

/// Tap-to-reveal privacy contract: the nearby-notes counter must not open a
/// building-precision relay REQ until one explicit act calls `reveal()`, and
/// the pooled subscription must come up exactly once and go down exactly once.
@MainActor
final class NearbyNotesCounterTests: XCTestCase {
    private var previousNotesEnabled: Any?

    override func setUp() {
        super.setUp()
        previousNotesEnabled = UserDefaults.standard.object(forKey: "locationNotes.enabled")
        UserDefaults.standard.set(true, forKey: "locationNotes.enabled")
    }

    override func tearDown() {
        if let previous = previousNotesEnabled as? Bool {
            UserDefaults.standard.set(previous, forKey: "locationNotes.enabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "locationNotes.enabled")
        }
        super.tearDown()
    }

    func test_counterOnlySubscribesAfterReveal_countsUnexpiredNotes_andUnsubscribesOnDeactivate() async throws {
        let relays = SubscriptionRecorder()
        let locationManager = try await makeAuthorizedLocationManager()
        let buildingGeohash = try XCTUnwrap(
            locationManager.availableChannels.first(where: { $0.level == .building })?.geohash
        )

        let counter = NearbyNotesCounter(
            locationManager: locationManager,
            managerFactory: { LocationNotesManager(geohash: $0, dependencies: relays.dependencies) },
            releaseManager: { $0?.cancel() }
        )

        counter.activate()
        // Let the availableChannels replay and any queued retargets land:
        // being active is not consent, so still no REQ.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(relays.subscribeCount, 0)
        XCTAssertFalse(counter.revealed)

        counter.reveal()

        XCTAssertTrue(counter.revealed)
        XCTAssertEqual(relays.subscribeCount, 1)
        let gTags = try XCTUnwrap(geohashTagFilter(of: XCTUnwrap(relays.lastFilter)))
        XCTAssertEqual(gTags.count, 9)
        XCTAssertEqual(
            Set(gTags),
            Set([buildingGeohash] + Geohash.neighbors(of: buildingGeohash)),
            "REQ must cover the building geohash plus its 8 neighbors"
        )

        // An expired NIP-40 note must never count.
        let identity = try NostrIdentity.generate()
        let now = Date()
        let expired = NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: now.addingTimeInterval(-3600),
            kind: .textNote,
            tags: [["g", buildingGeohash], ["expiration", String(Int(now.timeIntervalSince1970) - 60)]],
            content: "gone"
        )
        relays.lastHandler?(try expired.sign(with: identity.schnorrSigningKey()))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(counter.noteCount, 0)

        // A live matching kind-1 note drives the count to 1.
        let live = NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: now,
            kind: .textNote,
            tags: [["g", buildingGeohash]],
            content: "still here"
        )
        relays.lastHandler?(try live.sign(with: identity.schnorrSigningKey()))
        let counted = await waitUntil { counter.noteCount == 1 }
        XCTAssertTrue(counted)
        // Still exactly one REQ after all the async retarget re-entries.
        XCTAssertEqual(relays.subscribeCount, 1)

        counter.deactivate()

        XCTAssertEqual(relays.unsubscribeCount, 1)
        XCTAssertEqual(counter.noteCount, 0)
    }

    func test_checkNotesHint_requiresAuthorizedLocationPermission() {
        let relays = SubscriptionRecorder()
        let counter = NearbyNotesCounter(
            locationManager: makeBareLocationManager(),
            managerFactory: { LocationNotesManager(geohash: $0, dependencies: relays.dependencies) },
            releaseManager: { $0?.cancel() }
        )

        // An unauthorized install must never see the hint: the tap can't
        // subscribe (retarget requires authorization) and must not prompt,
        // so offering it would be a silent dead-end for the session.
        XCTAssertFalse(counter.offersRevealHint(permissionState: .notDetermined))
        XCTAssertFalse(counter.offersRevealHint(permissionState: .denied))
        XCTAssertFalse(counter.offersRevealHint(permissionState: .restricted))
        XCTAssertTrue(counter.offersRevealHint(permissionState: .authorized))

        // The app-info kill switch hides it too.
        LocationNotesSettings.enabled = false
        XCTAssertFalse(counter.offersRevealHint(permissionState: .authorized))
        LocationNotesSettings.enabled = true

        // Once revealed, the hint yields to the live strip and count.
        counter.reveal()
        XCTAssertFalse(counter.offersRevealHint(permissionState: .authorized))
        XCTAssertEqual(relays.subscribeCount, 0, "reveal without authorization must not open a REQ")
    }

    func test_noticesSheet_revealsOnlyOnExplicitGeoTabSelectionWithScope() {
        // The sheet reveals the local counter only when the person actively
        // picks the geo tab and the sheet actually has a geo scope —
        // auto-landing on geo (initial tab) never calls this path at all.
        XCTAssertTrue(NoticesView.revealsNearbyNotes(onSwitchingTo: .geo, geoGeohash: "u4pruydq"))
        XCTAssertFalse(NoticesView.revealsNearbyNotes(onSwitchingTo: .geo, geoGeohash: nil))
        XCTAssertFalse(NoticesView.revealsNearbyNotes(onSwitchingTo: .mesh, geoGeohash: "u4pruydq"))
    }

    func test_pool_sharesOneManagerPerGeohash_andCancelsOnLastRelease() {
        let relays = SubscriptionRecorder()
        let pool = LocationNotesPool(
            makeManager: { LocationNotesManager(geohash: $0, dependencies: relays.dependencies) }
        )

        let first = pool.acquire("u4pruydq")
        let second = pool.acquire("U4PRUYDQ")

        XCTAssertTrue(first === second, "same geohash (case-insensitive) must share one manager")
        XCTAssertEqual(relays.subscribeCount, 1)

        pool.release(first)

        XCTAssertEqual(relays.unsubscribeCount, 0, "first release keeps the shared REQ live")
        XCTAssertNotEqual(first.state, .idle)

        pool.release(second)

        XCTAssertEqual(relays.unsubscribeCount, 1)
        XCTAssertEqual(first.state, .idle)

        // An instance the pool never owned (test-injected) degrades to cancel.
        let stray = LocationNotesManager(geohash: "u4pruydp", dependencies: relays.dependencies)
        pool.release(stray)
        XCTAssertEqual(relays.unsubscribeCount, 2)
        XCTAssertEqual(stray.state, .idle)
    }

    func test_pool_reacquireAfterFullRelease_bringsSubscriptionBackUp() {
        let relays = SubscriptionRecorder()
        let pool = LocationNotesPool(
            makeManager: { LocationNotesManager(geohash: $0, dependencies: relays.dependencies) }
        )

        // The notices sheet's geo → mesh → geo cycle: switching to mesh
        // releases (REQ goes down), switching back re-acquires (fresh REQ),
        // with exactly one live REQ at any point.
        let first = pool.acquire("u4pruydq")
        XCTAssertEqual(relays.subscribeCount, 1)

        pool.release(first)
        XCTAssertEqual(relays.unsubscribeCount, 1)
        XCTAssertEqual(first.state, .idle)

        let second = pool.acquire("u4pruydq")
        XCTAssertEqual(relays.subscribeCount, 2)
        XCTAssertNotEqual(second.state, .idle)

        // Dismissal after the round trip releases once more — no double
        // unsubscribe from the earlier tab-switch release.
        pool.release(second)
        XCTAssertEqual(relays.unsubscribeCount, 2)
    }

    // MARK: - Helpers

    /// A LocationStateManager that never touches CoreLocation; for tests
    /// that don't need channels or authorization.
    private func makeBareLocationManager() -> LocationStateManager {
        let suiteName = "NearbyNotesCounterTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        storage.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            storage.removePersistentDomain(forName: suiteName)
        }
        return LocationStateManager(
            storage: storage,
            locationManager: MockLocationManager(authorizationStatus: .denied),
            geocoder: MockLocationGeocoder(),
            shouldInitializeCoreLocation: false
        )
    }

    /// An authorized LocationStateManager whose availableChannels carry a
    /// real building-level geohash (Honolulu), built over CoreLocation mocks.
    private func makeAuthorizedLocationManager() async throws -> LocationStateManager {
        let suiteName = "NearbyNotesCounterTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        storage.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            storage.removePersistentDomain(forName: suiteName)
        }

        let manager = LocationStateManager(
            storage: storage,
            locationManager: MockLocationManager(authorizationStatus: .authorizedAlways),
            geocoder: MockLocationGeocoder(),
            shouldInitializeCoreLocation: true
        )
        let authorized = await waitUntil { manager.permissionState == .authorized }
        XCTAssertTrue(authorized)

        manager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 21.2850, longitude: -157.8357)]
        )
        let channelsLoaded = await waitUntil {
            manager.availableChannels.contains { $0.level == .building }
        }
        XCTAssertTrue(channelsLoaded)
        return manager
    }

    /// The filter's `g` tag values, read through its NIP-01 wire encoding
    /// (the stored tag filters aren't visible outside the Nostr layer).
    private func geohashTagFilter(of filter: NostrFilter) throws -> [String]? {
        let data = try JSONEncoder().encode(filter)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return json["#g"] as? [String]
    }

    private func waitUntil(
        timeout: TimeInterval = 1.0,
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

/// Stub relay layer: counts REQs, captures the last filter/handler, and never
/// touches the network.
@MainActor
private final class SubscriptionRecorder {
    private(set) var subscribeCount = 0
    private(set) var unsubscribeCount = 0
    private(set) var lastFilter: NostrFilter?
    private(set) var lastHandler: ((NostrEvent) -> Void)?

    var dependencies: LocationNotesDependencies {
        LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { [weak self] filter, _, _, handler, _ in
                self?.subscribeCount += 1
                self?.lastFilter = filter
                self?.lastHandler = handler
            },
            unsubscribe: { [weak self] _ in
                self?.unsubscribeCount += 1
            },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in try NostrIdentity.generate() },
            now: { Date() }
        )
    }
}

private final class MockLocationManager: LocationStateManaging {
    weak var delegate: CLLocationManagerDelegate?
    var desiredAccuracy: CLLocationAccuracy = 0
    var distanceFilter: CLLocationDistance = 0
    var authorizationStatus: CLAuthorizationStatus

    init(authorizationStatus: CLAuthorizationStatus) {
        self.authorizationStatus = authorizationStatus
    }

    func requestWhenInUseAuthorization() {}
    func requestLocation() {}
    func startUpdatingLocation() {}
    func stopUpdatingLocation() {}
}

private final class MockLocationGeocoder: LocationStateGeocoding {
    func cancelGeocode() {}

    func reverseGeocodeLocation(
        _ location: CLLocation,
        completionHandler: @escaping ([CLPlacemark]?, Error?) -> Void
    ) {
        completionHandler(nil, nil)
    }
}
