//
// GeoChannelCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `GeoChannelCoordinator` against a mock `GeoChannelContext` —
// proving the coordinator works without a `ChatViewModel`, following the
// `ChatDeliveryCoordinatorContextTests` exemplar.
//
// Scope note: the location/bookmark managers are real `LocationStateManager`
// instances backed by throwaway `UserDefaults` suites and mocked CoreLocation
// seams. `TorManager` has no test seam (private init singleton); sampling
// tests pin `TorManager.shared` to foreground (its default) so the
// begin-sampling branch is deterministic.
//

import Testing
import Combine
import Foundation
import CoreLocation
import Tor
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `GeoChannelContext` proving that
/// `GeoChannelCoordinator` is testable without a `ChatViewModel`.
@MainActor
private final class MockGeoChannelContext: GeoChannelContext {
    private(set) var switchedChannels: [ChannelID] = []
    private(set) var beginSamplingCalls: [[String]] = []
    private(set) var endSamplingCount = 0

    func switchLocationChannel(to channel: ChannelID) { switchedChannels.append(channel) }
    func beginGeohashSampling(for geohashes: [String]) { beginSamplingCalls.append(geohashes.sorted()) }
    func endGeohashSampling() { endSamplingCount += 1 }
}

// MARK: - CoreLocation Seams

private final class StubLocationManaging: LocationStateManaging {
    weak var delegate: CLLocationManagerDelegate?
    var desiredAccuracy: CLLocationAccuracy = 0
    var distanceFilter: CLLocationDistance = 0
    var authorizationStatus: CLAuthorizationStatus = .denied

    func requestWhenInUseAuthorization() {}
    func requestLocation() {}
    func startUpdatingLocation() {}
    func stopUpdatingLocation() {}
}

private final class StubLocationGeocoder: LocationStateGeocoding {
    func cancelGeocode() {}
    func reverseGeocodeLocation(
        _ location: CLLocation,
        completionHandler: @escaping ([CLPlacemark]?, Error?) -> Void
    ) {
        completionHandler(nil, nil)
    }
}

// MARK: - Helpers

@MainActor
private func makeLocationManager(storage: UserDefaults? = nil) -> LocationStateManager {
    let suiteName = "GeoChannelCoordinatorContextTests-\(UUID().uuidString)"
    let defaults = storage ?? UserDefaults(suiteName: suiteName)!
    if storage == nil {
        defaults.removePersistentDomain(forName: suiteName)
    }
    return LocationStateManager(
        storage: defaults,
        locationManager: StubLocationManaging(),
        geocoder: StubLocationGeocoder(),
        shouldInitializeCoreLocation: false
    )
}

/// Polls until `condition` holds, letting main-actor tasks and main-queue
/// Combine hops drain in between.
@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `GeoChannelCoordinator` against `MockGeoChannelContext` with no
/// `ChatViewModel`.
struct GeoChannelCoordinatorContextTests {

    @Test @MainActor
    func start_publishesPersistedChannelAndEndsSamplingWithoutGeohashes() async throws {
        let suiteName = "GeoChannelCoordinatorContextTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        storage.removePersistentDomain(forName: suiteName)
        let persisted = ChannelID.location(GeohashChannel(level: .city, geohash: "u4pru"))
        storage.set(try JSONEncoder().encode(persisted), forKey: "locationChannel.selected")

        let locationManager = makeLocationManager(storage: storage)
        let context = MockGeoChannelContext()
        let coordinator = GeoChannelCoordinator(
            locationManager: locationManager,
            bookmarksStore: locationManager,
            torManager: TorManager.shared,
            context: context
        )
        defer { withExtendedLifetime(coordinator) {} }

        // The persisted selection is announced and, with no regional or
        // bookmarked geohashes, sampling ends rather than begins.
        #expect(await waitUntil { !context.switchedChannels.isEmpty && context.endSamplingCount > 0 })
        #expect(context.switchedChannels.allSatisfy { $0 == persisted })
        #expect(context.beginSamplingCalls.isEmpty)
    }

    @Test @MainActor
    func selectingChannel_propagatesSwitchToContext() async {
        let locationManager = makeLocationManager()
        let context = MockGeoChannelContext()
        let coordinator = GeoChannelCoordinator(
            locationManager: locationManager,
            bookmarksStore: locationManager,
            torManager: TorManager.shared,
            context: context
        )
        defer { withExtendedLifetime(coordinator) {} }

        #expect(await waitUntil { context.switchedChannels.contains(.mesh) })

        let target = ChannelID.location(GeohashChannel(level: .neighborhood, geohash: "u4pruydq"))
        locationManager.select(target)
        #expect(await waitUntil { context.switchedChannels.last == target })
    }

    @Test @MainActor
    func bookmarkChanges_beginAndEndGeohashSampling() async {
        TorManager.shared.setAppForeground(true)
        let locationManager = makeLocationManager()
        let context = MockGeoChannelContext()
        let coordinator = GeoChannelCoordinator(
            locationManager: locationManager,
            bookmarksStore: locationManager,
            torManager: TorManager.shared,
            context: context
        )

        // No geohashes yet: only end-sampling has run.
        #expect(await waitUntil { context.endSamplingCount > 0 })
        #expect(context.beginSamplingCalls.isEmpty)

        // Bookmarking a geohash starts sampling it.
        locationManager.toggleBookmark("u4pruydq")
        #expect(await waitUntil { context.beginSamplingCalls.last == ["u4pruydq"] })

        // Removing the last bookmark ends sampling again, and a manual
        // refresh keeps reporting the empty state.
        let endCountBeforeRemoval = context.endSamplingCount
        locationManager.toggleBookmark("u4pruydq")
        #expect(await waitUntil { context.endSamplingCount > endCountBeforeRemoval })

        let endCountBeforeRefresh = context.endSamplingCount
        coordinator.refreshSampling()
        #expect(await waitUntil { context.endSamplingCount > endCountBeforeRefresh })
    }

    @Test @MainActor
    func buildingCellJoinsSamplingOnlyAfterNotesReveal() async {
        TorManager.shared.setAppForeground(true)
        let locationManager = makeLocationManager()
        let context = MockGeoChannelContext()
        let revealed = CurrentValueSubject<Bool, Never>(false)
        let coordinator = GeoChannelCoordinator(
            locationManager: locationManager,
            bookmarksStore: locationManager,
            torManager: TorManager.shared,
            notesRevealed: revealed.eraseToAnyPublisher(),
            context: context
        )
        defer { withExtendedLifetime(coordinator) {} }

        // A location fix yields all six channel levels…
        locationManager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 21.2850, longitude: -157.8357)]
        )
        #expect(await waitUntil {
            locationManager.availableChannels.contains { $0.level == .building }
        })
        let building = locationManager.availableChannels.first { $0.level == .building }!.geohash

        // …but pre-reveal sampling must exclude the building-precision cell:
        // a passive precision-8 REQ identifies a single address.
        #expect(await waitUntil {
            (context.beginSamplingCalls.last?.count ?? 0) == GeohashChannelLevel.allCases.count - 1
        })
        #expect(context.beginSamplingCalls.allSatisfy { !$0.contains(building) })

        // The explicit notes act widens sampling to include it.
        revealed.send(true)
        #expect(await waitUntil { context.beginSamplingCalls.last?.contains(building) == true })
        #expect(context.beginSamplingCalls.last?.count == GeohashChannelLevel.allCases.count)
    }

    @Test @MainActor
    func releasedContext_isHeldWeaklyAndSafelyIgnored() async {
        let locationManager = makeLocationManager()
        var context: MockGeoChannelContext? = MockGeoChannelContext()
        weak var weakContext = context
        let coordinator = GeoChannelCoordinator(
            locationManager: locationManager,
            bookmarksStore: locationManager,
            torManager: TorManager.shared,
            context: context!
        )

        #expect(await waitUntil { context?.switchedChannels.isEmpty == false })

        // The coordinator must not keep the owner alive (it is owned by it).
        context = nil
        #expect(weakContext == nil)

        // Events after the owner is gone are safely dropped.
        locationManager.select(.location(GeohashChannel(level: .city, geohash: "u4pru")))
        locationManager.toggleBookmark("u4pruydq")
        coordinator.refreshSampling()
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}
