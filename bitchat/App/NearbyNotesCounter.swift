//
// NearbyNotesCounter.swift
// bitchat
//
// Counts unexpired location notes left at the user's current building-level
// geohash so the empty mesh timeline can say "📍 3 notes left here". Only
// subscribes while a view holds it active, and only when location notes are
// enabled and location permission is already granted (it never prompts).
// This is free and unencumbered software released into the public domain.
//

import Combine
import Foundation

@MainActor
final class NearbyNotesCounter: ObservableObject {
    static let shared = NearbyNotesCounter()

    @Published private(set) var noteCount = 0
    /// Whether an explicit notes act (the empty-timeline "check for notes"
    /// tap, opening the notices sheet's geo tab, or a successful /drop) has
    /// unlocked the counter this session. Until then nothing subscribes:
    /// merely looking at the mesh timeline must not open a building-precision
    /// relay REQ that leaks location passively.
    @Published private(set) var revealed = false

    private var manager: LocationNotesManager?
    private var managerCancellable: AnyCancellable?
    private var channelsCancellable: AnyCancellable?
    private var permissionCancellable: AnyCancellable?
    private var settingCancellable: AnyCancellable?
    private var activeHolders = 0
    private let locationManager: LocationChannelManager
    private let managerFactory: @MainActor (String) -> LocationNotesManager
    private let releaseManager: @MainActor (LocationNotesManager?) -> Void

    init(
        locationManager: LocationChannelManager = .shared,
        managerFactory: @escaping @MainActor (String) -> LocationNotesManager = { LocationNotesPool.shared.acquire($0) },
        releaseManager: @escaping @MainActor (LocationNotesManager?) -> Void = { LocationNotesPool.shared.release($0) }
    ) {
        self.locationManager = locationManager
        self.managerFactory = managerFactory
        self.releaseManager = releaseManager
    }

    /// Whether the empty-timeline "check for notes" hint should render.
    /// The permission gate matters: `retarget()` never subscribes without
    /// location authorization, so offering the hint to an unauthorized
    /// install would be a silent dead-end — tap, `revealed` flips, the hint
    /// vanishes, and nothing else happens for the session. The hint never
    /// prompts; it simply stays hidden until permission exists. The caller
    /// passes its own observed permission state so the hint re-renders when
    /// authorization changes.
    func offersRevealHint(permissionState: LocationChannelManager.PermissionState) -> Bool {
        !revealed && LocationNotesSettings.enabled && permissionState == .authorized
    }

    /// Marks the one explicit act that lets the counter subscribe. Sticky for
    /// the rest of the session (the singleton's lifetime); `deactivate()`
    /// deliberately does not reset it.
    func reveal() {
        guard !revealed else { return }
        revealed = true
        retarget()
    }

    /// Begins (or keeps) the notes subscription for the current building
    /// geohash. Balanced by `deactivate()`; ref-counted so multiple views can
    /// hold it.
    func activate() {
        activeHolders += 1
        guard activeHolders == 1 else { return }
        channelsCancellable = locationManager.$availableChannels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.retarget() }
        // CoreLocation can revoke authorization while the view remains
        // mounted. `availableChannels` deliberately retains its last value,
        // so permission must be an independent invalidation signal or the
        // building REQ survives on stale coordinates.
        permissionCancellable = locationManager.$permissionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.retarget() }
        // The app-info kill switch must take effect immediately, not on the
        // next location change or remount.
        settingCancellable = NotificationCenter.default
            .publisher(for: LocationNotesSettings.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.retarget() }
        retarget()
    }

    func deactivate() {
        activeHolders = max(0, activeHolders - 1)
        guard activeHolders == 0 else { return }
        channelsCancellable = nil
        permissionCancellable = nil
        settingCancellable = nil
        managerCancellable = nil
        releaseManager(manager)
        manager = nil
        noteCount = 0
    }

    private func retarget() {
        guard activeHolders > 0,
              revealed,
              LocationNotesSettings.enabled,
              locationManager.permissionState == .authorized,
              let geohash = locationManager.availableChannels
                  .first(where: { $0.level == .building })?.geohash
        else {
            managerCancellable = nil
            releaseManager(manager)
            manager = nil
            noteCount = 0
            return
        }

        if let manager {
            guard manager.geohash != geohash.lowercased() else { return }
            // Pooled managers are shared; never retarget one in place —
            // release the old cell and acquire the new one.
            managerCancellable = nil
            releaseManager(manager)
            self.manager = nil
        }

        let fresh = managerFactory(geohash)
        manager = fresh
        managerCancellable = fresh.$notes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notes in
                let now = Date()
                self?.noteCount = notes.filter { $0.expiresAt.map { $0 > now } ?? true }.count
            }
    }
}
