import BitLogger
import Foundation

struct LocationNotesCounterDependencies {
    typealias RelayLookup = @MainActor (_ geohash: String, _ count: Int) -> [String]
    typealias Subscribe = @MainActor (_ filter: NostrFilter, _ id: String, _ relays: [String], _ handler: @escaping (NostrEvent) -> Void, _ onEOSE: (() -> Void)?) -> Void
    typealias Unsubscribe = @MainActor (_ id: String) -> Void

    var relayLookup: RelayLookup
    var subscribe: Subscribe
    var unsubscribe: Unsubscribe

    static let live = LocationNotesCounterDependencies(
        relayLookup: { geohash, count in
            GeoRelayDirectory.shared.closestRelays(toGeohash: geohash, count: count)
        },
        subscribe: { filter, id, relays, handler, onEOSE in
            NostrRelayManager.shared.subscribe(
                filter: filter,
                id: id,
                relayUrls: relays,
                handler: handler,
                onEOSE: onEOSE
            )
        },
        unsubscribe: { id in
            NostrRelayManager.shared.unsubscribe(id: id)
        }
    )
}

/// Lightweight background counter for location notes (kind 1) at building-level geohash (8 chars).
@MainActor
final class LocationNotesCounter: ObservableObject {
    static let shared = LocationNotesCounter()

    @Published private(set) var geohash: String? = nil
    @Published private(set) var count: Int? = 0
    @Published private(set) var initialLoadComplete: Bool = false
    @Published private(set) var relayAvailable: Bool = true

    private var subscriptionID: String? = nil
    private var noteIDs = Set<String>()
    private let dependencies: LocationNotesCounterDependencies

    private init(dependencies: LocationNotesCounterDependencies = .live) {
        self.dependencies = dependencies
    }

    init(testDependencies: LocationNotesCounterDependencies) {
        self.dependencies = testDependencies
    }

    func subscribe(geohash gh: String) {
        let norm = gh.lowercased()
        if geohash == norm, subscriptionID != nil { return }
        // Unsubscribe previous without clearing count to avoid flicker
        if let sub = subscriptionID { dependencies.unsubscribe(sub) }
        subscriptionID = nil
        geohash = norm
        noteIDs.removeAll()
        initialLoadComplete = false
        relayAvailable = true

        // Subscribe only to the building geohash (precision 8)
        let subID = "locnotes-count-\(norm)-\(UUID().uuidString.prefix(6))"
        let relays = dependencies.relayLookup(norm, TransportConfig.nostrGeoRelayCount)
        guard !relays.isEmpty else {
            relayAvailable = false
            initialLoadComplete = true
            count = 0
            SecureLogger.warning("LocationNotesCounter: no geo relays for geohash=\(norm)", category: .session)
            return
        }

        subscriptionID = subID
        let filter = NostrFilter.geohashNotes(norm, since: nil, limit: 500)
        dependencies.subscribe(filter, subID, relays, { [weak self] event in
            guard let self = self else { return }
            guard event.kind == NostrProtocol.EventKind.textNote.rawValue else { return }
            guard event.tags.contains(where: { $0.count >= 2 && $0[0].lowercased() == "g" && $0[1].lowercased() == norm }) else { return }
            if !self.noteIDs.contains(event.id) {
                self.noteIDs.insert(event.id)
                self.count = self.noteIDs.count
            }
        }, { [weak self] in
            self?.initialLoadComplete = true
        })
    }

    func cancel() {
        if let sub = subscriptionID { dependencies.unsubscribe(sub) }
        subscriptionID = nil
        geohash = nil
        count = 0
        noteIDs.removeAll()
        relayAvailable = true
    }
}
