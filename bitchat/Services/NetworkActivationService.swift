import Foundation
import BitLogger
import Combine

/// Coordinates when the app is allowed to start Tor and connect to Nostr relays.
/// Policy: permit start when either location permissions are authorized OR
/// there exists at least one mutual favorite. Otherwise, do not start.
@MainActor
final class NetworkActivationService: ObservableObject {
    static let shared = NetworkActivationService()

    @Published private(set) var activationAllowed: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        // Initial compute
        activationAllowed = Self.computeAllowed()
        TorManager.shared.setAutoStartAllowed(activationAllowed)

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

    private func reevaluate() {
        let allowed = Self.computeAllowed()
        if allowed != activationAllowed {
            SecureLogger.info("NetworkActivationService: activationAllowed -> \(allowed)", category: .session)
            activationAllowed = allowed
            TorManager.shared.setAutoStartAllowed(allowed)
            if allowed {
                // Kick Tor + relays if we're now permitted
                TorManager.shared.startIfNeeded()
                // If app is in foreground, begin relay connections
                if TorManager.shared.isForeground() {
                    NostrRelayManager.shared.connect()
                }
            } else {
                // Transitioned to disallowed: disconnect relays and shut down Tor
                NostrRelayManager.shared.disconnect()
                TorManager.shared.goDormantOnBackground()
            }
        }
    }

    private static func computeAllowed() -> Bool {
        let permOK = LocationChannelManager.shared.permissionState == .authorized
        let hasMutual = !FavoritesPersistenceService.shared.mutualFavorites.isEmpty
        return permOK || hasMutual
    }
}
