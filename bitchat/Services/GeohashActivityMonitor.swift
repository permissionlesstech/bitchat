//
// GeohashActivityMonitor.swift
// bitchat
//
// Watches worldwide geohash chat traffic while the globe picker is open.
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Watches worldwide geohash chat traffic while the globe picker is open.
///
/// Subscribes to kind 20000 (last hour) and kind 20001 (last five minutes) with no
/// `g` filter, so the request says nothing about where the user is. Relays are a
/// fixed worldwide spread plus the few nearest to wherever the user rests the
/// globe. `NostrRelayManager` verifies every event's signature and id before
/// delivery and deduplicates per subscription, so this sweep never consumes
/// events the open chat still needs. `stop()` closes the subscriptions and
/// releases the relays the monitor opened.
@MainActor
final class GeohashActivityMonitor: ObservableObject {
    enum Status: Equatable {
        case connecting
        case live
        case offline
    }

    @Published private(set) var snapshot: GeohashActivitySnapshot = .empty
    @Published private(set) var status: Status = .connecting

    private let relayManager: NostrRelayManager?
    private let relayDirectory: GeoRelayDirectory?
    /// Blocked identities, hidden from counts exactly as the channel sheet hides them.
    private let isBlocked: (String) -> Bool
    /// Whether the app may and can reach the network at all; while it can, the
    /// monitor reports "connecting" (Tor may take a while to bootstrap).
    private let isNetworkAvailable: () -> Bool
    private var aggregator = GeohashActivityAggregator()

    private var isRunning = false
    private var subscriptionIDs: [String] = []
    private var subscribedRelays: Set<String> = []
    private var openedRelays: Set<String> = []
    private var publishTimer: Timer?
    private var focusTask: Task<Void, Never>?
    private var lastFocusCell: String?
    private var dirty = false
    private var lastPublishedAt = Date.distantPast

    private enum Constants {
        /// Population hubs used only to spread relays around the world.
        static let sweepAnchors = [
            "9q", "dr", "dn", "9g", "d5", "6g", "69", "gc", "u0", "u3", "uc", "sr",
            "sx", "st", "s1", "kz", "tt", "te", "w2", "wx", "xn", "r3"
        ]
        static let relaysPerAnchor = 2
        static let relaysPerFocus = 3
        static let maxSweepRelays = 24
        static let maxTotalRelays = 36
        static let focusPrecision = 3
        static let focusSettle: Duration = .milliseconds(1_200)
        static let requestLimit = 500
        static let publishInterval: TimeInterval = 0.5
        /// Republish at least this often so people leave the presence window on time
        /// even when no new events arrive.
        static let refreshInterval: TimeInterval = 15
    }

    /// - Parameter relayManager: nil observes nothing (previews and tests feed `ingest`).
    init(
        relayManager: NostrRelayManager? = .shared,
        relayDirectory: GeoRelayDirectory? = .shared,
        isBlocked: @escaping (String) -> Bool = { _ in false },
        isNetworkAvailable: (() -> Bool)? = nil
    ) {
        self.relayManager = relayManager
        self.relayDirectory = relayDirectory
        self.isBlocked = isBlocked
        self.isNetworkAvailable = isNetworkAvailable ?? {
            NetworkActivationService.shared.activationAllowed && NetworkActivationService.shared.isNetworkReachable
        }
    }

    deinit {
        publishTimer?.invalidate()
        focusTask?.cancel()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        status = .connecting
        let timer = Timer(timeInterval: Constants.publishInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        publishTimer = timer
        subscribe(to: sweepRelays())
        if let cell = lastFocusCell {
            subscribe(to: focusRelays(cell))
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        publishTimer?.invalidate()
        publishTimer = nil
        focusTask?.cancel()
        focusTask = nil
        for id in subscriptionIDs {
            relayManager?.unsubscribe(id: id)
        }
        subscriptionIDs.removeAll()
        subscribedRelays.removeAll()
        relayManager?.releaseRelays(Array(openedRelays))
        openedRelays.removeAll()
    }

    /// Tells the monitor where the globe is resting. After a short settle it adds the
    /// relays nearest that region, so quiet local channels show up as well as the
    /// busy hubs.
    func focus(latitude: Double, longitude: Double) {
        let cell = Geohash.encode(latitude: latitude, longitude: longitude, precision: Constants.focusPrecision)
        guard cell != lastFocusCell else { return }
        lastFocusCell = cell
        guard isRunning else { return }
        focusTask?.cancel()
        focusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Constants.focusSettle)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.subscribe(to: self.focusRelays(cell))
        }
    }

    /// Counts one verified kind-20000/20001 event at `seenAt`. Internal for tests
    /// and previews; relay events arrive through `receive(_:subscriptionID:)`.
    @discardableResult
    func ingest(_ event: NostrEvent, seenAt: Date, now: Date = Date()) -> Bool {
        guard event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue
                || event.kind == NostrProtocol.EventKind.geohashPresence.rawValue,
              let geohash = event.tags.first(where: { $0.count >= 2 && $0[0] == "g" })?[1].lowercased(),
              Geohash.isValidGeohash(geohash)
        else { return false }
        let counted = aggregator.record(
            geohash: geohash,
            pubkey: event.pubkey,
            at: seenAt,
            chatEventID: NostrInboundPipeline.chatEventID(event),
            now: now
        )
        if counted { dirty = true }
        return counted
    }

    /// Recomputes the published snapshot. Internal so tests can drive it.
    func publish(now: Date = Date()) {
        aggregator.prune(now: now)
        dirty = false
        lastPublishedAt = now
        let next = aggregator.snapshot(now: now, excluding: isBlocked)
        if next != snapshot { snapshot = next }
    }

    // MARK: - Private

    private func tick() {
        let now = Date()
        if dirty || now.timeIntervalSince(lastPublishedAt) >= Constants.refreshInterval {
            publish(now: now)
        }
        updateStatus()
    }

    private func updateStatus() {
        let connected = relayManager?.isAnyRelayConnected(among: Array(subscribedRelays)) ?? false
        let next = Self.status(relayConnected: connected, networkAvailable: isNetworkAvailable())
        if next != status { status = next }
    }

    /// Re-derived every tick from the monitor's own relays, so a dropped connection
    /// stops reading "live" even while what was seen is still shown, and a late
    /// connection turns live without waiting for traffic.
    static func status(relayConnected: Bool, networkAvailable: Bool) -> Status {
        if relayConnected { return .live }
        return networkAvailable ? .connecting : .offline
    }

    /// Events count when they say they happened (clamped to now by the aggregator).
    /// Unlike the open channel, the sweep cannot tell stored history from live
    /// traffic by EOSE: behind a slow Tor bootstrap the relay manager releases
    /// EOSE callbacks on a timeout, before any history has arrived.
    private func receive(_ event: NostrEvent, subscriptionID: String) {
        guard isRunning, subscriptionIDs.contains(subscriptionID) else { return }
        ingest(event, seenAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)))
    }

    private func sweepRelays() -> [String] {
        guard let relayDirectory else { return [] }
        let nearestPerAnchor = Constants.sweepAnchors.map {
            relayDirectory.closestRelays(toGeohash: $0, count: Constants.relaysPerAnchor)
        }
        var ordered: [String] = []
        var seen = Set<String>()
        for url in NostrRelayManager.builtInRelayURLs.sorted() where seen.insert(url).inserted {
            ordered.append(url)
        }
        for rank in 0..<Constants.relaysPerAnchor {
            for relays in nearestPerAnchor where rank < relays.count {
                if seen.insert(relays[rank]).inserted { ordered.append(relays[rank]) }
            }
        }
        return Array(ordered.prefix(Constants.maxSweepRelays))
    }

    private func focusRelays(_ cell: String) -> [String] {
        let room = Constants.maxTotalRelays - subscribedRelays.count
        guard room > 0, let relayDirectory else { return [] }
        return Array(
            relayDirectory.closestRelays(toGeohash: cell, count: Constants.relaysPerFocus)
                .filter { !subscribedRelays.contains($0) }
                .prefix(room)
        )
    }

    private func subscribe(to relays: [String]) {
        guard isRunning, let relayManager else { return }
        let fresh = relays.compactMap { NostrRelayURL.normalized($0) }.filter { !subscribedRelays.contains($0) }
        guard !fresh.isEmpty else { return }
        let known = Set(relayManager.relays.map(\.url))
        openedRelays.formUnion(fresh.filter { !known.contains($0) })
        subscribedRelays.formUnion(fresh)

        let now = Date()
        let filters = [
            NostrFilter.worldwideGeohashActivity(
                kind: NostrProtocol.EventKind.ephemeralEvent.rawValue,
                since: now.addingTimeInterval(-aggregator.chatWindow),
                limit: Constants.requestLimit
            ),
            NostrFilter.worldwideGeohashActivity(
                kind: NostrProtocol.EventKind.geohashPresence.rawValue,
                since: now.addingTimeInterval(-aggregator.presenceWindow),
                limit: Constants.requestLimit
            )
        ]
        for filter in filters {
            let id = "globe-activity-\(UUID().uuidString)"
            subscriptionIDs.append(id)
            relayManager.subscribe(filter: filter, id: id, relayUrls: fresh) { [weak self] event in
                MainActor.assumeIsolated { self?.receive(event, subscriptionID: id) }
            }
        }
    }
}
