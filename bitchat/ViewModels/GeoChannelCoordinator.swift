//
// GeoChannelCoordinator.swift
// bitchat
//
// Centralizes Combine wiring for location channel selection and sampling.
//

import Combine
import Foundation
import Tor

@MainActor
final class GeoChannelCoordinator {
    private let locationManager: LocationChannelManager
    private let bookmarksStore: GeohashBookmarksStore
    private let torManager: TorManager

    private let onChannelSwitch: (ChannelID) -> Void
    private let beginSampling: ([String]) -> Void
    private let endSampling: () -> Void

    private var cancellables = Set<AnyCancellable>()
    private var regionalGeohashes: [String] = []
    private var bookmarkedGeohashes: [String] = []

    init(
        locationManager: LocationChannelManager? = nil,
        bookmarksStore: GeohashBookmarksStore? = nil,
        torManager: TorManager? = nil,
        onChannelSwitch: @escaping (ChannelID) -> Void,
        beginSampling: @escaping ([String]) -> Void,
        endSampling: @escaping () -> Void
    ) {
        self.locationManager = locationManager ?? Self.defaultLocationManager()
        self.bookmarksStore = bookmarksStore ?? GeohashBookmarksStore.shared
        self.torManager = torManager ?? Self.defaultTorManager()
        self.onChannelSwitch = onChannelSwitch
        self.beginSampling = beginSampling
        self.endSampling = endSampling

        start()
    }

    func start() {
        regionalGeohashes = locationManager.availableChannels.map { $0.geohash }
        bookmarkedGeohashes = bookmarksStore.bookmarks

        locationManager.$selectedChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] channel in
                guard let self else { return }
                Task { @MainActor in
                    self.onChannelSwitch(channel)
                }
            }
            .store(in: &cancellables)

        locationManager.$availableChannels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] channels in
                guard let self else { return }
                self.regionalGeohashes = channels.map { $0.geohash }
                self.updateSampling()
            }
            .store(in: &cancellables)

        bookmarksStore.$bookmarks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bookmarks in
                guard let self else { return }
                self.bookmarkedGeohashes = bookmarks
                self.updateSampling()
            }
            .store(in: &cancellables)

        locationManager.$permissionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, state == .authorized else { return }
                Task { @MainActor [weak self] in
                    self?.locationManager.refreshChannels()
                }
            }
            .store(in: &cancellables)

        Task { @MainActor in
            self.onChannelSwitch(self.locationManager.selectedChannel)
        }
        updateSampling()
    }

    private func updateSampling() {
        let union = Array(Set(regionalGeohashes).union(bookmarkedGeohashes))
        Task { @MainActor in
            guard !union.isEmpty else {
                endSampling()
                return
            }
            if torManager.isForeground() {
                beginSampling(union)
            } else {
                endSampling()
            }
        }
    }

    func refreshSampling() {
        updateSampling()
    }
    private static func defaultLocationManager() -> LocationChannelManager {
        LocationChannelManager.shared
    }

    @MainActor
    private static func defaultTorManager() -> TorManager {
        TorManager.shared
    }
}
