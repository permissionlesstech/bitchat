import Foundation

struct BLEConnectionCandidate<Peripheral> {
    let peripheral: Peripheral
    let peripheralID: String
    let rssi: Int
    let name: String
    let isConnectable: Bool
    let discoveredAt: Date
}

struct BLEExistingConnectionState {
    let isConnecting: Bool
    let isConnected: Bool
    let lastConnectionAttempt: Date?
}

enum BLEPeripheralConnectionState {
    case disconnected
    case connecting
    case connected
}

enum BLEDiscoveryDecision: Equatable {
    case ignore
    case queued
    case scheduleRetry(after: TimeInterval)
    case cancelStaleConnection
    case connectNow
}

enum BLEConnectionQueueDecision<Peripheral> {
    case none
    case retryAfter(TimeInterval)
    case connect(BLEConnectionCandidate<Peripheral>)
}

final class BLEConnectionScheduler<Peripheral> {
    private let maxCentralLinks: Int
    private let connectRateLimitInterval: TimeInterval
    private let candidateCap: Int
    private let weakLinkCooldownSeconds: TimeInterval
    private let weakLinkRSSICutoff: Int

    private var lastGlobalConnectAttempt: Date = .distantPast
    private var candidates: [BLEConnectionCandidate<Peripheral>] = []
    private var failureCounts: [String: Int] = [:]
    private var recentConnectTimeouts: [String: Date] = [:]
    // Tracked separately from connect timeouts: a peer we held a connection
    // with and lost (walked out of range) usually comes back, so it only gets
    // a brief rediscovery ignore — not the timeout backoff/cooldown treatment
    // reserved for peers that never answered a connect attempt.
    private var recentDisconnects: [String: Date] = [:]
    private var lastIsolatedAt: Date?

    private let initialDynamicRSSIThreshold: Int
    private(set) var dynamicRSSIThreshold: Int

    var candidateCount: Int {
        candidates.count
    }

    init(
        maxCentralLinks: Int = TransportConfig.bleMaxCentralLinks,
        connectRateLimitInterval: TimeInterval = TransportConfig.bleConnectRateLimitInterval,
        candidateCap: Int = TransportConfig.bleConnectionCandidatesMax,
        weakLinkCooldownSeconds: TimeInterval = TransportConfig.bleWeakLinkCooldownSeconds,
        weakLinkRSSICutoff: Int = TransportConfig.bleWeakLinkRSSICutoff,
        dynamicRSSIThreshold: Int = TransportConfig.bleDynamicRSSIThresholdDefault
    ) {
        self.maxCentralLinks = maxCentralLinks
        self.connectRateLimitInterval = connectRateLimitInterval
        self.candidateCap = candidateCap
        self.weakLinkCooldownSeconds = weakLinkCooldownSeconds
        self.weakLinkRSSICutoff = weakLinkRSSICutoff
        self.initialDynamicRSSIThreshold = dynamicRSSIThreshold
        self.dynamicRSSIThreshold = dynamicRSSIThreshold
    }

    func handleDiscovery(
        _ candidate: BLEConnectionCandidate<Peripheral>,
        connectedOrConnectingCount: Int,
        existingState: BLEExistingConnectionState?,
        peripheralState: BLEPeripheralConnectionState,
        now: Date
    ) -> BLEDiscoveryDecision {
        guard candidate.isConnectable else { return .ignore }

        if candidate.rssi <= dynamicRSSIThreshold {
            enqueue(candidate)
            return .queued
        }

        if connectedOrConnectingCount >= maxCentralLinks {
            enqueue(candidate)
            return .queued
        }

        if let retryDelay = rateLimitRetryDelay(now: now) {
            enqueue(candidate)
            return .scheduleRetry(after: retryDelay)
        }

        if let existingState {
            if existingState.isConnected || existingState.isConnecting {
                return .ignore
            }

            if let lastAttempt = existingState.lastConnectionAttempt,
               now.timeIntervalSince(lastAttempt) < 2.0 {
                return .ignore
            }
        }

        if let lastTimeout = recentConnectTimeouts[candidate.peripheralID],
           now.timeIntervalSince(lastTimeout) < TransportConfig.bleTimeoutDiscoveryIgnoreSeconds {
            return .ignore
        }

        if let lastDisconnect = recentDisconnects[candidate.peripheralID],
           now.timeIntervalSince(lastDisconnect) < TransportConfig.bleDisconnectDiscoveryIgnoreSeconds {
            return .ignore
        }

        switch peripheralState {
        case .disconnected:
            return .connectNow
        case .connecting, .connected:
            return .cancelStaleConnection
        }
    }

    func enqueue(_ candidate: BLEConnectionCandidate<Peripheral>) {
        if let existingIndex = candidates.firstIndex(where: { $0.peripheralID == candidate.peripheralID }) {
            candidates[existingIndex] = candidate
        } else {
            candidates.append(candidate)
        }

        candidates.sort {
            if $0.rssi != $1.rssi { return $0.rssi > $1.rssi }
            return $0.discoveredAt < $1.discoveredAt
        }
        if candidates.count > candidateCap {
            candidates.removeLast(candidates.count - candidateCap)
        }
    }

    func nextCandidate(
        connectedOrConnectingCount: Int,
        isAlreadyConnectingOrConnected: (String) -> Bool,
        now: Date
    ) -> BLEConnectionQueueDecision<Peripheral> {
        guard connectedOrConnectingCount < maxCentralLinks else { return .none }

        if let retryDelay = rateLimitRetryDelay(now: now) {
            return .retryAfter(retryDelay)
        }

        while !candidates.isEmpty {
            candidates.sort { score($0, now: now) > score($1, now: now) }
            let candidate = candidates.removeFirst()
            guard candidate.isConnectable else { continue }

            if let delay = weakLinkRetryDelay(for: candidate, now: now) {
                enqueue(candidate)
                return .retryAfter(delay)
            }

            if let delay = disconnectSettleDelay(for: candidate, now: now) {
                enqueue(candidate)
                return .retryAfter(delay)
            }

            if isAlreadyConnectingOrConnected(candidate.peripheralID) {
                continue
            }

            return .connect(candidate)
        }

        return .none
    }

    func recordConnectionAttempt(at now: Date) {
        lastGlobalConnectAttempt = now
    }

    func recordConnectionSuccess(peripheralID: String) {
        failureCounts[peripheralID] = 0
        recentConnectTimeouts.removeValue(forKey: peripheralID)
        recentDisconnects.removeValue(forKey: peripheralID)
    }

    func recordConnectionFailure(peripheralID: String) {
        failureCounts[peripheralID, default: 0] += 1
    }

    func recordDisconnectError(peripheralID: String, at now: Date) {
        recentDisconnects[peripheralID] = now
    }

    func recordConnectionTimeout(peripheralID: String, at now: Date) {
        recentConnectTimeouts[peripheralID] = now
        recordConnectionFailure(peripheralID: peripheralID)
    }

    func pruneConnectionTimeouts(before cutoff: Date) {
        recentConnectTimeouts = recentConnectTimeouts.filter { $0.value >= cutoff }
        recentDisconnects = recentDisconnects.filter { $0.value >= cutoff }
    }

    func reset() {
        lastGlobalConnectAttempt = .distantPast
        candidates.removeAll()
        failureCounts.removeAll()
        recentConnectTimeouts.removeAll()
        recentDisconnects.removeAll()
        lastIsolatedAt = nil
        dynamicRSSIThreshold = initialDynamicRSSIThreshold
    }

    @discardableResult
    func updateRSSIThreshold(
        connectedCount: Int,
        connectedOrConnectingLinkCount: Int,
        now: Date
    ) -> Int {
        if connectedCount == 0 {
            if lastIsolatedAt == nil { lastIsolatedAt = now }
            let isolatedAt = lastIsolatedAt ?? now
            let elapsed = now.timeIntervalSince(isolatedAt)
            dynamicRSSIThreshold = elapsed > TransportConfig.bleIsolationRelaxThresholdSeconds
                ? TransportConfig.bleRSSIIsolatedRelaxed
                : TransportConfig.bleRSSIIsolatedBase
            return dynamicRSSIThreshold
        }

        lastIsolatedAt = nil
        // Flaky links are handled per-peripheral (weak-link cooldown, discovery
        // ignore window, score bias) — never globally, so one flaky distant peer
        // can't blind us to every other edge-of-range peer.
        var threshold = TransportConfig.bleDynamicRSSIThresholdDefault
        if connectedOrConnectingLinkCount >= maxCentralLinks || candidates.count >= candidateCap {
            threshold = TransportConfig.bleRSSIConnectedThreshold
        }

        dynamicRSSIThreshold = threshold
        return threshold
    }

    private func rateLimitRetryDelay(now: Date) -> TimeInterval? {
        let elapsed = now.timeIntervalSince(lastGlobalConnectAttempt)
        guard elapsed < connectRateLimitInterval else { return nil }
        return connectRateLimitInterval - elapsed + 0.05
    }

    private func weakLinkRetryDelay(
        for candidate: BLEConnectionCandidate<Peripheral>,
        now: Date
    ) -> TimeInterval? {
        guard let lastTimeout = recentConnectTimeouts[candidate.peripheralID] else { return nil }
        let elapsed = now.timeIntervalSince(lastTimeout)
        guard elapsed < weakLinkCooldownSeconds && candidate.rssi <= weakLinkRSSICutoff else { return nil }
        let remaining = weakLinkCooldownSeconds - elapsed
        return min(max(2.0, remaining), 15.0)
    }

    // The disconnect settle window must hold on the queue path too: a stale
    // candidate enqueued while the peripheral was still connected would
    // otherwise reconnect immediately via the post-disconnect queue drain,
    // bypassing the window and recreating reconnect/cancel thrash.
    private func disconnectSettleDelay(
        for candidate: BLEConnectionCandidate<Peripheral>,
        now: Date
    ) -> TimeInterval? {
        guard let lastDisconnect = recentDisconnects[candidate.peripheralID] else { return nil }
        let remaining = TransportConfig.bleDisconnectDiscoveryIgnoreSeconds - now.timeIntervalSince(lastDisconnect)
        guard remaining > 0 else { return nil }
        return remaining + 0.05
    }

    private func score(_ candidate: BLEConnectionCandidate<Peripheral>, now: Date) -> Int {
        let failures = failureCounts[candidate.peripheralID] ?? 0
        let penalty = min(20, 1 << min(4, failures))
        let timeoutBias = recentConnectTimeouts[candidate.peripheralID].map {
            now.timeIntervalSince($0) < 60 ? 10 : 0
        } ?? 0
        let base = (candidate.isConnectable ? 1000 : 0) + (candidate.rssi + 100) * 2
        let recency = -Int(now.timeIntervalSince(candidate.discoveredAt) * 10)
        return base + recency - penalty - timeoutBias
    }
}
