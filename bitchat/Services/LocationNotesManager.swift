import BitLogger
import Combine
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
    // Fires when the geo relay directory refreshes; used to retry after "no relays".
    var relayDirectoryUpdates: AnyPublisher<Void, Never> = Empty(completeImmediately: false).eraseToAnyPublisher()
    /// Whether any of the target relays has a live connection — distinguishes
    /// "loaded, empty" from "still connecting (Tor warming up)" when EOSE
    /// fires without data. Defaults to true so tests keep legacy behavior.
    var anyRelayConnected: @MainActor (_ relayUrls: [String]) -> Bool = { _ in true }

    private static let idBridge = NostrIdentityBridge()

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
            try idBridge.deriveIdentity(forGeohash: geohash)
        },
        now: { Date() },
        relayDirectoryUpdates: NotificationCenter.default
            .publisher(for: .geoRelayDirectoryDidRefresh)
            .map { _ in () }
            .eraseToAnyPublisher(),
        anyRelayConnected: { relayUrls in
            NostrRelayManager.shared.isAnyRelayConnected(among: relayUrls)
        }
    )
}

/// Persistent location notes (Nostr kind 1) scoped to a building-level geohash (precision 8).
/// Subscribes to and publishes notes for a given geohash and provides a send API.
@MainActor
final class LocationNotesManager: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        /// The initial fetch timed out with zero target relays connected
        /// (usually Tor still bootstrapping): not "empty", just not there
        /// yet. Retries automatically once a relay comes up.
        case connecting
        case ready
        case noRelays
    }

    struct Note: Identifiable, Equatable {
        let id: String
        let pubkey: String
        let content: String
        let createdAt: Date
        let nickname: String?
        /// The matched `g` tag: the cell the note was posted to, which can be
        /// a neighbor of the subscribed geohash.
        let geohash: String
        /// NIP-40 expiration, when the note carries one (dead drops do).
        let expiresAt: Date?
        /// Carries a `["t","urgent"]` tag (parity with urgent board posts).
        let isUrgent: Bool

        init(
            id: String,
            pubkey: String,
            content: String,
            createdAt: Date,
            nickname: String?,
            geohash: String,
            expiresAt: Date? = nil,
            isUrgent: Bool = false
        ) {
            self.id = id
            self.pubkey = pubkey
            self.content = content
            self.createdAt = createdAt
            self.nickname = nickname
            self.geohash = geohash
            self.expiresAt = expiresAt
            self.isUrgent = isUrgent
        }

        var displayName: String {
            let suffix = String(pubkey.suffix(4))
            if let nick = nickname?.trimmedOrNilIfEmpty {
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
    /// Public key of our per-geohash Nostr identity; identifies our own notes.
    private var ownPubkey: String?
    private var subscriptionID: String?
    private var noteIDs = Set<String>() // O(1) duplicate detection
    private var directoryUpdateCancellable: AnyCancellable?
    private var expiryPruneTimer: Timer?
    private var connectivityRetryTimer: Timer?
    private let dependencies: LocationNotesDependencies
    private let maxNotesInMemory = 500 // Defensive cap (relay limit is 200)

    private enum Strings {
        static let noRelays = String(localized: "location_notes.error.no_relays", comment: "Shown when no geo relays are available near the selected location")

        static func failedToSend(_ detail: String) -> String {
            String(
                format: String(localized: "location_notes.error.failed_to_send", comment: "Shown when a location note fails to send"),
                locale: .current,
                detail
            )
        }
    }

    init(geohash: String, dependencies: LocationNotesDependencies = .live) {
        let norm = geohash.lowercased()
        self.geohash = norm
        self.dependencies = dependencies
        if !Geohash.isValidGeohash(norm) {
            SecureLogger.warning("LocationNotesManager: invalid geohash '\(norm)' (expected 1-12 valid base32 chars)", category: .session)
        }
        ownPubkey = (try? dependencies.deriveIdentity(norm))?.publicKeyHex
        subscribe()
        // The relay directory may load after init (remote fetch over Tor);
        // retry automatically instead of staying stuck on "no relays".
        directoryUpdateCancellable = dependencies.relayDirectoryUpdates
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.state == .noRelays else { return }
                    self.subscribe()
                }
            }
        // NIP-40 notes can expire while displayed (a 24h dead drop crossing
        // its boundary); ingest-time filtering alone would keep it visible
        // until the subscription is recreated.
        expiryPruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pruneExpiredNotes()
            }
        }
    }

    deinit {
        expiryPruneTimer?.invalidate()
        connectivityRetryTimer?.invalidate()
        // A live REQ must not outlive its manager: relays would keep
        // streaming events nobody consumes. deinit is nonisolated, so hop to
        // the main actor with just the captured closure and id.
        if let sub = subscriptionID {
            let unsubscribe = dependencies.unsubscribe
            Task { @MainActor in
                unsubscribe(sub)
            }
        }
    }

    /// Drops notes whose NIP-40 expiry has passed. Their ids stay in
    /// `noteIDs` so a relay replay cannot resurrect them.
    func pruneExpiredNotes() {
        let now = dependencies.now()
        let expired = notes.contains { note in
            if let expiresAt = note.expiresAt { return expiresAt <= now }
            return false
        }
        guard expired else { return }
        notes.removeAll { note in
            if let expiresAt = note.expiresAt { return expiresAt <= now }
            return false
        }
    }

    // A manager's geohash is fixed for its lifetime: instances are pooled
    // per geohash (`LocationNotesPool`), so retargeting one in place would
    // corrupt the pool's keying and refcounts. Release the manager and
    // acquire the new cell instead.

    func refresh() {
        if let sub = subscriptionID {
            dependencies.unsubscribe(sub)
            subscriptionID = nil
        }
        // Set loading state before clearing to prevent empty state flicker
        state = .loading
        initialLoadComplete = false
        errorMessage = nil
        notes.removeAll()
        noteIDs.removeAll()
        subscribe()
    }

    func clearError() {
        errorMessage = nil
    }

    private func subscribe() {
        state = .loading
        errorMessage = nil
        connectivityRetryTimer?.invalidate()
        connectivityRetryTimer = nil
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
            errorMessage = Strings.noRelays
            SecureLogger.warning("LocationNotesManager: no geo relays for geohash=\(geohash)", category: .session)
            return
        }

        subscriptionID = subID
        initialLoadComplete = false

        // Subscribe to center + 8 neighbors (± 1 grid)
        let neighbors = Geohash.neighbors(of: geohash)
        let allGeohashes = [geohash] + neighbors
        let filter = NostrFilter.geohashNotes(allGeohashes, since: nil, limit: 200)

        // Build a set of valid geohashes for tag matching (includes all 9 cells)
        let validGeohashes = Set(allGeohashes.map { $0.lowercased() })

        dependencies.subscribe(filter, subID, relays, { [weak self] event in
            guard let self = self else { return }
            guard event.kind == NostrProtocol.EventKind.textNote.rawValue else { return }
            // Ensure matching tag - accept any of our 9 geohashes
            guard let matchedGeohash = event.tags.first(where: { tag in
                tag.count >= 2 && tag[0].lowercased() == "g" && validGeohashes.contains(tag[1].lowercased())
            })?[1].lowercased() else { return }
            guard !self.noteIDs.contains(event.id) else { return }
            // NIP-40: relays are not required to enforce expiration — drop
            // expired notes client-side so 24h dead drops actually vanish.
            let expiresAt = Self.expirationDate(of: event)
            if let expiresAt, expiresAt <= self.dependencies.now() { return }
            self.noteIDs.insert(event.id)
            let nick = event.tags.first(where: { $0.first?.lowercased() == "n" && $0.count >= 2 })?.dropFirst().first
            let ts = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            let urgent = event.tags.contains { $0.count >= 2 && $0[0].lowercased() == "t" && $0[1].lowercased() == "urgent" }
            let note = Note(id: event.id, pubkey: event.pubkey, content: event.content, createdAt: ts, nickname: nick, geohash: matchedGeohash, expiresAt: expiresAt, isUrgent: urgent)
            self.notes.append(note)
            self.notes.sort { $0.createdAt > $1.createdAt }
            self.enforceMemoryCap()
            self.state = .ready
        }, { [weak self] in
            guard let self = self else { return }
            self.initialLoadComplete = true
            guard self.state != .noRelays else { return }
            // EOSE with no data and zero connected target relays means the
            // 10s fallback fired while Tor was still warming up — showing
            // "no notes" would be a lie. Wait visibly and retry.
            if self.notes.isEmpty, !self.dependencies.anyRelayConnected(relays) {
                self.state = .connecting
                self.scheduleConnectivityRetry(relays: relays)
            } else {
                self.state = .ready
            }
        })
    }

    /// While `.connecting`, poll for a live target relay and re-subscribe as
    /// soon as one appears (fresh REQ, fresh EOSE tracking). The poll dies
    /// with the state: any subscribe/cancel invalidates it.
    private func scheduleConnectivityRetry(relays: [String]) {
        connectivityRetryTimer?.invalidate()
        connectivityRetryTimer = Timer.scheduledTimer(
            withTimeInterval: TransportConfig.uiGeoNotesConnectivityRetrySeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.retryIfRelaysAvailable(relays: relays)
            }
        }
    }

    func retryIfRelaysAvailable(relays: [String]) {
        guard state == .connecting else {
            connectivityRetryTimer?.invalidate()
            connectivityRetryTimer = nil
            return
        }
        guard dependencies.anyRelayConnected(relays) else { return }
        connectivityRetryTimer?.invalidate()
        connectivityRetryTimer = nil
        SecureLogger.debug("LocationNotesManager: relay came up, retrying notes fetch for \(geohash)", category: .session)
        refresh()
    }

    /// Send a location note for the current geohash using the per-geohash
    /// identity, optionally expiring via NIP-40 (dead drops pass 24h; the
    /// composer's ∞ option passes nil) and optionally tagged urgent.
    func send(content: String, nickname: String, expiresAt: Date? = nil, urgent: Bool = false) {
        guard let trimmed = content.trimmedOrNilIfEmpty else { return }
        let relays = dependencies.relayLookup(geohash, TransportConfig.nostrGeoRelayCount)
        guard !relays.isEmpty else {
            state = .noRelays
            errorMessage = Strings.noRelays
            SecureLogger.warning("LocationNotesManager: send blocked, no geo relays for geohash=\(geohash)", category: .session)
            return
        }
        do {
            let id = try dependencies.deriveIdentity(geohash)
            let event = try NostrProtocol.createGeohashTextNote(
                content: trimmed,
                geohash: geohash,
                senderIdentity: id,
                nickname: nickname,
                expiresAt: expiresAt,
                urgent: urgent
            )
            dependencies.sendEvent(event, relays)
            // Optimistic local-echo
            let echo = Note(
                id: event.id,
                pubkey: id.publicKeyHex,
                content: trimmed,
                createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
                nickname: nickname,
                geohash: geohash,
                expiresAt: expiresAt,
                isUrgent: urgent
            )
            self.noteIDs.insert(event.id)
            self.notes.insert(echo, at: 0)
            self.enforceMemoryCap()
            self.state = .ready
            self.errorMessage = nil
        } catch {
            SecureLogger.error("LocationNotesManager: failed to send note: \(error)", category: .session)
            errorMessage = Strings.failedToSend(error.localizedDescription)
        }
    }

    /// Whether the note was published by this device's identity for the
    /// current geohash (and can therefore be deleted with NIP-09).
    func isOwnNote(_ note: Note) -> Bool {
        guard let ownPubkey else { return false }
        return note.pubkey == ownPubkey
    }

    /// Requests NIP-09 deletion of one of our own notes and removes it locally.
    @discardableResult
    func delete(note: Note) -> Bool {
        guard isOwnNote(note) else { return false }
        let relays = dependencies.relayLookup(geohash, TransportConfig.nostrGeoRelayCount)
        guard !relays.isEmpty else {
            state = .noRelays
            errorMessage = Strings.noRelays
            return false
        }
        do {
            let identity = try dependencies.deriveIdentity(geohash)
            let deletion = try NostrProtocol.createDeleteEvent(ofEventID: note.id, senderIdentity: identity)
            dependencies.sendEvent(deletion, relays)
            // Keep the id in noteIDs so a relay replay can't resurrect it.
            notes.removeAll { $0.id == note.id }
            return true
        } catch {
            SecureLogger.error("LocationNotesManager: failed to delete note: \(error)", category: .session)
            return false
        }
    }

    /// The NIP-40 `expiration` tag as a date, if the event carries one.
    static func expirationDate(of event: NostrEvent) -> Date? {
        guard let tag = event.tags.first(where: { $0.count >= 2 && $0[0].lowercased() == "expiration" }),
              let seconds = TimeInterval(tag[1])
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Enforces defensive memory cap on notes array (keeps newest).
    private func enforceMemoryCap() {
        if notes.count > maxNotesInMemory {
            let removed = notes.count - maxNotesInMemory
            notes = Array(notes.prefix(maxNotesInMemory))
            SecureLogger.debug("LocationNotesManager: trimmed \(removed) old notes (cap: \(maxNotesInMemory))", category: .session)
        }
    }

    /// One-shot dead-drop publish without holding a subscription: pins a
    /// note to `geohash` that expires via NIP-40. Returns false when no geo
    /// relays are known or signing fails.
    @MainActor
    static func postDrop(
        content: String,
        nickname: String,
        geohash: String,
        expiry: TimeInterval = TransportConfig.locationDropExpirySeconds,
        dependencies: LocationNotesDependencies = .live
    ) -> Bool {
        guard let trimmed = content.trimmedOrNilIfEmpty else { return false }
        let relays = dependencies.relayLookup(geohash, TransportConfig.nostrGeoRelayCount)
        guard !relays.isEmpty else {
            SecureLogger.warning("LocationNotesManager: drop blocked, no geo relays for geohash=\(geohash)", category: .session)
            return false
        }
        do {
            let identity = try dependencies.deriveIdentity(geohash)
            let event = try NostrProtocol.createGeohashTextNote(
                content: trimmed,
                geohash: geohash,
                senderIdentity: identity,
                nickname: nickname,
                expiresAt: dependencies.now().addingTimeInterval(expiry)
            )
            dependencies.sendEvent(event, relays)
            return true
        } catch {
            SecureLogger.error("LocationNotesManager: failed to post drop: \(error)", category: .session)
            return false
        }
    }

    /// Explicitly cancel the subscription. The prune timer stays alive (it
    /// holds only a weak self) so a reused instance — the notices sheet
    /// cancels on tab switch and refreshes on return — keeps pruning.
    func cancel() {
        if let sub = subscriptionID {
            dependencies.unsubscribe(sub)
            subscriptionID = nil
        }
        connectivityRetryTimer?.invalidate()
        connectivityRetryTimer = nil
        state = .idle
        errorMessage = nil
    }
}
