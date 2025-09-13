import Foundation

/// Persistent location notes (Nostr kind 1) scoped to a street-level geohash (precision 7).
/// Subscribes to and publishes notes for a given geohash and provides a send API.
@MainActor
final class LocationNotesManager: ObservableObject {
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
    private var subscriptionID: String?

    init(geohash: String) {
        self.geohash = geohash.lowercased()
        subscribe()
    }

    func setGeohash(_ newGeohash: String) {
        let norm = newGeohash.lowercased()
        guard norm != geohash else { return }
        if let sub = subscriptionID {
            NostrRelayManager.shared.unsubscribe(id: sub)
            subscriptionID = nil
        }
        geohash = norm
        notes.removeAll()
        subscribe()
    }

    private func subscribe() {
        let subID = "locnotes-\(geohash)-\(UUID().uuidString.prefix(8))"
        subscriptionID = subID
        // For persistent notes, allow relays to return recent history without an aggressive time cutoff
        let filter = NostrFilter.geohashNotes(geohash, since: nil, limit: 200)
        let relays = GeoRelayDirectory.shared.closestRelays(toGeohash: geohash, count: TransportConfig.nostrGeoRelayCount)
        let relayUrls: [String]? = relays.isEmpty ? nil : relays
        initialLoadComplete = false
        NostrRelayManager.shared.subscribe(filter: filter, id: subID, relayUrls: relayUrls, handler: { [weak self] event in
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
        }, onEOSE: { [weak self] in
            self?.initialLoadComplete = true
        })
    }

    /// Send a location note for the current geohash using the per-geohash identity.
    func send(content: String, nickname: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let id = try NostrIdentityBridge.deriveIdentity(forGeohash: geohash)
            let event = try NostrProtocol.createGeohashTextNote(
                content: trimmed,
                geohash: geohash,
                senderIdentity: id,
                nickname: nickname
            )
            let relays = GeoRelayDirectory.shared.closestRelays(toGeohash: geohash, count: TransportConfig.nostrGeoRelayCount)
            NostrRelayManager.shared.sendEvent(event, to: relays)
            // Optimistic local-echo
            let echo = Note(id: event.id, pubkey: id.publicKeyHex, content: trimmed, createdAt: Date(), nickname: nickname)
            self.notes.insert(echo, at: 0)
        } catch {
            SecureLogger.error("LocationNotesManager: failed to send note: \(error)", category: .session)
        }
    }

    /// Explicitly cancel subscription and release resources.
    func cancel() {
        if let sub = subscriptionID {
            NostrRelayManager.shared.unsubscribe(id: sub)
            subscriptionID = nil
        }
    }
}
