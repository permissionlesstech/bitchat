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
    /// Persistent primary Nostr identity used only when the user opts into
    /// posting with their public handle (`.publicHandle`).
    var publicIdentity: () throws -> NostrIdentity? = { nil }
    /// Publishes an event to the default relay set so followers also receive
    /// place posts signed with `.publicHandle`.
    var sendToDefaultRelays: @MainActor (_ event: NostrEvent) -> Void = { _ in }
    /// Hands a locally signed kind-1/kind-7 event to a nearby BLE gateway peer
    /// when internet relays are unreachable.
    var uplinkViaMesh: @MainActor (_ event: NostrEvent, _ geohash: String) -> Bool = { _, _ in false }
    /// Rebroadcasts an inbound relay kind-1/kind-7 event onto the local BLE mesh
    /// when this device has Gateway Mode enabled.
    var rebroadcastToMesh: @MainActor (_ event: NostrEvent, _ geohash: String) -> Void = { _, _ in }

    private static let idBridge = NostrIdentityBridge.shared

    /// Panic-wipe hook: drop cached per-geohash secp256k1 keys held by the
    /// live dependencies bridge so post-panic notes/drops cannot sign with
    /// pre-panic identities.
    static func clearCachedIdentitiesForPanic() {
        idBridge.clearInMemoryCaches()
    }

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
        },
        publicIdentity: {
            try idBridge.getCurrentNostrIdentity()
        },
        sendToDefaultRelays: { event in
            NostrRelayManager.shared.sendEvent(event)
        },
        uplinkViaMesh: { event, geohash in
            GatewayService.shared.uplinkViaMesh(event: event, geohash: geohash)
        },
        rebroadcastToMesh: { event, geohash in
            GatewayService.shared.rebroadcastRelayEvent(
                event,
                geohash: geohash,
                signatureAlreadyVerified: true
            )
        }
    )
}

/// Persistent location notes and Place Feed (Nostr kind 1 posts/NIP-10 replies
/// + kind 7 NIP-25 reactions) scoped to a geohash and its 8 immediate neighbors.
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
        /// NIP-10 thread root event ID when this note is a reply; nil for top-level posts.
        let rootEventID: String?
        /// NIP-10 direct parent event ID when replying to a reply; nil for root posts or direct replies to root.
        let replyToEventID: String?
        /// Validated NIP-13 proof-of-work difficulty (leading zero bits committed and met).
        let powDifficulty: Int
        /// Carries `["t","teleport"]` when published remotely rather than on-site.
        let isTeleported: Bool
        /// Validated NIP-92 `imeta` Blossom media attachments (HTTPS + SHA-256).
        let attachments: [NostrProtocol.MediaAttachment]

        init(
            id: String,
            pubkey: String,
            content: String,
            createdAt: Date,
            nickname: String?,
            geohash: String,
            expiresAt: Date? = nil,
            isUrgent: Bool = false,
            rootEventID: String? = nil,
            replyToEventID: String? = nil,
            powDifficulty: Int = 0,
            isTeleported: Bool = false,
            attachments: [NostrProtocol.MediaAttachment] = []
        ) {
            self.id = id
            self.pubkey = pubkey
            self.content = content
            self.createdAt = createdAt
            self.nickname = nickname
            self.geohash = geohash
            self.expiresAt = expiresAt
            self.isUrgent = isUrgent
            self.rootEventID = rootEventID?.lowercased()
            let normalizedReply = replyToEventID?.lowercased()
            self.replyToEventID = (normalizedReply == self.rootEventID) ? nil : normalizedReply
            self.powDifficulty = max(0, powDifficulty)
            self.isTeleported = isTeleported
            self.attachments = attachments
        }

        var isReply: Bool { rootEventID != nil }
        var effectiveThreadRootID: String { rootEventID ?? id }
        var authorSuffix: String { String(pubkey.suffix(4)) }
        var shortAuthorName: String { nickname?.trimmedOrNilIfEmpty ?? "anon" }
        var hasVerifiedPoW: Bool { powDifficulty >= NostrProtocol.verifiedPoWThresholdBits }

        var displayName: String {
            let suffix = authorSuffix
            if let nick = nickname?.trimmedOrNilIfEmpty {
                return "\(nick)#\(suffix)"
            }
            return "anon#\(suffix)"
        }
    }

    private struct ReactionTargetKey: Hashable {
        let targetID: String
        let emoji: String
    }

    /// Top-level posts, newest first.
    @Published private(set) var notes: [Note] = []
    /// NIP-10 replies grouped by `rootEventID`, sorted chronologically (oldest -> newest).
    @Published private(set) var repliesByRootID: [String: [Note]] = [:]
    /// Aggregated NIP-25 reactions keyed by target event ID.
    @Published private(set) var reactionsByNoteID: [String: [AggregatedReaction]] = [:]
    @Published private(set) var geohash: String
    @Published private(set) var initialLoadComplete: Bool = false
    @Published private(set) var state: State = .loading
    @Published private(set) var errorMessage: String?
    /// True while an outgoing NIP-13 PoW mining task is running.
    @Published private(set) var isSending: Bool = false

    /// Public key of our per-geohash Nostr identity; identifies our own notes and reactions.
    private var ownPubkey: String?
    /// Public key of our persistent primary Nostr identity (when available), so
    /// notes posted under `.publicHandle` are also recognized as ours for delete/highlight.
    private var ownPublicPubkey: String?
    private var subscriptionID: String?
    private var noteIDs = Set<String>() // O(1) duplicate detection for kind-1 notes & replies
    private var reactionEventIDs = Set<String>() // O(1) dedup for kind-7 reactions
    /// targetEventID -> emoji -> Set<authorPubkey>
    private var reactionActorsByTarget: [String: [String: Set<String>]] = [:]
    /// targetEventID -> insertion order of emojis for stable UI pills
    private var reactionEmojiOrderByTarget: [String: [String]] = [:]
    /// Latest own kind-7 reaction event ID per (target, emoji) so toggling off can emit NIP-09 delete.
    private var ownReactionEventIDs: [ReactionTargetKey: String] = [:]

    private var directoryUpdateCancellable: AnyCancellable?
    private var expiryPruneTimer: Timer?
    private var connectivityRetryTimer: Timer?

    private let dependencies: LocationNotesDependencies
    private let maxNotesInMemory = 500 // Defensive cap (relay limit is 200)
    private let maxRepliesPerThread = 200
    private let maxTrackedReactionEvents = 2_000

    /// Short 4-char hex suffix of our unlinkable per-place pubkey, for composer attribution.
    var ownIdentitySuffix: String? {
        ownPubkey.map { String($0.suffix(4)) }
    }

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
        ownPubkey = (try? dependencies.deriveIdentity(norm))?.publicKeyHex.lowercased()
        ownPublicPubkey = (try? dependencies.publicIdentity())?.publicKeyHex.lowercased()
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
        let pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pruneExpiredNotes()
            }
        }
        pruneTimer.tolerance = 10.0
        expiryPruneTimer = pruneTimer
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

    // MARK: - Thread & Reaction Queries

    /// Chronological (oldest -> newest) NIP-10 replies for a root post.
    func replies(forRootID rootID: String) -> [Note] {
        repliesByRootID[rootID.lowercased()] ?? []
    }

    func replyCount(forRootID rootID: String) -> Int {
        repliesByRootID[rootID.lowercased()]?.count ?? 0
    }

    func reactions(forNoteID noteID: String) -> [AggregatedReaction] {
        reactionsByNoteID[noteID.lowercased()] ?? []
    }

    func totalReactionCount(forNoteID noteID: String) -> Int {
        reactions(forNoteID: noteID).reduce(0) { $0 + $1.count }
    }

    /// Drops notes and replies whose NIP-40 expiry has passed. Their ids stay in
    /// `noteIDs` so a relay replay cannot resurrect them.
    func pruneExpiredNotes() {
        let now = dependencies.now()
        if notes.contains(where: { $0.expiresAt.map { $0 <= now } ?? false }) {
            notes.removeAll { note in
                if let expiresAt = note.expiresAt { return expiresAt <= now }
                return false
            }
        }
        var updatedReplies = repliesByRootID
        var repliesChanged = false
        for (rootID, thread) in repliesByRootID {
            if thread.contains(where: { $0.expiresAt.map { $0 <= now } ?? false }) {
                let remaining = thread.filter { reply in
                    if let expiresAt = reply.expiresAt { return expiresAt > now }
                    return true
                }
                if remaining.isEmpty {
                    updatedReplies.removeValue(forKey: rootID)
                } else {
                    updatedReplies[rootID] = remaining
                }
                repliesChanged = true
            }
        }
        if repliesChanged {
            repliesByRootID = updatedReplies
        }
    }

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
        repliesByRootID.removeAll()
        reactionsByNoteID.removeAll()
        noteIDs.removeAll()
        reactionEventIDs.removeAll()
        reactionActorsByTarget.removeAll()
        reactionEmojiOrderByTarget.removeAll()
        ownReactionEventIDs.removeAll()
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

        // Subscribe to center + 8 neighbors (± 1 grid) for kind-1 notes/replies
        // and kind-7 NIP-25 reactions in one REQ to preserve Tor socket budget.
        let neighbors = Geohash.neighbors(of: geohash)
        let allGeohashes = [geohash] + neighbors
        let filter = NostrFilter.geohashFeed(allGeohashes, since: nil, limit: 200)

        // Build a set of valid geohashes for tag matching (includes all 9 cells)
        let validGeohashes = Set(allGeohashes.map { $0.lowercased() })

        dependencies.subscribe(filter, subID, relays, { [weak self] event in
            guard let self = self else { return }
            self.ingestInboundEvent(event, validGeohashes: validGeohashes, fromGateway: false)
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
            } else if self.state != .ready {
                self.state = .ready
            }
        })
    }

    /// Injects a Schnorr-verified kind-1 or kind-7 event carried over BLE by a
    /// nearby Gateway peer. Never re-broadcasts back to the mesh (loop rule 1).
    func ingestCarriedEvent(_ event: NostrEvent) {
        let validGeohashes = Set(([geohash] + Geohash.neighbors(of: geohash)).map { $0.lowercased() })
        ingestInboundEvent(event, validGeohashes: validGeohashes, fromGateway: true)
    }

    private func ingestInboundEvent(_ event: NostrEvent, validGeohashes: Set<String>, fromGateway: Bool) {
        switch event.kind {
        case NostrProtocol.EventKind.textNote.rawValue:
            if let matchedGeohash = ingestTextNote(event, validGeohashes: validGeohashes), !fromGateway {
                dependencies.rebroadcastToMesh(event, matchedGeohash)
            }
        case NostrProtocol.EventKind.reaction.rawValue:
            if let matchedGeohash = ingestReaction(event, validGeohashes: validGeohashes), !fromGateway {
                dependencies.rebroadcastToMesh(event, matchedGeohash)
            }
        default:
            return
        }
    }

    @discardableResult
    private func ingestTextNote(_ event: NostrEvent, validGeohashes: Set<String>) -> String? {
        let normalizedID = event.id.lowercased()
        guard !noteIDs.contains(normalizedID) else { return nil }

        // Single pass over tags: match any of our 9 cells + extract nick/expiration/urgent/teleport.
        var matchedGeohash: String?
        var nick: String?
        var expiresAt: Date?
        var urgent = false
        var teleported = false
        for tag in event.tags where tag.count >= 2 {
            let key = tag[0].lowercased()
            switch key {
            case "g":
                if matchedGeohash == nil {
                    let candidate = tag[1].lowercased()
                    if validGeohashes.contains(candidate) {
                        matchedGeohash = candidate
                    }
                }
            case "n":
                if nick == nil {
                    nick = tag[1]
                }
            case "expiration":
                if expiresAt == nil, let seconds = TimeInterval(tag[1]) {
                    expiresAt = Date(timeIntervalSince1970: seconds)
                }
            case "t":
                let value = tag[1].lowercased()
                if value == "urgent" {
                    urgent = true
                } else if value == "teleport" {
                    teleported = true
                }
            default:
                break
            }
        }
        guard let matchedGeohash else { return nil }
        // NIP-40: relays are not required to enforce expiration — drop
        // expired notes client-side so 24h dead drops actually vanish.
        let now = dependencies.now()
        if let expiresAt, expiresAt <= now { return nil }
        recordNoteID(normalizedID)

        // created_at is author-chosen; clamp so a future-dated note can't
        // hold the top of the newest-first list past the memory cap. The
        // bound is the board's clock-skew allowance: a bridged copy of an
        // accepted board post must keep its timestamp, or
        // UnifiedNotices.merge no longer recognizes it as the same notice.
        let latestAccepted = now
            .addingTimeInterval(TimeInterval(BoardStore.Limits.clockSkewMs) / 1000)
        let ts = min(Date(timeIntervalSince1970: TimeInterval(event.created_at)), latestAccepted)

        let threadRef = NostrProtocol.parseThreadReference(from: event.tags)
        let powDifficulty = NostrProtocol.validatedPoWDifficulty(idHex: event.id, tags: event.tags)
        let attachments = NostrProtocol.parseMediaAttachments(from: event.tags)

        let note = Note(
            id: normalizedID,
            pubkey: event.pubkey.lowercased(),
            content: event.content,
            createdAt: ts,
            nickname: nick,
            geohash: matchedGeohash,
            expiresAt: expiresAt,
            isUrgent: urgent,
            rootEventID: threadRef?.rootEventID,
            replyToEventID: threadRef?.replyEventID,
            powDifficulty: powDifficulty,
            isTeleported: teleported,
            attachments: attachments
        )

        if let rootID = note.rootEventID {
            insertReplySorted(note, forRootID: rootID)
        } else {
            insertNoteSorted(note)
            enforceMemoryCap()
        }
        if state != .ready {
            state = .ready
        }
        return matchedGeohash
    }

    @discardableResult
    private func ingestReaction(_ event: NostrEvent, validGeohashes: Set<String>) -> String? {
        let normalizedEventID = event.id.lowercased()
        guard !reactionEventIDs.contains(normalizedEventID) else { return nil }

        // Require the reaction to belong to one of our 9 subscribed cells.
        guard let matchedGeohash = event.tags.first(where: { tag in
            tag.count >= 2 && tag[0].lowercased() == "g" && validGeohashes.contains(tag[1].lowercased())
        })?[1].lowercased() else {
            return nil
        }

        guard let parsed = NostrProtocol.parseReactionTarget(from: event) else { return nil }
        recordReactionEventID(normalizedEventID)

        let authorPubkey = event.pubkey.lowercased()
        applyReaction(
            targetID: parsed.targetEventID,
            emoji: parsed.emoji,
            actorPubkey: authorPubkey,
            eventID: normalizedEventID
        )
        return matchedGeohash
    }

    private func isOwnPubkey(_ pubkeyHex: String) -> Bool {
        let lower = pubkeyHex.lowercased()
        if let ownPubkey, lower == ownPubkey.lowercased() { return true }
        if let ownPublicPubkey, lower == ownPublicPubkey.lowercased() { return true }
        return false
    }

    private func applyReaction(targetID: String, emoji: String, actorPubkey: String, eventID: String) {
        let normalizedTarget = targetID.lowercased()
        var byEmoji = reactionActorsByTarget[normalizedTarget, default: [:]]
        var actors = byEmoji[emoji, default: []]
        let inserted = actors.insert(actorPubkey).inserted
        byEmoji[emoji] = actors
        reactionActorsByTarget[normalizedTarget] = byEmoji

        if inserted {
            var order = reactionEmojiOrderByTarget[normalizedTarget, default: []]
            if !order.contains(emoji) {
                order.append(emoji)
                reactionEmojiOrderByTarget[normalizedTarget] = order
            }
        }
        if isOwnPubkey(actorPubkey) {
            ownReactionEventIDs[ReactionTargetKey(targetID: normalizedTarget, emoji: emoji)] = eventID
        }
        rebuildAggregatedReactions(forTargetID: normalizedTarget)
    }

    private func rebuildAggregatedReactions(forTargetID targetID: String) {
        guard let byEmoji = reactionActorsByTarget[targetID], !byEmoji.isEmpty else {
            reactionsByNoteID.removeValue(forKey: targetID)
            return
        }
        let order = reactionEmojiOrderByTarget[targetID] ?? Array(byEmoji.keys)
        let aggregated: [AggregatedReaction] = order.compactMap { emoji in
            guard let actors = byEmoji[emoji], !actors.isEmpty else { return nil }
            let includesMe = actors.contains { isOwnPubkey($0) }
            return AggregatedReaction(
                emoji: emoji,
                count: actors.count,
                includesCurrentUser: includesMe
            )
        }
        if aggregated.isEmpty {
            reactionsByNoteID.removeValue(forKey: targetID)
        } else {
            reactionsByNoteID[targetID] = aggregated
        }
    }

    /// Inserts a top-level note in descending `createdAt` order via binary search.
    private func insertNoteSorted(_ note: Note) {
        var low = 0
        var high = notes.count
        while low < high {
            let mid = (low + high) / 2
            if notes[mid].createdAt >= note.createdAt {
                low = mid + 1
            } else {
                high = mid
            }
        }
        notes.insert(note, at: low)
    }

    /// Inserts a NIP-10 reply in ascending `createdAt` order (oldest -> newest).
    private func insertReplySorted(_ reply: Note, forRootID rootID: String) {
        var thread = repliesByRootID[rootID] ?? []
        var low = 0
        var high = thread.count
        while low < high {
            let mid = (low + high) / 2
            if thread[mid].createdAt <= reply.createdAt {
                low = mid + 1
            } else {
                high = mid
            }
        }
        thread.insert(reply, at: low)
        if thread.count > maxRepliesPerThread {
            thread = Array(thread.suffix(maxRepliesPerThread))
        }
        repliesByRootID[rootID] = thread
    }

    private func recordNoteID(_ id: String) {
        noteIDs.insert(id)
        if noteIDs.count > maxNotesInMemory * 4 {
            // Keep all currently visible note & reply IDs so active items never duplicate.
            var liveIDs = Set(notes.map(\.id))
            for thread in repliesByRootID.values {
                liveIDs.formUnion(thread.map(\.id))
            }
            noteIDs = liveIDs.union([id])
        }
    }

    private func recordReactionEventID(_ id: String) {
        reactionEventIDs.insert(id)
        if reactionEventIDs.count > maxTrackedReactionEvents {
            let ownIDs = Set(ownReactionEventIDs.values)
            reactionEventIDs = ownIDs.union([id])
        }
    }

    /// While `.connecting`, poll for a live target relay and re-subscribe as
    /// soon as one appears (fresh REQ, fresh EOSE tracking). The poll dies
    /// with the state: any subscribe/cancel invalidates it.
    private func scheduleConnectivityRetry(relays: [String]) {
        connectivityRetryTimer?.invalidate()
        let retryTimer = Timer.scheduledTimer(
            withTimeInterval: TransportConfig.uiGeoNotesConnectivityRetrySeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.retryIfRelaysAvailable(relays: relays)
            }
        }
        retryTimer.tolerance = min(2.0, TransportConfig.uiGeoNotesConnectivityRetrySeconds * 0.25)
        connectivityRetryTimer = retryTimer
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

    // MARK: - Publishing (Posts, NIP-10 Replies, NIP-25 Reactions)

    /// Send a location note synchronously for the current geohash using the
    /// per-geohash identity (preserved for NoticesView and existing tests).
    func send(
        content: String,
        nickname: String,
        expiresAt: Date? = nil,
        urgent: Bool = false,
        teleported: Bool = false,
        replyTo: NostrProtocol.ThreadReference? = nil
    ) {
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
            ownPubkey = id.publicKeyHex.lowercased()
            let event = try NostrProtocol.createGeohashTextNote(
                content: trimmed,
                geohash: geohash,
                senderIdentity: id,
                nickname: nickname,
                expiresAt: expiresAt,
                urgent: urgent,
                replyTo: replyTo,
                teleported: teleported,
                createdAt: dependencies.now()
            )
            publishAndEcho(
                event: event,
                relays: relays,
                content: trimmed,
                nickname: nickname,
                expiresAt: expiresAt,
                urgent: urgent,
                teleported: teleported,
                replyTo: replyTo
            )
        } catch {
            SecureLogger.error("LocationNotesManager: failed to send note: \(error)", category: .session)
            errorMessage = Strings.failedToSend(error.localizedDescription)
        }
    }

    /// Signs synchronously and publishes a kind-1 Place Feed post or NIP-10
    /// reply. Supports dual-posture identity: `.placePersona` (unlinkable
    /// per-geohash key, default) or `.publicHandle` (persistent primary key,
    /// published to both geo relays and default relays), with automatic BLE
    /// gateway uplink when internet relays are unreachable.
    @discardableResult
    func sendFeedPost(
        content: String,
        nickname: String,
        expiresAt: Date? = nil,
        urgent: Bool = false,
        teleported: Bool = false,
        replyTo: NostrProtocol.ThreadReference? = nil,
        identityMode: PostingIdentityMode = .placePersona,
        attachments: [NostrProtocol.MediaAttachment] = []
    ) -> Bool {
        guard let trimmed = content.trimmedOrNilIfEmpty else { return false }
        let relays = dependencies.relayLookup(geohash, TransportConfig.nostrGeoRelayCount)

        let identity: NostrIdentity
        do {
            switch identityMode {
            case .placePersona:
                identity = try dependencies.deriveIdentity(geohash)
                ownPubkey = identity.publicKeyHex.lowercased()
            case .publicHandle:
                guard let persistent = try dependencies.publicIdentity() else {
                    throw NostrError.cryptographicFailure
                }
                identity = persistent
                ownPublicPubkey = persistent.publicKeyHex.lowercased()
            }
        } catch {
            SecureLogger.error("LocationNotesManager: failed to derive identity: \(error)", category: .session)
            errorMessage = Strings.failedToSend(error.localizedDescription)
            return false
        }

        let mirrorToDefaultRelays = (identityMode == .publicHandle)
        isSending = true
        defer { isSending = false }

        do {
            let event = try NostrProtocol.createGeohashTextNote(
                content: trimmed,
                geohash: geohash,
                senderIdentity: identity,
                nickname: nickname,
                expiresAt: expiresAt,
                urgent: urgent,
                replyTo: replyTo,
                teleported: teleported,
                attachments: attachments,
                createdAt: dependencies.now()
            )
            let uplinked = !dependencies.anyRelayConnected(relays)
                && dependencies.uplinkViaMesh(event, geohash)
            guard !relays.isEmpty || uplinked else {
                state = .noRelays
                errorMessage = Strings.noRelays
                return false
            }
            if mirrorToDefaultRelays {
                dependencies.sendToDefaultRelays(event)
            }
            publishAndEcho(
                event: event,
                relays: relays,
                content: trimmed,
                nickname: nickname,
                expiresAt: expiresAt,
                urgent: urgent,
                teleported: teleported,
                replyTo: replyTo,
                attachments: attachments
            )
            return true
        } catch {
            SecureLogger.error("LocationNotesManager: failed to send feed note: \(error)", category: .session)
            errorMessage = Strings.failedToSend(error.localizedDescription)
            return false
        }
    }

    private func publishAndEcho(
        event: NostrEvent,
        relays: [String],
        content: String,
        nickname: String,
        expiresAt: Date?,
        urgent: Bool,
        teleported: Bool,
        replyTo: NostrProtocol.ThreadReference?,
        attachments: [NostrProtocol.MediaAttachment] = []
    ) {
        if !relays.isEmpty {
            dependencies.sendEvent(event, relays)
        }
        let normalizedID = event.id.lowercased()
        let powDifficulty = NostrProtocol.validatedPoWDifficulty(idHex: event.id, tags: event.tags)
        let echo = Note(
            id: normalizedID,
            pubkey: event.pubkey.lowercased(),
            content: content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
            nickname: nickname,
            geohash: geohash,
            expiresAt: expiresAt,
            isUrgent: urgent,
            rootEventID: replyTo?.rootEventID,
            replyToEventID: replyTo?.replyEventID,
            powDifficulty: powDifficulty,
            isTeleported: teleported,
            attachments: attachments
        )
        recordNoteID(normalizedID)
        if let rootID = echo.rootEventID {
            insertReplySorted(echo, forRootID: rootID)
        } else {
            insertNoteSorted(echo)
            enforceMemoryCap()
        }
        state = .ready
        errorMessage = nil
    }

    /// Toggles a NIP-25 emoji reaction on a note. Adding publishes a kind-7
    /// reaction; removing sends a NIP-09 deletion of our own kind-7 event.
    @discardableResult
    func toggleReaction(emoji: String, on note: Note) -> Bool {
        guard let normalizedEmoji = NostrProtocol.normalizeReactionContent(emoji) else {
            return false
        }
        let relays = dependencies.relayLookup(geohash, TransportConfig.nostrGeoRelayCount)
        guard !relays.isEmpty else {
            state = .noRelays
            errorMessage = Strings.noRelays
            return false
        }
        do {
            let identity = try dependencies.deriveIdentity(geohash)
            let ownHex = identity.publicKeyHex.lowercased()
            ownPubkey = ownHex
            let targetID = note.id.lowercased()
            let key = ReactionTargetKey(targetID: targetID, emoji: normalizedEmoji)

            var byEmoji = reactionActorsByTarget[targetID, default: [:]]
            var actors = byEmoji[normalizedEmoji, default: []]

            if actors.contains(ownHex) {
                // Toggle off: remove locally and emit NIP-09 deletion when we know the reaction event ID.
                actors.remove(ownHex)
                if actors.isEmpty {
                    byEmoji.removeValue(forKey: normalizedEmoji)
                } else {
                    byEmoji[normalizedEmoji] = actors
                }
                if byEmoji.isEmpty {
                    reactionActorsByTarget.removeValue(forKey: targetID)
                } else {
                    reactionActorsByTarget[targetID] = byEmoji
                }
                rebuildAggregatedReactions(forTargetID: targetID)

                if let reactionEventID = ownReactionEventIDs.removeValue(forKey: key) {
                    let deletion = try NostrProtocol.createDeleteEvent(
                        ofEventID: reactionEventID,
                        senderIdentity: identity
                    )
                    dependencies.sendEvent(deletion, relays)
                }
                return true
            } else {
                let reactionEvent = try NostrProtocol.createGeohashReactionEvent(
                    emoji: normalizedEmoji,
                    targetEventID: targetID,
                    targetAuthorPubkey: note.pubkey,
                    geohash: geohash,
                    senderIdentity: identity,
                    createdAt: dependencies.now()
                )
                dependencies.sendEvent(reactionEvent, relays)
                let reactionID = reactionEvent.id.lowercased()
                recordReactionEventID(reactionID)
                applyReaction(
                    targetID: targetID,
                    emoji: normalizedEmoji,
                    actorPubkey: ownHex,
                    eventID: reactionID
                )
                return true
            }
        } catch {
            SecureLogger.error("LocationNotesManager: failed to toggle reaction: \(error)", category: .session)
            errorMessage = Strings.failedToSend(error.localizedDescription)
            return false
        }
    }

    /// Whether the note was published by either this device's per-geohash
    /// identity or its persistent public handle (and can be deleted with NIP-09).
    func isOwnNote(_ note: Note) -> Bool {
        isOwnPubkey(note.pubkey)
    }

    /// Requests NIP-09 deletion of one of our own notes (top-level or reply) and removes it locally.
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
            let usedPublicHandle = ownPublicPubkey.map { note.pubkey.lowercased() == $0.lowercased() } ?? false
            let identity: NostrIdentity
            if usedPublicHandle, let persistent = try dependencies.publicIdentity() {
                identity = persistent
            } else {
                identity = try dependencies.deriveIdentity(geohash)
            }
            let deletion = try NostrProtocol.createDeleteEvent(ofEventID: note.id, senderIdentity: identity)
            dependencies.sendEvent(deletion, relays)
            if usedPublicHandle {
                dependencies.sendToDefaultRelays(deletion)
            }
            // Keep the id in noteIDs so a relay replay can't resurrect it.
            if let rootID = note.rootEventID {
                var thread = repliesByRootID[rootID] ?? []
                thread.removeAll { $0.id == note.id }
                if thread.isEmpty {
                    repliesByRootID.removeValue(forKey: rootID)
                } else {
                    repliesByRootID[rootID] = thread
                }
            } else {
                notes.removeAll { $0.id == note.id }
            }
            return true
        } catch {
            SecureLogger.error("LocationNotesManager: failed to delete note: \(error)", category: .session)
            return false
        }
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

    /// Panic-wipe hook: cancel relay subscriptions, stop timers, and erase
    /// in-memory notes, threads, reactions, and key state.
    func resetForPanic() {
        isSending = false
        cancel()
        expiryPruneTimer?.invalidate()
        expiryPruneTimer = nil
        directoryUpdateCancellable = nil
        notes.removeAll(keepingCapacity: false)
        repliesByRootID.removeAll(keepingCapacity: false)
        reactionsByNoteID.removeAll(keepingCapacity: false)
        noteIDs.removeAll(keepingCapacity: false)
        reactionEventIDs.removeAll(keepingCapacity: false)
        reactionActorsByTarget.removeAll(keepingCapacity: false)
        reactionEmojiOrderByTarget.removeAll(keepingCapacity: false)
        ownReactionEventIDs.removeAll(keepingCapacity: false)
        ownPubkey = nil
        ownPublicPubkey = nil
        initialLoadComplete = false
    }
}
