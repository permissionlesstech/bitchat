//
// GeoChannelCoordinator.swift
// bitchat
//
// Centralizes Combine wiring for location channel selection and sampling.
//

import Combine
import Foundation
import Tor

/// The narrow surface `GeoChannelCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of capturing `ChatViewModel` in
/// per-callback closures. This keeps the coordinator independently testable
/// (see `GeoChannelCoordinatorContextTests`) and makes its true dependencies
/// explicit. Held `weak` — the owner retains the coordinator, and every
/// callback was previously a `[weak viewModel]` capture.
@MainActor
protocol GeoChannelContext: AnyObject {
    func switchLocationChannel(to channel: ChannelID)
    func beginGeohashSampling(for geohashes: [String])
    func endGeohashSampling()
}

// `switchLocationChannel(to:)`, `beginGeohashSampling(for:)`, and
// `endGeohashSampling()` are satisfied by existing `ChatViewModel` members.
extension ChatViewModel: GeoChannelContext {}

@MainActor
final class GeoChannelCoordinator {
    private let locationManager: LocationChannelManager
    private let bookmarksStore: GeohashBookmarksStore
    private let torManager: TorManager

    private weak var context: (any GeoChannelContext)?

    private var cancellables = Set<AnyCancellable>()
    private var regionalChannels: [GeohashChannel] = []
    private var bookmarkedGeohashes: [String] = []
    private var permissionState: LocationChannelManager.PermissionState
    private var locationNotesEnabled: Bool
    /// Mirrors `NearbyNotesCounter.revealed` (injectable for tests): the
    /// session's one explicit notes act. Until it happens, background
    /// sampling must not include the building-precision cell — see
    /// `sampledRegionalGeohashes`.
    private var notesRevealed = false
    private let notesRevealedPublisher: AnyPublisher<Bool, Never>
    private let locationNotesSettingsPublisher: AnyPublisher<Bool, Never>

    init(
        locationManager: LocationChannelManager? = nil,
        bookmarksStore: GeohashBookmarksStore? = nil,
        torManager: TorManager? = nil,
        notesRevealed: AnyPublisher<Bool, Never>? = nil,
        locationNotesEnabled: Bool? = nil,
        locationNotesSettings: AnyPublisher<Bool, Never>? = nil,
        context: any GeoChannelContext
    ) {
        let resolvedLocationManager = locationManager ?? Self.defaultLocationManager()
        self.locationManager = resolvedLocationManager
        self.bookmarksStore = bookmarksStore ?? GeohashBookmarksStore.shared
        self.torManager = torManager ?? Self.defaultTorManager()
        self.permissionState = resolvedLocationManager.permissionState
        self.locationNotesEnabled = locationNotesEnabled ?? LocationNotesSettings.enabled
        self.notesRevealedPublisher = notesRevealed
            ?? NearbyNotesCounter.shared.$revealed.eraseToAnyPublisher()
        self.locationNotesSettingsPublisher = locationNotesSettings
            ?? NotificationCenter.default
                .publisher(for: LocationNotesSettings.didChangeNotification)
                .map { _ in LocationNotesSettings.enabled }
                .eraseToAnyPublisher()
        self.context = context

        start()
    }

    func start() {
        regionalChannels = locationManager.availableChannels
        bookmarkedGeohashes = bookmarksStore.bookmarks

        locationManager.$selectedChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] channel in
                guard let self else { return }
                Task { @MainActor in
                    self.context?.switchLocationChannel(to: channel)
                }
            }
            .store(in: &cancellables)

        locationManager.$availableChannels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] channels in
                guard let self else { return }
                self.regionalChannels = channels
                self.updateSampling()
            }
            .store(in: &cancellables)

        // Revealing the nearby-notes counter is the session's explicit notes
        // act; it widens sampling to include the building cell (below).
        notesRevealedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] revealed in
                guard let self, self.notesRevealed != revealed else { return }
                self.notesRevealed = revealed
                self.updateSampling()
            }
            .store(in: &cancellables)

        // The location-notes preference is a live privacy kill switch. It
        // removes the device-derived building cell even if the session was
        // previously revealed. Explicit bookmarks remain eligible below.
        locationNotesSettingsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self, self.locationNotesEnabled != enabled else { return }
                self.locationNotesEnabled = enabled
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
                guard let self else { return }
                self.permissionState = state
                if state == .authorized {
                    self.locationManager.refreshChannels()
                }
                // Cached channels outlive authorization by design. Recompute
                // regardless of direction so revocation tears down regional
                // sampling instead of continuing from stale coordinates.
                self.updateSampling()
            }
            .store(in: &cancellables)

        Task { @MainActor in
            self.context?.switchLocationChannel(to: self.locationManager.selectedChannel)
        }
        updateSampling()
    }

    /// Regional geohashes eligible for background sampling. The
    /// building-precision (precision-8) cell identifies a single address, so
    /// sampling it passively would leak the same location signal the
    /// nearby-notes tap-to-reveal exists to gate — it joins only after the
    /// session's explicit notes act. The coarser levels (block and up) keep
    /// the nearby-conversation hint and channel participant counts working.
    /// Bookmarks are exempt: bookmarking a geohash is itself explicit.
    private var sampledRegionalGeohashes: [String] {
        guard permissionState == .authorized else { return [] }
        return regionalChannels
            .filter { (notesRevealed && locationNotesEnabled) || $0.level != .building }
            .map { $0.geohash }
    }

    private func updateSampling() {
        let union = Array(Set(sampledRegionalGeohashes).union(bookmarkedGeohashes))
        guard !union.isEmpty else {
            context?.endGeohashSampling()
            return
        }
        if torManager.isForeground() {
            context?.beginGeohashSampling(for: union)
        } else {
            context?.endGeohashSampling()
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
