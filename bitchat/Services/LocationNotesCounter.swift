import Foundation

/// Lightweight background counter for location notes (kind 1) at block-level geohash.
@MainActor
final class LocationNotesCounter: ObservableObject {
    static let shared = LocationNotesCounter()

    @Published private(set) var geohash: String? = nil
    @Published private(set) var count: Int? = 0
    @Published private(set) var initialLoadComplete: Bool = false

    private var subscriptionID: String? = nil
    private var noteIDs = Set<String>()

    private init() {}

    func subscribe(geohash gh: String) {
        let norm = gh.lowercased()
        if geohash == norm { return }
        cancel()
        geohash = norm
        count = 0
        noteIDs.removeAll()
        initialLoadComplete = false

        // Subscribe only to the building geohash (precision 8)
        let subID = "locnotes-count-\(norm)-\(UUID().uuidString.prefix(6))"
        subscriptionID = subID
        let filter = NostrFilter.geohashNotes(norm, since: nil, limit: 500)
        let relays = GeoRelayDirectory.shared.closestRelays(toGeohash: norm, count: TransportConfig.nostrGeoRelayCount)
        let relayUrls: [String]? = relays.isEmpty ? nil : relays
        NostrRelayManager.shared.subscribe(filter: filter, id: subID, relayUrls: relayUrls, handler: { [weak self] event in
            guard let self = self else { return }
            guard event.kind == NostrProtocol.EventKind.textNote.rawValue else { return }
            guard event.tags.contains(where: { $0.count >= 2 && $0[0].lowercased() == "g" && $0[1].lowercased() == norm }) else { return }
            if !self.noteIDs.contains(event.id) {
                self.noteIDs.insert(event.id)
                self.count = self.noteIDs.count
            }
        }, onEOSE: { [weak self] in
            self?.initialLoadComplete = true
        })
    }

    func cancel() {
        if let sub = subscriptionID { NostrRelayManager.shared.unsubscribe(id: sub) }
        subscriptionID = nil
        geohash = nil
        count = 0
        noteIDs.removeAll()
    }
}
