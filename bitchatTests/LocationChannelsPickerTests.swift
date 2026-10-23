import CoreLocation
import Foundation
import Testing
@testable import bitchat

/// The location-channel picker asks for location only as its presentation
/// allows (I3). The sheet keeps today's contract: one fix and live updates
/// while it is up. The split layout's inline pane can sit on screen for
/// hours, so it only ever asks for one fix, and neither ever prompts for
/// permission: that stays the tap on the enable button.
@MainActor
struct LocationChannelsPickerTests {
    private typealias Picker = LocationChannelsPicker
    private static let permissions: [LocationChannelManager.PermissionState] = [
        .notDetermined, .denied, .restricted, .authorized
    ]

    // MARK: - The policy

    @Test
    func sheetRefreshesThenLiveUpdatesWhileUp() {
        for permission in Self.permissions {
            let refresh: [Picker.LifecycleAction] = permission == .authorized ? [.refreshChannels] : []
            #expect(Picker.lifecycleActions(for: .appear, presentation: .sheet, permission: permission)
                == refresh + [.beginLiveRefresh])
            #expect(Picker.lifecycleActions(for: .disappear, presentation: .sheet, permission: permission)
                == [.endLiveRefresh])
        }
    }

    @Test
    func permissionArrivingAsksForOneFix() {
        for permission in Self.permissions {
            #expect(Picker.lifecycleActions(for: .permissionChange, presentation: .sheet, permission: permission)
                == (permission == .authorized ? [.refreshChannels] : []))
        }
    }

    #if os(iOS)
    private static let pane = Picker.Presentation.pane(headerHeight: 44, trailingCornerReach: 0)

    @Test
    func paneOnlyEverAsksForOneFix() {
        for permission in Self.permissions {
            let refresh: [Picker.LifecycleAction] = permission == .authorized ? [.refreshChannels] : []
            #expect(Picker.lifecycleActions(for: .appear, presentation: Self.pane, permission: permission) == refresh)
            #expect(Picker.lifecycleActions(for: .disappear, presentation: Self.pane, permission: permission).isEmpty)
            #expect(Picker.lifecycleActions(for: .permissionChange, presentation: Self.pane, permission: permission) == refresh)
        }
    }
    #endif

    // MARK: - Through the location manager

    @Test
    func sheetStartsLiveUpdatesAndStopsThemOnDisappear() async {
        let fixture = await Fixture(authorizationStatus: .authorizedAlways)
        defer { fixture.tearDown() }
        let location = fixture.location

        Picker.perform(.appear, presentation: .sheet, permission: fixture.model.permissionState, on: fixture.model)
        // One fix for the refresh, one as live updates begin.
        #expect(location.requestLocationCallCount == 2)
        #expect(location.startUpdatingLocationCallCount == 1)

        Picker.perform(.disappear, presentation: .sheet, permission: fixture.model.permissionState, on: fixture.model)
        #expect(location.stopUpdatingLocationCallCount == 1)
        #expect(location.requestAuthorizationCallCount == 0)
    }

    @Test
    func sheetNeverPromptsForPermission() async {
        let fixture = await Fixture(authorizationStatus: .notDetermined)
        defer { fixture.tearDown() }
        let location = fixture.location

        for event in [Picker.LifecycleEvent.appear, .permissionChange, .disappear] {
            Picker.perform(event, presentation: .sheet, permission: fixture.model.permissionState, on: fixture.model)
        }

        #expect(location.requestAuthorizationCallCount == 0)
        #expect(location.requestLocationCallCount == 0)
        #expect(location.startUpdatingLocationCallCount == 0)
    }

    #if os(iOS)
    @Test
    func paneWithoutPermissionAsksForNothing() async {
        for status in [CLAuthorizationStatus.notDetermined, .denied, .restricted] {
            let fixture = await Fixture(authorizationStatus: status)
            defer { fixture.tearDown() }
            let location = fixture.location
            let stopsBefore = location.stopUpdatingLocationCallCount

            for event in [Picker.LifecycleEvent.appear, .permissionChange, .disappear] {
                Picker.perform(event, presentation: Self.pane, permission: fixture.model.permissionState, on: fixture.model)
            }

            #expect(location.requestAuthorizationCallCount == 0, "\(status.rawValue)")
            #expect(location.requestLocationCallCount == 0, "\(status.rawValue)")
            #expect(location.startUpdatingLocationCallCount == 0, "\(status.rawValue)")
            #expect(location.stopUpdatingLocationCallCount == stopsBefore, "\(status.rawValue)")
        }
    }

    @Test
    func paneWithPermissionAsksForExactlyOneFix() async {
        let fixture = await Fixture(authorizationStatus: .authorizedAlways)
        defer { fixture.tearDown() }
        let location = fixture.location

        Picker.perform(.appear, presentation: Self.pane, permission: fixture.model.permissionState, on: fixture.model)
        #expect(location.requestLocationCallCount == 1)

        Picker.perform(.disappear, presentation: Self.pane, permission: fixture.model.permissionState, on: fixture.model)
        #expect(location.requestLocationCallCount == 1)
        #expect(location.startUpdatingLocationCallCount == 0)
        #expect(location.stopUpdatingLocationCallCount == 0)
        #expect(location.requestAuthorizationCallCount == 0)
    }

    @Test
    func paneAsksForOneFixWhenPermissionArrives() async {
        let fixture = await Fixture(authorizationStatus: .notDetermined)
        defer { fixture.tearDown() }
        let location = fixture.location
        Picker.perform(.appear, presentation: Self.pane, permission: fixture.model.permissionState, on: fixture.model)

        // The person grants it through the enable button.
        location.authorizationStatus = .authorizedAlways
        fixture.manager.locationManager(CLLocationManager(), didChangeAuthorization: .authorizedAlways)
        let authorized = await TestHelpers.waitUntil(
            { fixture.model.permissionState == .authorized },
            timeout: TestConstants.settleTimeout
        )
        #expect(authorized)
        let fixesBefore = location.requestLocationCallCount

        Picker.perform(.permissionChange, presentation: Self.pane, permission: fixture.model.permissionState, on: fixture.model)

        #expect(location.requestLocationCallCount == fixesBefore + 1)
        #expect(location.startUpdatingLocationCallCount == 0)
        #expect(location.requestAuthorizationCallCount == 0)
    }

    /// E7: choosing the selected channel again only ends browsing, so the
    /// choice is matched by cell, whatever level it arrives with.
    @Test
    func choicesMatchTheSelectionByGeohash() {
        let city = GeohashChannel(level: .city, geohash: "u4pru")
        #expect(Picker.isSelected(geohash: nil, in: .mesh))
        #expect(!Picker.isSelected(geohash: "u4pru", in: .mesh))
        #expect(!Picker.isSelected(geohash: nil, in: .location(city)))
        #expect(Picker.isSelected(geohash: "u4pru", in: .location(city)))
        #expect(Picker.isSelected(geohash: "U4PRU", in: .location(GeohashChannel(level: .block, geohash: "u4pru"))))
        #expect(!Picker.isSelected(geohash: "u4prv", in: .location(city)))
    }
    #endif
}

/// A `LocationChannelsModel` over a real `LocationStateManager` whose
/// CoreLocation seam is the shared mock.
@MainActor
private struct Fixture {
    let location: MockLocationStateManaging
    let manager: LocationStateManager
    let model: LocationChannelsModel
    private let suiteName: String

    init(authorizationStatus: CLAuthorizationStatus) async {
        suiteName = "LocationChannelsPickerTests.\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName) ?? .standard
        location = MockLocationStateManaging(authorizationStatus: authorizationStatus)
        manager = LocationStateManager(
            storage: storage,
            locationManager: location,
            geocoder: MockLocationStateGeocoder(),
            shouldInitializeCoreLocation: true
        )
        model = LocationChannelsModel(manager: manager)

        let expected: LocationChannelManager.PermissionState
        switch authorizationStatus {
        case .notDetermined: expected = .notDetermined
        case .denied: expected = .denied
        case .restricted: expected = .restricted
        default: expected = .authorized
        }
        let model = model
        let manager = manager
        let settled = await TestHelpers.waitUntil(
            { manager.permissionState == expected && model.permissionState == expected },
            timeout: TestConstants.settleTimeout
        )
        #expect(settled)
    }

    func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }
}
