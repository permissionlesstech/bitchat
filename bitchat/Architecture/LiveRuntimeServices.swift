import Foundation
import Tor

@MainActor
private final class RelayControllerProxy: NetworkActivationRelayControlling {
    weak var controller: NetworkActivationRelayControlling?

    func connect() {
        controller?.connect()
    }

    func disconnect() {
        controller?.disconnect()
    }
}

@MainActor
enum LiveRuntimeServices {
    private struct SharedPair {
        let networkActivationService: NetworkActivationService
        let nostrRelayManager: NostrRelayManager
    }

    private static let sharedPair: SharedPair = {
        let relayControllerProxy = RelayControllerProxy()
        let locationManager = LocationChannelManager.shared
        let favoritesService = FavoritesPersistenceService.shared
        let networkActivationService = NetworkActivationService.live(
            locationManager: locationManager,
            favoritesService: favoritesService,
            relayController: relayControllerProxy
        )
        let nostrRelayManager = NostrRelayManager.live(
            networkActivationService: networkActivationService,
            locationManager: locationManager,
            favoritesService: favoritesService
        )
        relayControllerProxy.controller = nostrRelayManager
        return SharedPair(
            networkActivationService: networkActivationService,
            nostrRelayManager: nostrRelayManager
        )
    }()

    static var networkActivationService: NetworkActivationService {
        sharedPair.networkActivationService
    }

    static var nostrRelayManager: NostrRelayManager {
        sharedPair.nostrRelayManager
    }
}
