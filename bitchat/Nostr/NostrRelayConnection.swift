import Combine
import Foundation
import Tor

protocol NostrRelayConnectionProtocol: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void)
    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func sendPing(pongReceiveHandler: @escaping (Error?) -> Void)
}

protocol NostrRelaySessionProtocol {
    func webSocketTask(with url: URL) -> NostrRelayConnectionProtocol
}

private final class URLSessionWebSocketTaskAdapter: NostrRelayConnectionProtocol {
    private let base: URLSessionWebSocketTask

    init(base: URLSessionWebSocketTask) {
        self.base = base
    }

    func resume() {
        base.resume()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        base.cancel(with: closeCode, reason: reason)
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void) {
        base.send(message, completionHandler: completionHandler)
    }

    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        base.receive(completionHandler: completionHandler)
    }

    func sendPing(pongReceiveHandler: @escaping (Error?) -> Void) {
        base.sendPing(pongReceiveHandler: pongReceiveHandler)
    }
}

private struct URLSessionAdapter: NostrRelaySessionProtocol {
    let base: URLSession

    func webSocketTask(with url: URL) -> NostrRelayConnectionProtocol {
        let task = base.webSocketTask(with: url)
        // Byte bound per inbound frame; without it the per-relay buffer cap
        // (nostrInboundPerRelayBufferCap) bounds FRAMES but not BYTES, and a
        // hostile relay could pile up cap × 1 MiB (URLSession default) per
        // connection. See TransportConfig.nostrInboundMaxFrameBytes for the
        // sizing rationale. Oversized frames fail the receive with an error.
        task.maximumMessageSize = TransportConfig.nostrInboundMaxFrameBytes
        return URLSessionWebSocketTaskAdapter(base: task)
    }
}

struct NostrRelayManagerDependencies {
    var activationAllowed: () -> Bool
    var userTorEnabled: () -> Bool
    var hasMutualFavorites: () -> Bool
    var hasLocationPermission: () -> Bool
    var mutualFavoritesPublisher: AnyPublisher<Set<Data>, Never>
    var locationPermissionPublisher: AnyPublisher<LocationChannelManager.PermissionState, Never>
    var torEnforced: () -> Bool
    var torIsReady: () -> Bool
    var torIsForeground: () -> Bool
    var awaitTorReady: (@escaping (Bool) -> Void) -> Void
    var makeSession: () -> NostrRelaySessionProtocol
    var scheduleAfter: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    var now: () -> Date
    /// Uniform random value in [0, 1) used to jitter reconnect backoff.
    /// Injectable so tests can pin or sweep the jitter deterministically.
    var jitterUnit: () -> Double
    /// Where relay-settings changes are observed. Injectable so a test can use
    /// its own center instead of racing the process-wide one.
    var notificationCenter: NotificationCenter = .default
    /// Relays added by hand, merged with the built-in set. Injectable so tests
    /// do not have to write to shared preferences.
    var customRelays: () -> [String] = { NostrRelaySettings.customRelays() }
    /// Whether a location channel is currently open. Mirrors the third arm of
    /// `NetworkActivationService`'s gate: teleporting into a geohash needs no
    /// location permission, and without this the relays would stay filtered out
    /// for someone who denied location and has no mutual favorites.
    var isInLocationChannel: () -> Bool = { false }
    var selectedChannelPublisher: AnyPublisher<ChannelID, Never> = Empty().eraseToAnyPublisher()
}

extension NostrRelayManagerDependencies {
    @MainActor
    static func live() -> Self {
        Self(
            activationAllowed: { NetworkActivationService.shared.activationAllowed },
            userTorEnabled: { NetworkActivationService.shared.userTorEnabled },
            hasMutualFavorites: { !FavoritesPersistenceService.shared.mutualFavorites.isEmpty },
            hasLocationPermission: { LocationChannelManager.shared.permissionState == .authorized },
            mutualFavoritesPublisher: FavoritesPersistenceService.shared.$mutualFavorites.eraseToAnyPublisher(),
            locationPermissionPublisher: LocationChannelManager.shared.$permissionState.eraseToAnyPublisher(),
            torEnforced: { TorManager.shared.torEnforced },
            torIsReady: { TorManager.shared.isReady },
            torIsForeground: { TorManager.shared.isForeground() },
            awaitTorReady: { completion in
                Task.detached {
                    let ready = await TorManager.shared.awaitReady()
                    await MainActor.run {
                        completion(ready)
                    }
                }
            },
            makeSession: { URLSessionAdapter(base: TorURLSession.shared.session) },
            scheduleAfter: { delay, action in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
            },
            now: Date.init,
            jitterUnit: { Double.random(in: 0..<1) },
            isInLocationChannel: {
                if case .location = LocationChannelManager.shared.selectedChannel { return true }
                return false
            },
            selectedChannelPublisher: LocationChannelManager.shared.$selectedChannel.eraseToAnyPublisher()
        )
    }
}
