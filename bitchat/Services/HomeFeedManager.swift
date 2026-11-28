//
// HomeFeedManager.swift
// bitchat
//
// Aggregates a Tor-friendly merged Home Feed across:
// 1. Saved Places (bookmarked geohashes, pooled via LocationNotesPool so open
//    Place rooms and Home Feed share the same subscriptions).
// 2. Following (a single bounded `authors` kind-1 REQ on default relays,
//    avoiding heavy NIP-65 multi-relay fan-out over Tor).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import Foundation

struct HomeFeedDependencies {
    typealias AcquirePlaceManager = @MainActor (_ geohash: String) -> LocationNotesManager
    typealias ReleasePlaceManager = @MainActor (_ manager: LocationNotesManager?) -> Void
    typealias SubscribeDefaultRelays = @MainActor (_ filter: NostrFilter, _ id: String, _ handler: @escaping (NostrEvent) -> Void, _ onEOSE: (() -> Void)?) -> Void
    typealias Unsubscribe = @MainActor (_ id: String) -> Void
    typealias SendDefaultRelays = @MainActor (_ event: NostrEvent) -> Void

    var acquirePlaceManager: AcquirePlaceManager
    var releasePlaceManager: ReleasePlaceManager
    var subscribeDefaultRelays: SubscribeDefaultRelays
    var unsubscribe: Unsubscribe
    var sendDefaultRelays: SendDefaultRelays
    var publicIdentity: () throws -> NostrIdentity?
    var ensureProfiles: @MainActor (_ pubkeys: [String]) -> Void
    var now: () -> Date

    static let live = HomeFeedDependencies(
        acquirePlaceManager: { LocationNotesPool.shared.acquire($0) },
        releasePlaceManager: { LocationNotesPool.shared.release($0) },
        subscribeDefaultRelays: { filter, id, handler, onEOSE in
            NostrRelayManager.shared.subscribe(
                filter: filter,
                id: id,
                relayUrls: nil,
                handler: handler,
                onEOSE: onEOSE
            )
        },
        unsubscribe: { NostrRelayManager.shared.unsubscribe(id: $0) },
        sendDefaultRelays: { NostrRelayManager.shared.sendEvent($0) },
        publicIdentity: { try NostrIdentityBridge.shared.getCurrentNostrIdentity() },
        ensureProfiles: { NostrProfileStore.shared.ensureProfiles(for: $0) },
        now: Date.init
    )
}

/// One deduplicated post in the merged Saved Places + Following Home Feed.
struct HomeFeedItem: Identifiable, Equatable {
    let note: LocationNotesManager.Note
    /// Non-nil when this post belongs to (or was seen in) a bookmarked place.
    let savedPlaceGeohash: String?
    /// True when the author is in the user's private follow list or favorites.
    let isFromFollowedAuthor: Bool

    var id: String { note.id }

    var noticeItem: NoticeItem {
        NoticeItem(note: note)
    }
}

@MainActor
final class HomeFeedManager: ObservableObject {
    static let shared = HomeFeedManager()

    /// Cap concurrently subscribed Saved Places to keep Tor circuit/socket load bounded.
    static let maxSubscribedPlaces = 12
    private static let maxFollowingNotesInMemory = 300

    @Published private(set) var items: [HomeFeedItem] = []
    @Published private(set) var isLoadingFollowing: Bool = false
    @Published private(set) var isSending: Bool = false
    @Published private(set) var errorMessage: String?

    private let dependencies: HomeFeedDependencies
    private var placeManagers: [String: LocationNotesManager] = [:]
    private var placeCancellables: [String: AnyCancellable] = [:]
    private var followingNotes: [LocationNotesManager.Note] = []
    private var followingRepliesByRootID: [String: [LocationNotesManager.Note]] = [:]
    private var followingNoteIDs = Set<String>()
    private var followingSubscriptionID: String?
    private var subscribedBookmarks: [String] = []
    private var subscribedFollows: [String] = []
    private var expiryPruneTimer: Timer?
    private var isActive = false

    init(dependencies: HomeFeedDependencies = .live) {
        self.dependencies = dependencies
    }

    deinit {
        expiryPruneTimer?.invalidate()
        if let sub = followingSubscriptionID {
            let unsubscribe = dependencies.unsubscribe
            Task { @MainActor in
                unsubscribe(sub)
            }
        }
        let managers = Array(placeManagers.values)
        let release = dependencies.releasePlaceManager
        if !managers.isEmpty {
            Task { @MainActor in
                for manager in managers {
                    release(manager)
                }
            }
        }
    }

    // MARK: - Lifecycle

    func activate(bookmarks: [String], followedPubkeys: [String]) {
        isActive = true
        startExpiryPruneTimer()
        updateSources(bookmarks: bookmarks, followedPubkeys: followedPubkeys)
    }

    func updateSources(bookmarks: [String], followedPubkeys: [String]) {
        guard isActive else { return }

        let normalizedBookmarks = Array(
            NSOrderedSet(array: bookmarks.map { $0.lowercased() }.filter { Geohash.isValidGeohash($0) })
                .compactMap { $0 as? String }
                .prefix(Self.maxSubscribedPlaces)
        )
        let normalizedFollows = Array(
            NSOrderedSet(array: followedPubkeys.compactMap { NostrProtocol.normalizePubkeyHex($0) })
                .compactMap { $0 as? String }
        )

        if normalizedBookmarks != subscribedBookmarks {
            reconcilePlaceManagers(targetBookmarks: normalizedBookmarks)
            subscribedBookmarks = normalizedBookmarks
        }

        if normalizedFollows != subscribedFollows {
            subscribedFollows = normalizedFollows
            resubscribeFollowing(pubkeys: normalizedFollows)
        }

        rebuildItems()
    }

    func deactivate() {
        isActive = false
        stopExpiryPruneTimer()
        releaseAllPlaceManagers()
        closeFollowingSubscription()
        subscribedBookmarks = []
        subscribedFollows = []
    }

    func refresh() {
        for manager in placeManagers.values {
            manager.refresh()
        }
        resubscribeFollowing(pubkeys: subscribedFollows)
        rebuildItems()
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Queries

    func manager(forGeohash geohash: String) -> LocationNotesManager? {
        placeManagers[geohash.lowercased()]
    }

    func replyCount(for item: HomeFeedItem) -> Int {
        var ids = Set<String>()
        if let gh = item.savedPlaceGeohash, let manager = placeManagers[gh] {
            for r in manager.replies(forRootID: item.id) { ids.insert(r.id) }
        }
        for r in followingRepliesByRootID[item.id] ?? [] {
            ids.insert(r.id)
        }
        return ids.count
    }

    func reactions(for item: HomeFeedItem) -> [AggregatedReaction] {
        guard let gh = item.savedPlaceGeohash, let manager = placeManagers[gh] else {
            return []
        }
        return manager.reactions(forNoteID: item.id)
    }

    func totalReactionCount(for item: HomeFeedItem) -> Int {
        reactions(for: item).reduce(0) { $0 + $1.count }
    }

    func isOwn(_ item: HomeFeedItem) -> Bool {
        if let gh = item.savedPlaceGeohash,
           let manager = placeManagers[gh],
           manager.isOwnNote(item.note) {
            return true
        }
        if let ownPubkey = (try? dependencies.publicIdentity())?.publicKeyHex.lowercased(),
           item.note.pubkey.lowercased() == ownPubkey {
            return true
        }
        return false
    }

    func filteredItems(
        scope: HomeFeedScope,
        sort: PlaceFeedSort,
        filter: PlaceFeedFilter,
        query: String = ""
    ) -> [HomeFeedItem] {
        let scoped = items.filter { item in
            switch scope {
            case .all:
                return true
            case .savedPlaces:
                return item.savedPlaceGeohash != nil
            case .following:
                return item.isFromFollowedAuthor
            }
        }
        let lookup = Dictionary(uniqueKeysWithValues: scoped.map { ($0.id, $0) })
        let organizedNotices = PlaceFeedOrganizer.organize(
            items: scoped.map(\.noticeItem),
            sort: sort,
            filter: filter,
            query: query,
            replyCount: { id in
                guard let item = lookup[id] else { return 0 }
                return self.replyCount(for: item)
            },
            reactionCount: { id in
                guard let item = lookup[id] else { return 0 }
                return self.totalReactionCount(for: item)
            },
            isVouched: { notice in
                guard let note = notice.nostrNote else { return false }
                return LocalWebOfTrustService.shared.isTrustedAuthor(note.pubkey)
            }
        )
        return organizedNotices.compactMap { lookup[$0.id] }
    }

    // MARK: - Publishing & Interactions

    /// Publishes a global (non-geohash) kind-1 post signed synchronously with
    /// the user's persistent public handle.
    @discardableResult
    func sendGlobalPost(
        content: String,
        nickname: String,
        expiresAt: Date? = nil
    ) -> Bool {
        guard let trimmed = content.trimmedOrNilIfEmpty else { return false }
        guard let identity = try? dependencies.publicIdentity() else {
            errorMessage = String(localized: "home_feed.error.handle_required", defaultValue: "Enable your Public Handle to post globally.", comment: "Shown when attempting a global post without a persistent handle")
            return false
        }

        isSending = true
        defer { isSending = false }
        do {
            let event = try NostrProtocol.createPublicTextNote(
                content: trimmed,
                senderIdentity: identity,
                nickname: nickname,
                expiresAt: expiresAt,
                replyTo: nil,
                createdAt: dependencies.now()
            )
            dependencies.sendDefaultRelays(event)
            ingestFollowingEvent(event)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func toggleReaction(emoji: String, on item: HomeFeedItem) {
        if let gh = item.savedPlaceGeohash, let manager = placeManagers[gh] {
            manager.toggleReaction(emoji: emoji, on: item.note)
        }
    }

    func delete(_ item: HomeFeedItem) {
        if let gh = item.savedPlaceGeohash,
           let manager = placeManagers[gh],
           manager.isOwnNote(item.note) {
            manager.delete(note: item.note)
        }
        if let identity = try? dependencies.publicIdentity(),
           item.note.pubkey.lowercased() == identity.publicKeyHex.lowercased() {
            if let deletion = try? NostrProtocol.createDeleteEvent(ofEventID: item.id, senderIdentity: identity) {
                dependencies.sendDefaultRelays(deletion)
            }
            followingNotes.removeAll { $0.id == item.id }
            rebuildItems()
        }
    }

    /// Panic-wipe hook: tears down all subscriptions, releases pooled managers,
    /// and erases cached feed items.
    func resetForPanic() {
        isSending = false
        isActive = false
        stopExpiryPruneTimer()
        releaseAllPlaceManagers()
        closeFollowingSubscription()
        followingNotes.removeAll(keepingCapacity: false)
        followingRepliesByRootID.removeAll(keepingCapacity: false)
        followingNoteIDs.removeAll(keepingCapacity: false)
        subscribedBookmarks = []
        subscribedFollows = []
        items.removeAll(keepingCapacity: false)
        isLoadingFollowing = false
        errorMessage = nil
    }

    // MARK: - Internal Subscription Wiring

    private func reconcilePlaceManagers(targetBookmarks: [String]) {
        let targetSet = Set(targetBookmarks)
        for existingKey in Array(placeManagers.keys) where !targetSet.contains(existingKey) {
            placeCancellables.removeValue(forKey: existingKey)
            let manager = placeManagers.removeValue(forKey: existingKey)
            dependencies.releasePlaceManager(manager)
        }
        for gh in targetBookmarks where placeManagers[gh] == nil {
            let manager = dependencies.acquirePlaceManager(gh)
            placeManagers[gh] = manager
            placeCancellables[gh] = Publishers.Merge3(
                manager.$notes.map { _ in () },
                manager.$repliesByRootID.map { _ in () },
                manager.$reactionsByNoteID.map { _ in () }
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildItems()
            }
        }
    }

    private func releaseAllPlaceManagers() {
        placeCancellables.removeAll()
        let managers = Array(placeManagers.values)
        placeManagers.removeAll()
        for manager in managers {
            dependencies.releasePlaceManager(manager)
        }
    }

    private func closeFollowingSubscription() {
        if let sub = followingSubscriptionID {
            dependencies.unsubscribe(sub)
            followingSubscriptionID = nil
        }
        isLoadingFollowing = false
    }

    private func resubscribeFollowing(pubkeys: [String]) {
        closeFollowingSubscription()
        followingNotes.removeAll()
        followingRepliesByRootID.removeAll()
        followingNoteIDs.removeAll()

        var authors = pubkeys
        if let ownHex = (try? dependencies.publicIdentity())?.publicKeyHex.lowercased(),
           NostrProfileStore.shared.isPublicHandleEnabled,
           !authors.contains(ownHex) {
            authors.append(ownHex)
        }
        guard !authors.isEmpty else { return }

        dependencies.ensureProfiles(authors)
        isLoadingFollowing = true
        let subID = "homefeed-following-\(UUID().uuidString.prefix(8))"
        followingSubscriptionID = subID
        let filter = NostrFilter.authorNotes(authors, since: nil, limit: 150)

        dependencies.subscribeDefaultRelays(filter, subID, { [weak self] event in
            self?.ingestFollowingEvent(event)
        }, { [weak self] in
            self?.isLoadingFollowing = false
        })
    }

    private func ingestFollowingEvent(_ event: NostrEvent) {
        guard event.kind == NostrProtocol.EventKind.textNote.rawValue else { return }
        let normalizedID = event.id.lowercased()
        guard !followingNoteIDs.contains(normalizedID) else { return }

        var geohash = ""
        var nick: String?
        var expiresAt: Date?
        var urgent = false
        var teleported = false
        for tag in event.tags where tag.count >= 2 {
            switch tag[0].lowercased() {
            case "g":
                if geohash.isEmpty { geohash = tag[1].lowercased() }
            case "n":
                if nick == nil { nick = tag[1] }
            case "expiration":
                if expiresAt == nil, let secs = TimeInterval(tag[1]) {
                    expiresAt = Date(timeIntervalSince1970: secs)
                }
            case "t":
                let val = tag[1].lowercased()
                if val == "urgent" { urgent = true }
                else if val == "teleport" { teleported = true }
            default:
                break
            }
        }
        let now = dependencies.now()
        if let expiresAt, expiresAt <= now { return }
        followingNoteIDs.insert(normalizedID)

        let latestAccepted = now.addingTimeInterval(TimeInterval(BoardStore.Limits.clockSkewMs) / 1000)
        let ts = min(Date(timeIntervalSince1970: TimeInterval(event.created_at)), latestAccepted)
        let threadRef = NostrProtocol.parseThreadReference(from: event.tags)
        let powDifficulty = NostrProtocol.validatedPoWDifficulty(idHex: event.id, tags: event.tags)
        let attachments = NostrProtocol.parseMediaAttachments(from: event.tags)

        let note = LocationNotesManager.Note(
            id: normalizedID,
            pubkey: event.pubkey.lowercased(),
            content: event.content,
            createdAt: ts,
            nickname: nick,
            geohash: geohash,
            expiresAt: expiresAt,
            isUrgent: urgent,
            rootEventID: threadRef?.rootEventID,
            replyToEventID: threadRef?.replyEventID,
            powDifficulty: powDifficulty,
            isTeleported: teleported,
            attachments: attachments
        )

        if let rootID = note.rootEventID {
            var thread = followingRepliesByRootID[rootID] ?? []
            thread.append(note)
            thread.sort { $0.createdAt < $1.createdAt }
            followingRepliesByRootID[rootID] = thread
        } else {
            followingNotes.append(note)
            followingNotes.sort { $0.createdAt > $1.createdAt }
            if followingNotes.count > Self.maxFollowingNotesInMemory {
                followingNotes = Array(followingNotes.prefix(Self.maxFollowingNotesInMemory))
            }
        }
        rebuildItems()
    }

    /// Drops NIP-40 expired entries from the Following cache and triggers a
    /// feed rebuild so expired followed posts cannot linger or resurrect
    /// expired Saved Place posts.
    func pruneExpiredFollowingNotes() {
        let now = dependencies.now()
        var removedIDs: [String] = []
        followingNotes.removeAll { note in
            if let expiresAt = note.expiresAt, expiresAt <= now {
                removedIDs.append(note.id)
                return true
            }
            return false
        }
        for (rootID, replies) in followingRepliesByRootID {
            let kept = replies.filter { reply in
                if let expiresAt = reply.expiresAt, expiresAt <= now {
                    removedIDs.append(reply.id)
                    return false
                }
                return true
            }
            if kept.isEmpty {
                followingRepliesByRootID.removeValue(forKey: rootID)
            } else if kept.count != replies.count {
                followingRepliesByRootID[rootID] = kept
            }
        }
        if !removedIDs.isEmpty {
            for id in removedIDs {
                followingNoteIDs.remove(id)
            }
            rebuildItems()
        }
    }

    private func startExpiryPruneTimer() {
        guard expiryPruneTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pruneExpiredFollowingNotes()
            }
        }
        timer.tolerance = 10.0
        expiryPruneTimer = timer
    }

    private func stopExpiryPruneTimer() {
        expiryPruneTimer?.invalidate()
        expiryPruneTimer = nil
    }

    private func rebuildItems() {
        let now = dependencies.now()
        // Drop any expired following entries before merging so an expired
        // saved-place post cannot be resurrected from the Following cache.
        var expiredFollowingIDs: [String] = []
        followingNotes.removeAll { note in
            if let expiresAt = note.expiresAt, expiresAt <= now {
                expiredFollowingIDs.append(note.id)
                return true
            }
            return false
        }
        for id in expiredFollowingIDs {
            followingNoteIDs.remove(id)
        }

        let followedSet = Set(subscribedFollows)
        let ownPublicHex = (try? dependencies.publicIdentity())?.publicKeyHex.lowercased()
        var mergedByID: [String: HomeFeedItem] = [:]
        var authorPubkeys = Set<String>()

        // 1. Saved Places notes
        for (bookmarkGeohash, manager) in placeManagers {
            for note in manager.notes {
                if let expiresAt = note.expiresAt, expiresAt <= now { continue }
                let pubkey = note.pubkey.lowercased()
                authorPubkeys.insert(pubkey)
                let isFollowed = followedSet.contains(pubkey) || (ownPublicHex == pubkey)
                if let existing = mergedByID[note.id] {
                    mergedByID[note.id] = HomeFeedItem(
                        note: existing.note,
                        savedPlaceGeohash: existing.savedPlaceGeohash ?? bookmarkGeohash,
                        isFromFollowedAuthor: existing.isFromFollowedAuthor || isFollowed
                    )
                } else {
                    mergedByID[note.id] = HomeFeedItem(
                        note: note,
                        savedPlaceGeohash: bookmarkGeohash,
                        isFromFollowedAuthor: isFollowed
                    )
                }
            }
        }

        // 2. Following notes (merge into existing place entry when same event ID)
        for note in followingNotes {
            let pubkey = note.pubkey.lowercased()
            authorPubkeys.insert(pubkey)
            if let existing = mergedByID[note.id] {
                mergedByID[note.id] = HomeFeedItem(
                    note: existing.note,
                    savedPlaceGeohash: existing.savedPlaceGeohash,
                    isFromFollowedAuthor: true
                )
            } else {
                let matchedBookmark = !note.geohash.isEmpty && placeManagers[note.geohash] != nil
                    ? note.geohash
                    : nil
                mergedByID[note.id] = HomeFeedItem(
                    note: note,
                    savedPlaceGeohash: matchedBookmark,
                    isFromFollowedAuthor: true
                )
            }
        }

        if !authorPubkeys.isEmpty {
            dependencies.ensureProfiles(Array(authorPubkeys))
        }

        items = mergedByID.values.sorted { lhs, rhs in
            if lhs.note.isUrgent != rhs.note.isUrgent { return lhs.note.isUrgent }
            if lhs.note.createdAt != rhs.note.createdAt { return lhs.note.createdAt > rhs.note.createdAt }
            return lhs.id < rhs.id
        }
    }
}
