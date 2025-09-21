import BitLogger
import Foundation

/// Dependencies for location notes, allowing tests to stub relay/identity behavior.
struct LocationNotesDependencies {
    typealias RelayLookup = @MainActor (_ geohash: String, _ count: Int) -> [String]
    typealias Subscribe = @MainActor (_ filter: NostrFilter, _ id: String, _ relays: [String], _ handler: @escaping (NostrEvent) -> Void, _ onEOSE: (() -> Void)?) -> Void
    typealias Unsubscribe = @MainActor (_ id: String) -> Void
    typealias SendEvent = @MainActor (_ event: NostrEvent, _ relayUrls: [String]) -> Void

    var relayLookup: RelayLookup
    var subscribe: Subscribe
    var unsubscribe: Unsubscribe
    var sendEvent: SendEvent
    var deriveIdentity: (_ geohash: String) throws -> NostrIdentity
    var now: () -> Date

    static let live = LocationNotesDependencies(
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
        },
        sendEvent: { event, relays in
            NostrRelayManager.shared.sendEvent(event, to: relays)
        },
        deriveIdentity: { geohash in
            try NostrIdentityBridge.deriveIdentity(forGeohash: geohash)
        },
        now: { Date() }
    )
}

/// Persistent location notes (Nostr kind 1) scoped to a building-level geohash (precision 8).
/// Subscribes to and publishes notes for a given geohash and provides a send API.
@MainActor
final class LocationNotesManager: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case ready
        case noRelays
    }

    struct Note: Identifiable, Equatable {
        let id: String
        let pubkey: String
        let content: String
        let createdAt: Date
        let nickname: String?

        var displayName: String {
            let suffix = String(pubkey.suffix(4))
            if let nick = nickname, !nick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(nick)#\(suffix)"
            }
            return "anon#\(suffix)"
        }
    }

    @Published private(set) var notes: [Note] = [] // reverse-chron sorted
    @Published private(set) var geohash: String
    @Published private(set) var initialLoadComplete: Bool = false
    @Published private(set) var state: State = .loading
    @Published private(set) var errorMessage: String?
    private var subscriptionID: String?
    private let dependencies: LocationNotesDependencies

    init(geohash: String, dependencies: LocationNotesDependencies = .live) {
        self.geohash = geohash.lowercased()
        self.dependencies = dependencies
        subscribe()
    }

    func setGeohash(_ newGeohash: String) {
        let norm = newGeohash.lowercased()
        guard norm != geohash else { return }
        if let sub = subscriptionID {
            dependencies.unsubscribe(sub)
            subscriptionID = nil
        }
        geohash = norm
        notes.removeAll()
        subscribe()
    }

    func refresh() {
        if let sub = subscriptionID {
            dependencies.unsubscribe(sub)
            subscriptionID = nil
        }
        notes.removeAll()
        subscribe()
    }

    func clearError() {
        errorMessage = nil
    }

    private func subscribe() {
        state = .loading
        errorMessage = nil
        if let sub = subscriptionID {
            dependencies.unsubscribe(sub)
            subscriptionID = nil
        }
        let subID = "locnotes-\(geohash)-\(UUID().uuidString.prefix(8))"
        let relays = dependencies.relayLookup(geohash, TransportConfig.nostrGeoRelayCount)
        guard !relays.isEmpty else {
            subscriptionID = nil
            initialLoadComplete = true
            state = .noRelays
            errorMessage = "No geo relays available near this location. Try again soon."
            SecureLogger.warning("LocationNotesManager: no geo relays for geohash=\(geohash)", category: .session)
            return
        }

        subscriptionID = subID
        initialLoadComplete = false
        // For persistent notes, allow relays to return recent history without an aggressive time cutoff
        let filter = NostrFilter.geohashNotes(geohash, since: nil, limit: 200)

        dependencies.subscribe(filter, subID, relays, { [weak self] event in
            guard let self = self else { return }
            guard event.kind == NostrProtocol.EventKind.textNote.rawValue else { return }
            // Ensure matching tag
            guard event.tags.contains(where: { $0.count >= 2 && $0[0].lowercased() == "g" && $0[1].lowercased() == self.geohash }) else { return }
            if self.notes.contains(where: { $0.id == event.id }) { return }
            let nick = event.tags.first(where: { $0.first?.lowercased() == "n" && $0.count >= 2 })?.dropFirst().first
            let ts = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            let note = Note(id: event.id, pubkey: event.pubkey, content: event.content, createdAt: ts, nickname: nick)
            self.notes.append(note)
            self.notes.sort { $0.createdAt > $1.createdAt }
            self.state = .ready
        }, { [weak self] in
            guard let self = self else { return }
            self.initialLoadComplete = true
            if self.state != .noRelays {
                self.state = .ready
            }
        })
    }

    /// Send a location note for the current geohash using the per-geohash identity.
    func send(content: String, nickname: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let relays = dependencies.relayLookup(geohash, TransportConfig.nostrGeoRelayCount)
        guard !relays.isEmpty else {
            state = .noRelays
            errorMessage = "No geo relays available near this location. Try again soon."
            SecureLogger.warning("LocationNotesManager: send blocked, no geo relays for geohash=\(geohash)", category: .session)
            return
        }
        do {
            let id = try dependencies.deriveIdentity(geohash)
            let event = try NostrProtocol.createGeohashTextNote(
                content: trimmed,
                geohash: geohash,
                senderIdentity: id,
                nickname: nickname
            )
            dependencies.sendEvent(event, relays)
            // Optimistic local-echo
            let echo = Note(
                id: event.id,
                pubkey: id.publicKeyHex,
                content: trimmed,
                createdAt: dependencies.now(),
                nickname: nickname
            )
            self.notes.insert(echo, at: 0)
            self.state = .ready
            self.errorMessage = nil
        } catch {
            SecureLogger.error("LocationNotesManager: failed to send note: \(error)", category: .session)
            errorMessage = "Failed to send note. \(error.localizedDescription)"
        }
    }

    /// Explicitly cancel subscription and release resources.
    func cancel() {
        if let sub = subscriptionID {
            dependencies.unsubscribe(sub)
            subscriptionID = nil
        }
        state = .idle
        errorMessage = nil
    }
}
