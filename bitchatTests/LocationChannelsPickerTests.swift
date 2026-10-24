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
    private static let pane = Picker.Presentation.pane(headerHeight: 44, trailingCornerReach: 0, panicEpoch: 0)

    @Test
    func paneOnlyEverAsksForOneFix() {
        for permission in Self.permissions {
            let refresh: [Picker.LifecycleAction] = permission == .authorized ? [.refreshChannels] : []
            #expect(Picker.lifecycleActions(for: .appear, presentation: Self.pane, permission: permission) == refresh)
            #expect(Picker.lifecycleActions(for: .disappear, presentation: Self.pane, permission: permission).isEmpty)
            #expect(Picker.lifecycleActions(for: .permissionChange, presentation: Self.pane, permission: permission) == refresh)
            #expect(Picker.lifecycleActions(for: .retry, presentation: Self.pane, permission: permission) == refresh)
        }
    }

    /// I4: the pane outlives a panic wipe. What it listed came from a fix
    /// taken before the wipe, so it asks for one more, as when it appears.
    /// The sheet never sees a wipe: the wipe closes it.
    @Test
    func panicWipeAsksThePaneForOneFreshFix() {
        for permission in Self.permissions {
            #expect(Picker.lifecycleActions(for: .panicWipe, presentation: Self.pane, permission: permission)
                == (permission == .authorized ? [.refreshChannels] : []))
            #expect(Picker.lifecycleActions(for: .panicWipe, presentation: .sheet, permission: permission).isEmpty)
        }
    }

    /// E8: continuous updates ending elsewhere (the location sheet closing
    /// as the device unfolds, or the notices) also cancel a one-shot fix
    /// still on its way, so the pane asks for its fix again. The sheet's
    /// own ending asks for nothing.
    @Test
    func liveUpdatesEndingElsewhereAskThePaneForItsFixAgain() {
        for permission in Self.permissions {
            #expect(Picker.lifecycleActions(for: .liveRefreshEnded, presentation: Self.pane, permission: permission)
                == (permission == .authorized ? [.refreshChannels] : []))
            #expect(Picker.lifecycleActions(for: .liveRefreshEnded, presentation: .sheet, permission: permission).isEmpty)
        }
    }

    // MARK: - Choices

    /// The sheet selects whatever is chosen and closes at once, as ever.
    @Test
    func sheetSelectsEveryChoice() {
        let city = ChannelID.location(GeohashChannel(level: .city, geohash: "u4pru"))
        for selected in [ChannelID.mesh, city] {
            for geohash in [String?.none, "u4pru", "9q8yy"] {
                #expect(Picker.selects(ofGeohash: geohash, presentation: .sheet, selected: selected))
            }
        }
    }

    /// E7: the pane selects every choice but the selection itself, which
    /// only ends browsing.
    @Test
    func paneSelectsEveryChoiceButTheSelection() {
        let city = ChannelID.location(GeohashChannel(level: .city, geohash: "u4pru"))

        // The selected geohash again, at any level or case: no select (no
        // resubscribe).
        #expect(!Picker.selects(ofGeohash: "u4pru", presentation: Self.pane, selected: city))
        #expect(!Picker.selects(
            ofGeohash: "U4PRU",
            presentation: Self.pane,
            selected: .location(GeohashChannel(level: .block, geohash: "u4pru"))
        ))

        // Browsing away from it: another geohash, or #mesh.
        for geohash in [String?.none, "9q8yy", "u4pr"] {
            #expect(Picker.selects(ofGeohash: geohash, presentation: Self.pane, selected: city))
        }

        // The idle pane.
        #expect(Picker.selects(ofGeohash: "9q8yy", presentation: Self.pane, selected: .mesh))
        // (#mesh isn't listed there; were it chosen, it is the selection.)
        #expect(!Picker.selects(ofGeohash: nil, presentation: Self.pane, selected: .mesh))
    }

    // MARK: - A fix that never comes

    /// The pane asks for one fix; once that has had its chance it stops
    /// promising one and offers a retry. The sheet's live updates keep
    /// trying, so it keeps its spinner. No permission: the hint, always.
    @Test
    func paneStopsPromisingAFixThatNeverCame() {
        let asked = Date(timeIntervalSince1970: 1_000_000)
        let patience = Picker.nearbyFixPatience
        let times: [Date] = [
            asked,
            asked.addingTimeInterval(patience - 1),
            asked.addingTimeInterval(patience),
            asked.addingTimeInterval(patience * 100)
        ]

        for permission in Self.permissions where permission != .authorized {
            for presentation in [Picker.Presentation.sheet, Self.pane] {
                for now in times {
                    #expect(Picker.nearbyPlaceholder(
                        presentation: presentation,
                        permission: permission,
                        fixRequestedAt: asked,
                        now: now
                    ) == .grantPermission)
                }
            }
        }

        for now in times {
            #expect(Picker.nearbyPlaceholder(
                presentation: .sheet,
                permission: .authorized,
                fixRequestedAt: asked,
                now: now
            ) == .finding)
        }

        func pane(at now: Date, askedAt: Date? = asked) -> Picker.NearbyPlaceholder {
            Picker.nearbyPlaceholder(presentation: Self.pane, permission: .authorized, fixRequestedAt: askedAt, now: now)
        }
        #expect(pane(at: times[0]) == .finding)
        #expect(pane(at: times[1]) == .finding)
        #expect(pane(at: times[2]) == .unavailable)
        #expect(pane(at: times[3]) == .unavailable)
        // Not asked yet: it asks as it appears and as permission arrives.
        #expect(pane(at: times[3], askedAt: nil) == .finding)
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

    @Test
    func paneWipeAndRetryAskForOneFixAndNeverPrompt() async {
        let fixture = await Fixture(authorizationStatus: .authorizedAlways)
        defer { fixture.tearDown() }
        let location = fixture.location

        Picker.perform(.appear, presentation: Self.pane, permission: fixture.model.permissionState, on: fixture.model)
        Picker.perform(.panicWipe, presentation: Self.pane, permission: fixture.model.permissionState, on: fixture.model)
        #expect(location.requestLocationCallCount == 2)
        Picker.perform(.retry, presentation: Self.pane, permission: fixture.model.permissionState, on: fixture.model)
        #expect(location.requestLocationCallCount == 3)

        #expect(location.startUpdatingLocationCallCount == 0)
        #expect(location.stopUpdatingLocationCallCount == 0)
        #expect(location.requestAuthorizationCallCount == 0)
    }

    /// Every panic wipe moves the epoch the inline picker resets on.
    @Test
    func everyPanicWipeMovesTheEpoch() {
        let chrome = makeChromeModel()
        let before = chrome.panicEpoch

        chrome.panicClearAllData()

        #expect(chrome.panicEpoch == before &+ 1)
    }

    /// E7: the sheet always lists #mesh; the pane only while browsing, its
    /// close control up. Not while a geohash chosen in the idle pane is
    /// selected but not yet on screen: the pane is still idle.
    @Test
    func onlyTheSheetAndABrowsingPaneListMesh() {
        #expect(Picker.showsMeshRow(presentation: .sheet, canClose: true))
        #expect(Picker.showsMeshRow(presentation: Self.pane, canClose: true))
        #expect(!Picker.showsMeshRow(presentation: Self.pane, canClose: false))
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

#if os(iOS)
/// An `AppChromeModel` over a view model with its own location manager, so a
/// panic wipe doesn't reach the process-wide location state.
@MainActor
private func makeChromeModel() -> AppChromeModel {
    let keychain = MockKeychain()
    let suiteName = "LocationChannelsPickerTests.chrome.\(UUID().uuidString)"
    let storage = UserDefaults(suiteName: suiteName) ?? .standard
    storage.removePersistentDomain(forName: suiteName)
    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
        identityManager: MockIdentityManager(keychain),
        transport: MockTransport(),
        locationManager: LocationChannelManager(storage: storage)
    )
    return AppChromeModel(
        chatViewModel: viewModel,
        privateInboxModel: PrivateInboxModel(conversations: ConversationStore())
    )
}
#endif

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
