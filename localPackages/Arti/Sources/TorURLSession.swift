import Foundation
#if os(macOS)
import CFNetwork
#endif

/// Provides a shared URLSession that routes traffic via Tor's SOCKS5 proxy
/// when Tor is enforced/ready. Allows swapping between proxied and direct
/// sessions so UI can toggle Tor usage at runtime.
public final class TorURLSession: @unchecked Sendable {
    public static let shared = TorURLSession()

    private let lock = NSLock()

    // Ephemeral (no proxy) session for direct Nostr access when Tor is explicitly disabled.
    private var defaultSession: URLSession = TorURLSession.makeDefaultSession()

    // Proxied (SOCKS5) session that routes through Tor.
    private var torSession: URLSession = TorURLSession.makeTorSession()
    private var useTorProxy: Bool = true

    public var session: URLSession {
        lock.lock()
        defer { lock.unlock() }
        return useTorProxy ? torSession : defaultSession
    }

    // Recreate sessions so new clients bind to the fresh SOCKS/control ports after a Tor restart.
    public func rebuild() {
        let newDefault = TorURLSession.makeDefaultSession()
        let newTor = TorURLSession.makeTorSession()

        lock.lock()
        let oldDefault = defaultSession
        let oldTor = torSession
        defaultSession = newDefault
        torSession = newTor
        lock.unlock()

        oldDefault.finishTasksAndInvalidate()
        oldTor.finishTasksAndInvalidate()
    }

    public func setProxyMode(useTor: Bool) {
        lock.lock()
        guard useTorProxy != useTor else {
            lock.unlock()
            return
        }
        useTorProxy = useTor
        lock.unlock()
        rebuild()
    }

    private static func makeTorSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = true
        // Keep in sync with TorManager defaults
        let host = "127.0.0.1"
        let port = 39050
        #if os(macOS)
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: host,
            kCFNetworkProxiesSOCKSPort as String: port
        ]
        #else
        // iOS: CFNetwork SOCKS proxy keys are unavailable at compile time.
        cfg.connectionProxyDictionary = [
            "SOCKSEnable": 1,
            "SOCKSProxy": host,
            "SOCKSPort": port
        ]
        #endif
        return URLSession(configuration: cfg)
    }

    private static func makeDefaultSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }
}
