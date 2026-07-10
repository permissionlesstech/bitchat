import Foundation
import BitLogger
import Combine
import Tor

@MainActor
protocol NetworkActivationTorControlling: AnyObject {
    func setAutoStartAllowed(_ allowed: Bool)
    func startIfNeeded()
    func shutdownCompletely()
}

@MainActor
protocol NetworkActivationRelayControlling: AnyObject {
    func connect()
    func disconnect()
}

protocol NetworkActivationProxyControlling: AnyObject {
    func setProxyMode(useTor: Bool)
}

extension TorManager: NetworkActivationTorControlling {}
extension NostrRelayManager: NetworkActivationRelayControlling {}
extension TorURLSession: NetworkActivationProxyControlling {}

/// Coordinates when the app is allowed to start Tor and connect to Nostr relays.
/// Policy: permit start when (location permissions are authorized OR there
/// exists at least one mutual favorite) AND the device has a usable network
/// path. When there is provably no network at all we do not bootstrap Tor or
/// spin relay reconnects — that only wastes battery on a mesh-only/offline
/// device. BLE mesh is entirely independent of this gate.
@MainActor
final class NetworkActivationService: ObservableObject {
    static let shared = NetworkActivationService()

    @Published private(set) var activationAllowed: Bool = false
    @Published private(set) var userTorEnabled: Bool = true
    /// Coarse, debounced network reachability. `false` only when the OS reports
    /// no usable interface at all. Surfaced for UI ("offline" vs "connecting").
    @Published private(set) var isNetworkReachable: Bool = true

    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private let torPreferenceKey = "networkActivationService.userTorEnabled"
    private var torAutoStartDesired: Bool = false
    private let storage: UserDefaults
    private let locationPermissionPublisher: AnyPublisher<LocationChannelManager.PermissionState, Never>
    private let mutualFavoritesPublisher: AnyPublisher<Set<Data>, Never>
    private let permissionProvider: () -> LocationChannelManager.PermissionState
    private let mutualFavoritesProvider: () -> Set<Data>
    private let reachabilityMonitor: NetworkReachabilityMonitoring
    private let torController: NetworkActivationTorControlling
    // Resolved lazily: NostrRelayManager.init() reads NetworkActivationService.shared
    // (via its live dependencies), so capturing NostrRelayManager.shared here would
    // re-enter whichever singleton's dispatch_once started first and trap at launch.
    private lazy var relayController: NetworkActivationRelayControlling = relayControllerProvider()
    private let relayControllerProvider: () -> NetworkActivationRelayControlling
    private let proxyController: NetworkActivationProxyControlling
    private let notificationCenter: NotificationCenter

    private init() {
        storage = .standard
        locationPermissionPublisher = LocationChannelManager.shared.$permissionState.eraseToAnyPublisher()
        mutualFavoritesPublisher = FavoritesPersistenceService.shared.$mutualFavorites.eraseToAnyPublisher()
        permissionProvider = { LocationChannelManager.shared.permissionState }
        mutualFavoritesProvider = { FavoritesPersistenceService.shared.mutualFavorites }
        reachabilityMonitor = NWPathReachabilityMonitor()
        torController = TorManager.shared
        relayControllerProvider = { NostrRelayManager.shared }
        proxyController = TorURLSession.shared
        notificationCenter = .default
    }

    internal init(
        storage: UserDefaults,
        locationPermissionPublisher: AnyPublisher<LocationChannelManager.PermissionState, Never>,
        mutualFavoritesPublisher: AnyPublisher<Set<Data>, Never>,
        permissionProvider: @escaping () -> LocationChannelManager.PermissionState,
        mutualFavoritesProvider: @escaping () -> Set<Data>,
        reachabilityMonitor: NetworkReachabilityMonitoring,
        torController: NetworkActivationTorControlling,
        relayController: NetworkActivationRelayControlling,
        proxyController: NetworkActivationProxyControlling,
        notificationCenter: NotificationCenter = .default
    ) {
        self.storage = storage
        self.locationPermissionPublisher = locationPermissionPublisher
        self.mutualFavoritesPublisher = mutualFavoritesPublisher
        self.permissionProvider = permissionProvider
        self.mutualFavoritesProvider = mutualFavoritesProvider
        self.reachabilityMonitor = reachabilityMonitor
        self.torController = torController
        self.relayControllerProvider = { relayController }
        self.proxyController = proxyController
        self.notificationCenter = notificationCenter
    }

    func start() {
        guard !started else { return }
        started = true

        if let stored = storage.object(forKey: torPreferenceKey) as? Bool {
            userTorEnabled = stored
        } else {
            userTorEnabled = true
        }

        // Begin (idempotent) reachability monitoring and seed initial state.
        reachabilityMonitor.start()
        isNetworkReachable = reachabilityMonitor.isReachable

        // Initial compute
        let allowed = effectiveAllowed()
        activationAllowed = allowed
        torAutoStartDesired = allowed && userTorEnabled
        torController.setAutoStartAllowed(torAutoStartDesired)
        applyTorState(torDesired: torAutoStartDesired)
        if allowed {
            relayController.connect()
        } else {
            relayController.disconnect()
        }

        // React to location permission changes
        locationPermissionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reevaluate()
            }
            .store(in: &cancellables)

        // React to mutual favorites changes
        mutualFavoritesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reevaluate()
            }
            .store(in: &cancellables)

        // React to network reachability changes (debounced, unsatisfied-only).
        reachabilityMonitor.reachabilityPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reachable in
                guard let self else { return }
                guard reachable != self.isNetworkReachable else { return }
                self.isNetworkReachable = reachable
                SecureLogger.info(
                    "NetworkActivationService: isNetworkReachable -> \(reachable)",
                    category: .session
                )
                self.reevaluate()
            }
            .store(in: &cancellables)
    }

    func setUserTorEnabled(_ enabled: Bool) {
        guard enabled != userTorEnabled else { return }
        userTorEnabled = enabled
        storage.set(enabled, forKey: torPreferenceKey)
        notificationCenter.post(
            name: .TorUserPreferenceChanged,
            object: nil,
            userInfo: ["enabled": enabled]
        )
        reevaluate()
    }

    private func reevaluate() {
        let allowed = effectiveAllowed()
        let torDesired = allowed && userTorEnabled
        let statusChanged = allowed != activationAllowed
        let torChanged = torDesired != torAutoStartDesired
        if statusChanged {
            SecureLogger.info("NetworkActivationService: activationAllowed -> \(allowed)", category: .session)
            activationAllowed = allowed
        }
        if statusChanged || torChanged {
            torAutoStartDesired = torDesired
            torController.setAutoStartAllowed(torDesired)
            applyTorState(torDesired: torDesired)
        }

        if allowed {
            if torChanged {
                // Reset relay sockets when switching transport path (Tor ↔︎ direct)
                relayController.disconnect()
            }
            relayController.connect()
        } else if statusChanged {
            relayController.disconnect()
        }
    }

    /// Base policy: who is allowed to use the network at all (permission or a
    /// mutual favorite), ignoring current link state.
    private func basePolicyAllowed() -> Bool {
        let permOK = permissionProvider() == .authorized
        let hasMutual = !mutualFavoritesProvider().isEmpty
        return permOK || hasMutual
    }

    /// Effective gate: base policy AND a usable network path. When there is
    /// provably no network, Tor bootstrap and relay reconnects are suppressed.
    private func effectiveAllowed() -> Bool {
        basePolicyAllowed() && reachabilityMonitor.isReachable
    }

    private func applyTorState(torDesired: Bool) {
        proxyController.setProxyMode(useTor: torDesired)
        if torDesired {
            torController.startIfNeeded()
        } else {
            torController.shutdownCompletely()
        }
    }
}
