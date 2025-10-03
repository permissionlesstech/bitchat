import Foundation
import BitLogger
import Combine
import Tor

/// Coordinates when the app is allowed to start Tor and connect to Nostr relays.
/// Policy: permit start when either location permissions are authorized OR
/// there exists at least one mutual favorite. Otherwise, do not start.
@MainActor
final class NetworkActivationService: ObservableObject {
    static let shared = NetworkActivationService()

    @Published private(set) var activationAllowed: Bool = false
    @Published private(set) var userTorEnabled: Bool = true

    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private let torPreferenceKey = "networkActivationService.userTorEnabled"
    private var torAutoStartDesired: Bool = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        if let stored = UserDefaults.standard.object(forKey: torPreferenceKey) as? Bool {
            userTorEnabled = stored
        } else {
            userTorEnabled = true
        }

        // Initial compute
        let allowed = basePolicyAllowed()
        activationAllowed = allowed
        torAutoStartDesired = allowed && userTorEnabled
        TorManager.shared.setAutoStartAllowed(torAutoStartDesired)
        applyTorState(torDesired: torAutoStartDesired)
        if allowed {
            NostrRelayManager.shared.connect()
        } else {
            NostrRelayManager.shared.disconnect()
        }

        // React to location permission changes
        LocationChannelManager.shared.$permissionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reevaluate()
            }
            .store(in: &cancellables)

        // React to mutual favorites changes
        FavoritesPersistenceService.shared.$mutualFavorites
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reevaluate()
            }
            .store(in: &cancellables)
    }

    func setUserTorEnabled(_ enabled: Bool) {
        guard enabled != userTorEnabled else { return }
        userTorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: torPreferenceKey)
        NotificationCenter.default.post(
            name: .TorUserPreferenceChanged,
            object: nil,
            userInfo: ["enabled": enabled]
        )
        reevaluate()
    }

    private func reevaluate() {
        let allowed = basePolicyAllowed()
        let torDesired = allowed && userTorEnabled
        let statusChanged = allowed != activationAllowed
        let torChanged = torDesired != torAutoStartDesired
        if statusChanged {
            SecureLogger.info("NetworkActivationService: activationAllowed -> \(allowed)", category: .session)
            activationAllowed = allowed
        }
        if statusChanged || torChanged {
            torAutoStartDesired = torDesired
            TorManager.shared.setAutoStartAllowed(torDesired)
            applyTorState(torDesired: torDesired)
        }

        if allowed {
            if torChanged {
                // Reset relay sockets when switching transport path (Tor ↔︎ direct)
                NostrRelayManager.shared.disconnect()
            }
            NostrRelayManager.shared.connect()
        } else if statusChanged {
            NostrRelayManager.shared.disconnect()
        }
    }

    private func basePolicyAllowed() -> Bool {
        let permOK = LocationChannelManager.shared.permissionState == .authorized
        let hasMutual = !FavoritesPersistenceService.shared.mutualFavorites.isEmpty
        return permOK || hasMutual
    }

    private func applyTorState(torDesired: Bool) {
        TorURLSession.shared.setProxyMode(useTor: torDesired)
        if torDesired {
            TorManager.shared.startIfNeeded()
        } else {
            TorManager.shared.shutdownCompletely()
        }
    }
}
