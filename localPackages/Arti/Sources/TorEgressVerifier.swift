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
/// Policy (`verify()` return value) — fail-closed on unverified egress:
///   - `.verifiedTor`   → allow, and cache the positive result for `ttl`.
///   - `.notTor`        → REFUSE, and drop any cached verification. The canary
///                        reached the internet but the exit is NOT a Tor node:
///                        a real leak. Never allow relays.
///   - `.unreachable`   → REFUSE (egress unverified). The canary itself failed
///                        (endpoint down / circuit not built), so we cannot tell
///                        whether the platform honored the SOCKS proxy — the
///                        exact ambiguity this verifier exists to resolve.
///                        Unverified traffic must not proceed on the
///                        enforced-Tor path.
///
/// TTL / retry semantics:
///   - A `verifiedTor` verdict allows connection *opens* for `ttl` without
///     re-probing, so a brief canary blip inside the TTL window does not take
///     relays offline (a fresh positive verdict is authoritative for the
///     window). Already-open sockets are never torn down by verification —
///     they were opened under a verified egress and the proxied session is
///     fail-closed by construction.
///   - After TTL expiry (or `invalidate()` on Tor restart/dormant/shutdown),
///     the next `verify()` re-probes; while the canary stays `.unreachable`,
///     new connection opens are refused until a probe succeeds again.
///   - Probe cadence is bounded: at most one probe per `minRetryInterval`
///     (callers within the window reuse the last decision), and concurrent
///     `verify()` calls share one in-flight probe. Recovery from a transient
///     canary outage is automatic: callers that keep retrying (relay connect
///     gate, GeoRelayDirectory backoff) re-probe and succeed once the canary
///     is reachable again.
///
/// Liveness:
///   - Every probe is hard-bounded by `probeTimeout` via an independent async
///     watchdog. The proxied session sets `waitsForConnectivity = true`, which
///     can defer the per-request timer indefinitely, leaving the request
///     bounded only by the default 7-day resource timeout — without the
///     watchdog a hung canary would wedge every subsequent `verify()` caller.
///     On timeout the probe task is cancelled (cooperatively cancelling the
///     underlying `URLSessionTask`), the verdict is the fail-closed
///     `.unreachable`, and the in-flight slot is cleared so the next
///     `verify()` (after the retry throttle) starts a fresh probe.
///   - `invalidate()` cancels any in-flight probe and clears all cached state
///     (including the retry throttle), so a Tor restart/dormant/shutdown
///     genuinely resets the verifier: a hung probe cannot survive it.
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

    /// Hard upper bound for a single canary probe, enforced independently of
    /// URLSession timers (see the "Liveness" section of the type doc). Matches
    /// the live probe's per-request timeout.
    public static let defaultProbeTimeout: TimeInterval = 20

    private let probe: @Sendable () async -> ProbeResult
    private let now: @Sendable () -> Date
    private let ttl: TimeInterval
    /// Minimum spacing between probes when not currently verified, so a
    /// persistent `.unreachable` cannot hammer the canary endpoint on every
    /// reconnect burst.
    private let minRetryInterval: TimeInterval
    /// Outer wall-clock bound on a single probe (watchdog; fail-closed).
    private let probeTimeout: TimeInterval

    private var lastVerifiedAt: Date?
    private var lastProbeAt: Date?
    private var lastResult: ProbeResult?
    private var inFlight: Task<Bool, Never>?
    /// Bumped whenever a new probe starts or `invalidate()` runs. A completing
    /// probe only records its outcome (cache/throttle) and clears `inFlight`
    /// if its generation is still current, so a cancelled/superseded probe
    /// cannot clobber state owned by a fresh one (actor-reentrancy safety).
    private var probeGeneration = 0

    /// Lock-protected mirror of "verified within TTL" so synchronous gates
    /// (e.g. `NostrRelayManager`'s connect path) can consult the cache without
    /// awaiting the actor.
    private let verifiedSnapshot = VerifiedSnapshot()

    private final class VerifiedSnapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var verifiedUntil: Date?

        func update(_ until: Date?) {
            lock.lock()
            verifiedUntil = until
            lock.unlock()
        }

        func isFresh(at date: Date) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let verifiedUntil else { return false }
            return date < verifiedUntil
        }
    }

    public init(
        ttl: TimeInterval,
        minRetryInterval: TimeInterval = 5.0,
        probeTimeout: TimeInterval = TorEgressVerifier.defaultProbeTimeout,
        now: @escaping @Sendable () -> Date = Date.init,
        probe: @escaping @Sendable () async -> ProbeResult
    ) {
        self.ttl = ttl
        self.minRetryInterval = minRetryInterval
        self.probeTimeout = probeTimeout
        self.now = now
        self.probe = probe
    }

    /// Drop any cached verification (e.g. after a Tor restart or when the
    /// network path changes) AND cancel any in-flight probe. The next
    /// `verify()` starts a fresh probe — it neither joins the cancelled one
    /// nor is throttled by its outcome, so a probe hung from before a Tor
    /// restart cannot wedge callers after it.
    public func invalidate() {
        probeGeneration += 1
        inFlight?.cancel()
        inFlight = nil
        lastVerifiedAt = nil
        lastProbeAt = nil
        lastResult = nil
        verifiedSnapshot.update(nil)
    }

    /// The most recent probe outcome, for diagnostics/tests.
    public func lastProbeResult() -> ProbeResult? { lastResult }

    /// Synchronous view of the cache: `true` while a `verifiedTor` verdict is
    /// within its TTL. Callers that get `false` must route through the async
    /// `verify()` gate (which probes) before opening connections.
    public nonisolated var hasFreshVerification: Bool {
        verifiedSnapshot.isFresh(at: now())
    }

    /// Returns `true` only when the proxied egress is verified to exit via Tor
    /// (a fresh probe or a cached `verifiedTor` verdict within TTL). Returns
    /// `false` when a non-Tor egress was positively detected *or* when the
    /// egress could not be verified. See the type doc for the full policy.
    public func verify() async -> Bool {
        if isFreshlyVerified() { return true }
        // Throttle re-probes when the last attempt did not verify.
        if let last = lastProbeAt,
           let result = lastResult,
           now().timeIntervalSince(last) < minRetryInterval {
            return decision(for: result)
        }
        if let inFlight { return await inFlight.value }

        probeGeneration += 1
        let generation = probeGeneration
        let task = Task<Bool, Never> { await self.runProbe(generation: generation) }
        inFlight = task
        let allowed = await task.value
        // Only clear the slot if this probe is still the current one: an
        // `invalidate()` while we were suspended has already cleared it and a
        // newer probe may occupy it (do not clobber the fresh task).
        if probeGeneration == generation { inFlight = nil }
        return allowed
    }

    private func isFreshlyVerified() -> Bool {
        guard let last = lastVerifiedAt else { return false }
        return now().timeIntervalSince(last) < ttl
    }

    private func decision(for result: ProbeResult) -> Bool {
        switch result {
        case .verifiedTor: return true
        // Fail closed: both a positively detected leak and an unverifiable
        // egress refuse connections. Only a fresh `verifiedTor` allows.
        case .unreachable, .notTor: return false
        }
    }

    private func runProbe(generation: Int) async -> Bool {
        let result = await boundedProbe()
        // Superseded by `invalidate()` (Tor restart/dormant/shutdown) while the
        // probe ran: its verdict predates the reset, so discard it — recording
        // it would re-seed the throttle/cache that invalidate() just cleared.
        // Fail closed for the callers that were awaiting this probe.
        guard generation == probeGeneration else { return false }
        lastProbeAt = now()
        lastResult = result
        switch result {
        case .verifiedTor:
            lastVerifiedAt = now()
            verifiedSnapshot.update(now().addingTimeInterval(ttl))
            return true
        case .notTor:
            lastVerifiedAt = nil
            verifiedSnapshot.update(nil)
            SecureLogger.error(
                "🧅 Tor egress self-check FAILED: request exited via a NON-Tor address — refusing relay connections (possible IP leak)",
                category: .session
            )
            return false
        case .unreachable(let why):
            // Note: a probe only runs when no fresh cached verdict exists, so
            // there is no still-valid cache to preserve or drop here.
            SecureLogger.warning(
                "🧅 Tor egress self-check could not complete (\(why)) — egress UNVERIFIED; refusing relay connections until the canary succeeds (bounded retry)",
                category: .session
            )
            return false
        }
    }

    /// Runs the injected probe raced against `probeTimeout`, guaranteeing a
    /// result in bounded time regardless of URLSession timer behavior (the
    /// proxied session's `waitsForConnectivity` can defer the per-request
    /// timeout indefinitely). Whichever side loses the race is cancelled:
    /// - on timeout, the probe task is cancelled (URLSession's async APIs
    ///   cancel the underlying `URLSessionTask` cooperatively) and the result
    ///   is the fail-closed `.unreachable`;
    /// - on completion, the watchdog's sleep is cancelled so no timer lingers.
    /// Cancelling the enclosing task (`invalidate()`) resolves immediately as
    /// `.unreachable` and cancels both sides.
    ///
    /// `nonisolated` so the race body never re-enters the actor; it touches
    /// only immutable `Sendable` state.
    nonisolated private func boundedProbe() async -> ProbeResult {
        let probe = self.probe
        let timeout = self.probeTimeout
        let race = ProbeRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProbeResult, Never>) in
                race.install(continuation)
                let probeTask = Task { race.finish(await probe()) }
                let watchdog = Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    race.finish(.unreachable("probe timed out after \(Int(timeout))s"))
                }
                race.register(probeTask: probeTask, watchdog: watchdog)
            }
        } onCancel: {
            race.finish(.unreachable("probe cancelled"))
        }
    }

    /// Resolve-once rendezvous for the probe/watchdog race. Lock-protected
    /// (never held across an await); the first `finish()` wins, resumes the
    /// continuation exactly once, and cancels both tasks.
    private final class ProbeRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ProbeResult, Never>?
        private var pendingResult: ProbeResult?
        private var resolved = false
        private var probeTask: Task<Void, Never>?
        private var watchdog: Task<Void, Never>?

        func install(_ continuation: CheckedContinuation<ProbeResult, Never>) {
            lock.lock()
            if let result = pendingResult {
                // finish() ran before the continuation existed (e.g. the
                // enclosing task was already cancelled): resolve immediately.
                pendingResult = nil
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func register(probeTask: Task<Void, Never>, watchdog: Task<Void, Never>) {
            lock.lock()
            if resolved {
                lock.unlock()
                probeTask.cancel()
                watchdog.cancel()
                return
            }
            self.probeTask = probeTask
            self.watchdog = watchdog
            lock.unlock()
        }

        func finish(_ result: ProbeResult) {
            lock.lock()
            guard !resolved else { lock.unlock(); return }
            resolved = true
            let continuation = self.continuation
            self.continuation = nil
            if continuation == nil { pendingResult = result }
            let probeTask = self.probeTask
            let watchdog = self.watchdog
            self.probeTask = nil
            self.watchdog = nil
            lock.unlock()
            probeTask?.cancel()
            watchdog?.cancel()
            continuation?.resume(returning: result)
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
    /// Note: the per-request `timeoutInterval` below is best-effort only — the
    /// proxied session's `waitsForConnectivity` can defer it. The authoritative
    /// bound is the verifier's `probeTimeout` watchdog, whose cancellation
    /// propagates into `session.data(for:)` and cancels the URLSessionTask.
    static func liveProbe(
        endpoint: URL = URL(string: "https://check.torproject.org/api/ip")!,
        timeout: TimeInterval = TorEgressVerifier.defaultProbeTimeout
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
