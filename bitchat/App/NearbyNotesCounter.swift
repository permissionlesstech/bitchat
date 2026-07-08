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

    private var manager: LocationNotesManager?
    private var managerCancellable: AnyCancellable?
    private var channelsCancellable: AnyCancellable?
    private var activeHolders = 0
    private let locationManager: LocationChannelManager

    init(locationManager: LocationChannelManager = .shared) {
        self.locationManager = locationManager
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
        retarget()
    }

    func deactivate() {
        activeHolders = max(0, activeHolders - 1)
        guard activeHolders == 0 else { return }
        channelsCancellable = nil
        managerCancellable = nil
        manager?.cancel()
        manager = nil
        noteCount = 0
    }

    private func retarget() {
        guard activeHolders > 0,
              LocationNotesSettings.enabled,
              locationManager.permissionState == .authorized,
              let geohash = locationManager.availableChannels
                  .first(where: { $0.level == .building })?.geohash
        else {
            managerCancellable = nil
            manager?.cancel()
            manager = nil
            noteCount = 0
            return
        }

        if let manager {
            manager.setGeohash(geohash)
            return
        }

        let fresh = LocationNotesManager(geohash: geohash)
        manager = fresh
        managerCancellable = fresh.$notes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notes in
                let now = Date()
                self?.noteCount = notes.filter { $0.expiresAt.map { $0 > now } ?? true }.count
            }
    }
}
