import Nostr
import Combine
import Foundation
import Tor
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - GeoRelayDirectory Live Dependencies

extension GeoRelayDirectoryDependencies {
    @MainActor
    static func live() -> Self {
        #if os(iOS)
        let activeNotificationName: Notification.Name? = UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        let activeNotificationName: Notification.Name? = NSApplication.didBecomeActiveNotification
        #else
        let activeNotificationName: Notification.Name? = nil
        #endif

        return Self(
            userDefaults: .standard,
            notificationCenter: .default,
            now: Date.init,
            remoteURL: URL(string: "https://raw.githubusercontent.com/permissionlesstech/georelays/refs/heads/main/nostr_relays.csv")!,
            fetchInterval: TransportConfig.geoRelayFetchIntervalSeconds,
            refreshCheckInterval: TransportConfig.geoRelayRefreshCheckIntervalSeconds,
            retryInitialSeconds: TransportConfig.geoRelayRetryInitialSeconds,
            retryMaxSeconds: TransportConfig.geoRelayRetryMaxSeconds,
            awaitTorReady: { await TorManager.shared.awaitReady() },
            makeFetchData: {
                let session = TorURLSession.shared.session
                return { request in
                    let (data, _) = try await session.data(for: request)
                    return data
                }
            },
            readData: { try? Data(contentsOf: $0) },
            writeData: { data, url in
                try data.write(to: url, options: .atomic)
            },
            cacheURL: {
                do {
                    let base = try FileManager.default.url(
                        for: .applicationSupportDirectory,
                        in: .userDomainMask,
                        appropriateFor: nil,
                        create: true
                    )
                    let dir = base.appendingPathComponent("bitchat", isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    return dir.appendingPathComponent("georelays_cache.csv")
                } catch {
                    return nil
                }
            },
            bundledCSVURLs: {
                [
                    Bundle.main.url(forResource: "nostr_relays", withExtension: "csv"),
                    Bundle.main.url(forResource: "online_relays_gps", withExtension: "csv"),
                    Bundle.main.url(forResource: "online_relays_gps", withExtension: "csv", subdirectory: "relays")
                ].compactMap { $0 }
            },
            currentDirectoryPath: { FileManager.default.currentDirectoryPath },
            retrySleep: { delay in
                let nanoseconds = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            },
            torReadyNotificationName: .TorDidBecomeReady,
            activeNotificationName: activeNotificationName,
            autoStart: true
        )
    }
}

// MARK: - NostrRelayManager Live Dependencies

extension NostrRelayManagerDependencies {
    @MainActor
    static func live() -> Self {
        Self(
            activationAllowed: { NetworkActivationService.shared.activationAllowed },
            userTorEnabled: { NetworkActivationService.shared.userTorEnabled },
            hasMutualFavorites: { !FavoritesPersistenceService.shared.mutualFavorites.isEmpty },
            hasLocationPermission: { LocationChannelManager.shared.permissionState == .authorized },
            mutualFavoritesPublisher: FavoritesPersistenceService.shared.$mutualFavorites.eraseToAnyPublisher(),
            locationPermissionPublisher: LocationChannelManager.shared.$permissionState
                .map { state -> LocationPermissionState in
                    switch state {
                    case .notDetermined:.notDetermined
                    case .authorized:   .authorized
                    case .denied:       .denied
                    case .restricted:   .denied
                    }
                }
                .eraseToAnyPublisher(),
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
            makeSession: { NostrRelayManager.makeURLSession(TorURLSession.shared.session) },
            scheduleAfter: { delay, action in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
            },
            now: Date.init
        )
    }
}
