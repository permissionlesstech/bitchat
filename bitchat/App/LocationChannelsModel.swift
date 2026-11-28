import Combine
import Foundation

@MainActor
final class LocationChannelsModel: ObservableObject {
    @Published private(set) var permissionState: LocationChannelManager.PermissionState
    @Published private(set) var availableChannels: [GeohashChannel]
    @Published private(set) var selectedChannel: ChannelID
    @Published private(set) var teleported: Bool
    @Published private(set) var bookmarks: [String]
    @Published private(set) var bookmarkNames: [String: String]
    @Published private(set) var locationNames: [GeohashChannelLevel: String]
    @Published private(set) var userTorEnabled: Bool
    @Published private(set) var gatewayEnabled: Bool

    private let manager: LocationChannelManager
    private let network: NetworkActivationService
    private let gateway: GatewayService

    init(
        manager: LocationChannelManager? = nil,
        network: NetworkActivationService? = nil,
        gateway: GatewayService? = nil
    ) {
        let manager = manager ?? .shared
        let network = network ?? .shared
        let gateway = gateway ?? .shared

        self.manager = manager
        self.network = network
        self.gateway = gateway
        self.gatewayEnabled = gateway.isEnabled
        self.permissionState = manager.permissionState
        self.availableChannels = manager.availableChannels
        self.selectedChannel = manager.selectedChannel
        self.teleported = manager.teleported
        self.bookmarks = manager.bookmarks
        self.bookmarkNames = manager.bookmarkNames
        self.locationNames = manager.locationNames
        self.userTorEnabled = network.userTorEnabled

        bind()
    }

    var currentBuildingGeohash: String? {
        availableChannels.first(where: { $0.level == .building })?.geohash
    }

    func isSelected(_ channel: GeohashChannel) -> Bool {
        guard case .location(let selected) = selectedChannel else { return false }
        return selected == channel
    }

    func isBookmarked(_ geohash: String) -> Bool {
        manager.isBookmarked(geohash)
    }

    func enableLocationChannels() {
        manager.enableLocationChannels()
    }

    func refreshChannels() {
        manager.refreshChannels()
    }

    func enableAndRefresh() {
        manager.enableLocationChannels()
        manager.refreshChannels()
    }

    func beginLiveRefresh() {
        manager.beginLiveRefresh()
    }

    func endLiveRefresh() {
        manager.endLiveRefresh()
    }

    func select(_ channel: ChannelID) {
        manager.select(channel)
    }

    func markTeleported(for geohash: String, _ flag: Bool) {
        manager.markTeleported(for: geohash, flag)
    }

    func toggleBookmark(_ geohash: String) {
        manager.toggleBookmark(geohash)
    }

    func resolveBookmarkNameIfNeeded(for geohash: String) {
        manager.resolveBookmarkNameIfNeeded(for: geohash)
    }

    func locationName(for level: GeohashChannelLevel) -> String? {
        locationNames[level]
    }

    /// Resolves the header title for a place room without letting the user's
    /// own GPS location names bleed into teleported or popular regions.
    nonisolated static func resolveDisplayTitle(
        for channel: GeohashChannel,
        availableChannels: [GeohashChannel],
        locationNames: [GeohashChannelLevel: String],
        bookmarkNames: [String: String],
        explicitTitle: String? = nil
    ) -> String {
        if let explicit = explicitTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        if availableChannels.contains(where: { $0.geohash == channel.geohash }),
           let localName = locationNames[channel.level]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !localName.isEmpty {
            return localName
        }
        if let bookmarkName = bookmarkNames[channel.geohash]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bookmarkName.isEmpty {
            return bookmarkName
        }
        return "#\(channel.geohash)"
    }

    func displayTitle(for channel: GeohashChannel, explicitTitle: String? = nil) -> String {
        Self.resolveDisplayTitle(
            for: channel,
            availableChannels: availableChannels,
            locationNames: locationNames,
            bookmarkNames: bookmarkNames,
            explicitTitle: explicitTitle
        )
    }

    func setUserTorEnabled(_ enabled: Bool) {
        network.setUserTorEnabled(enabled)
    }

    func refreshMeshChannelsIfNeeded() {
        guard case .mesh = selectedChannel,
              permissionState == .authorized,
              availableChannels.isEmpty else {
            return
        }
        refreshChannels()
    }

    func openLocationChannel(for geohash: String) {
        let normalized = geohash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
        guard (2...12).contains(normalized.count),
              normalized.allSatisfy({ allowed.contains($0) }) else {
            return
        }

        let channel = GeohashChannel(level: level(forLength: normalized.count), geohash: normalized)
        let isRegional = availableChannels.contains { $0.geohash == normalized }
        if !isRegional && !availableChannels.isEmpty {
            markTeleported(for: normalized, true)
        }
        select(.location(channel))
    }

    func teleport(to geohash: String) {
        let normalized = geohash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let channel = GeohashChannel(level: level(forLength: normalized.count), geohash: normalized)
        markTeleported(for: normalized, true)
        select(.location(channel))
    }

    private func bind() {
        manager.$permissionState
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .assign(to: &$permissionState)

        manager.$availableChannels
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .assign(to: &$availableChannels)

        manager.$selectedChannel
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .assign(to: &$selectedChannel)

        manager.$teleported
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .assign(to: &$teleported)

        manager.$bookmarks
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .assign(to: &$bookmarks)

        manager.$bookmarkNames
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .assign(to: &$bookmarkNames)

        manager.$locationNames
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .assign(to: &$locationNames)

        network.$userTorEnabled
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .assign(to: &$userTorEnabled)

        gateway.$isEnabled
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .assign(to: &$gatewayEnabled)
    }

    private func level(forLength length: Int) -> GeohashChannelLevel {
        switch length {
        case 0...2: return .region
        case 3...4: return .province
        case 5: return .city
        case 6: return .neighborhood
        case 7: return .block
        case 8...12: return .building
        default: return .block
        }
    }
}
