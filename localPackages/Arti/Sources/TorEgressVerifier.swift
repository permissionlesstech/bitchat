import BitLogger
import Foundation

/// Runtime self-check that the proxied `URLSession` egress is *actually* routed
/// through Tor — defense-in-depth for the case where a platform silently ignores
/// `URLSessionConfiguration.connectionProxyDictionary` SOCKS settings and lets
/// traffic egress directly (leaking the real IP while Tor appears enabled).
///
/// Runtime verification (see `scripts/tor-egress-verification/`) showed that
/// macOS and the iOS simulator DO honor the SOCKS proxy for both plain HTTPS and
/// `URLSessionWebSocketTask`, and that the proxied session is fail-closed (every
/// request errors when the SOCKS proxy is down). Apple does not officially
/// support SOCKS for URLSession on iOS, so on a physical device the behavior is
/// not contractually guaranteed. This verifier closes that gap: before relay
/// connections are opened under enforced Tor, it performs a canary request whose
/// response positively reports whether the egress hit the network via Tor.
///
/// Policy (`verify()` return value):
///   - `.verifiedTor`   → allow, and cache the positive result for `ttl`.
///   - `.notTor`        → REFUSE. The canary reached the internet but the exit
///                        is NOT a Tor node: a real leak. Never allow relays.
///   - `.unreachable`   → allow-with-warning. The canary itself failed (endpoint
///                        down / circuit not built). This does NOT egress direct:
///                        the relay session is independently fail-closed, so the
///                        worst case is that relay connections also fail. We do
///                        not hard-block here to avoid taking Nostr fully offline
///                        whenever the single canary host is unavailable.
///
/// The probe is injectable so the policy/caching logic is unit-tested without a
/// live network (see `TorEgressVerifierTests`).
public actor TorEgressVerifier {
    public enum ProbeResult: Equatable, Sendable {
        /// Canary succeeded and the exit is a Tor node.
        case verifiedTor
        /// Canary succeeded but the exit is NOT Tor — a direct-egress leak.
        case notTor
        /// Canary could not complete (endpoint down, no circuit, parse error).
        case unreachable(String)
    }

    private let probe: @Sendable () async -> ProbeResult
    private let now: @Sendable () -> Date
    private let ttl: TimeInterval
    /// Minimum spacing between probes when not currently verified, so a
    /// persistent `.unreachable` cannot hammer the canary endpoint on every
    /// reconnect burst.
    private let minRetryInterval: TimeInterval

    private var lastVerifiedAt: Date?
    private var lastProbeAt: Date?
    private var lastResult: ProbeResult?
    private var inFlight: Task<Bool, Never>?

    public init(
        ttl: TimeInterval,
        minRetryInterval: TimeInterval = 5.0,
        now: @escaping @Sendable () -> Date = Date.init,
        probe: @escaping @Sendable () async -> ProbeResult
    ) {
        self.ttl = ttl
        self.minRetryInterval = minRetryInterval
        self.now = now
        self.probe = probe
    }

    /// Drop any cached verification (e.g. after a Tor restart or when the
    /// network path changes). The next `verify()` re-probes.
    public func invalidate() {
        lastVerifiedAt = nil
        lastProbeAt = nil
        lastResult = nil
    }

    /// The most recent probe outcome, for diagnostics/tests.
    public func lastProbeResult() -> ProbeResult? { lastResult }

    /// Returns `true` when it is safe to open relay connections through the
    /// proxied session, `false` only when a non-Tor egress was positively
    /// detected. See the type doc for the full policy.
    public func verify() async -> Bool {
        if isFreshlyVerified() { return true }
        // Throttle re-probes when the last attempt did not verify.
        if let last = lastProbeAt,
           let result = lastResult,
           now().timeIntervalSince(last) < minRetryInterval {
            return decision(for: result)
        }
        if let inFlight { return await inFlight.value }

        let task = Task<Bool, Never> { await self.runProbe() }
        inFlight = task
        let allowed = await task.value
        inFlight = nil
        return allowed
    }

    private func isFreshlyVerified() -> Bool {
        guard let last = lastVerifiedAt else { return false }
        return now().timeIntervalSince(last) < ttl
    }

    private func decision(for result: ProbeResult) -> Bool {
        switch result {
        case .verifiedTor: return true
        case .unreachable: return true
        case .notTor: return false
        }
    }

    private func runProbe() async -> Bool {
        let result = await probe()
        lastProbeAt = now()
        lastResult = result
        switch result {
        case .verifiedTor:
            lastVerifiedAt = now()
            return true
        case .notTor:
            lastVerifiedAt = nil
            SecureLogger.error(
                "🧅 Tor egress self-check FAILED: request exited via a NON-Tor address — refusing relay connections (possible IP leak)",
                category: .session
            )
            return false
        case .unreachable(let why):
            lastVerifiedAt = nil
            SecureLogger.warning(
                "🧅 Tor egress self-check could not complete (\(why)); relay session remains fail-closed via SOCKS proxy",
                category: .session
            )
            return true
        }
    }
}

// MARK: - Live probe

public extension TorEgressVerifier {
    /// Default canary: fetch Tor Project's connectivity check API through the
    /// shared proxied session and assert `IsTor == true`. Because the response
    /// is served from the *exit's* vantage point, a silent direct egress is
    /// caught here as `.notTor`. `check.torproject.org` is clearnet, so this
    /// works without onion-service support.
    ///
    /// Follow-up (see PR): make the canary endpoint configurable and add an
    /// onion-service canary so verification does not depend on a single host.
    static func liveProbe(
        endpoint: URL = URL(string: "https://check.torproject.org/api/ip")!,
        timeout: TimeInterval = 20
    ) -> @Sendable () async -> ProbeResult {
        return {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = timeout
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let session = TorURLSession.shared.session
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    return .unreachable("http status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .unreachable("unparseable canary response")
                }
                if let isTor = json["IsTor"] as? Bool {
                    return isTor ? .verifiedTor : .notTor
                }
                return .unreachable("canary response missing IsTor")
            } catch {
                return .unreachable(error.localizedDescription)
            }
        }
    }
}
