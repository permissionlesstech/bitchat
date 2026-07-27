//
// BoardStore.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import Combine
import Foundation

/// Outcome of feeding a board packet into the store, so the transport can
/// decide whether the packet is still worth relaying.
enum BoardIngestResult {
    /// New post or tombstone accepted (or a quota rejected it locally while
    /// it remains valid for other devices).
    case accepted
    /// Already known; nothing changed.
    case duplicate
    /// Invalid, expired, or deleted; do not relay.
    case rejected
}

/// Persistent storage for bulletin-board posts and their tombstones.
///
/// Posts are signed public notices designed to outlive chat: they stay on
/// disk until their author-chosen expiry (max 7 days) and re-enter gossip
/// sync after a restart. Tombstones are retained until the deleted post's
/// original expiry so the delete keeps outrunning stale copies of the post.
///
/// The on-disk format is the raw signed packets themselves (like
/// `GossipMessageArchive`); state is rebuilt by re-verifying and re-ingesting
/// them on launch. Wiped on panic.
final class BoardStore {
    enum Limits {
        static let maxPosts = 200
        static let maxPostsPerAuthor = 5
        /// Retention for a tombstone whose post we never saw: we cannot know
        /// the original expiry, so cap at the max post lifetime.
        static let orphanTombstoneLifetimeMs = BoardWireConstants.maxLifetimeMs
        /// Orphan tombstones name posts nobody here has seen, so their volume
        /// is entirely sender-controlled; cap them like posts.
        static let maxOrphanTombstones = 100
        static let maxOrphanTombstonesPerAuthor = 5
        /// Allowance for clock skew between peers when judging received
        /// timestamps against local time.
        static let clockSkewMs: UInt64 = 60 * 60 * 1000
    }

    private struct StoredPost {
        let post: BoardPostPacket
        let packet: BitchatPacket
        let rawPacket: Data
    }

    private struct StoredTombstone {
        let tombstone: BoardTombstonePacket
        let packet: BitchatPacket
        let rawPacket: Data
        let retainUntil: UInt64
        /// True when no matching post was known at ingest time; only these
        /// count against the orphan caps.
        let isOrphan: Bool
    }

    /// On-disk entry: the raw signed packet, plus the retention deadline for
    /// tombstones (derived from the deleted post's original expiry, which is
    /// no longer recoverable once the post is gone).
    private struct PersistedEntry: Codable {
        let packet: Data
        let retainUntil: UInt64?
    }

    static let shared = BoardStore()

    /// Live posts, published on the main thread for the board UI.
    @Published private(set) var postsSnapshot: [BoardPostPacket] = []

    /// Fires on the main thread for each post newly accepted from the wire
    /// (radio, sync, or local echo) — not for disk restores. Drives the
    /// local new-pin chat alerts; duplicates never fire twice because the
    /// store rejects them.
    let postArrivals = PassthroughSubject<BoardPostPacket, Never>()

    /// Fires on the main thread after a panic wipe so derived state (pending
    /// alerts, unseen badges) is dropped along with the posts themselves.
    let didWipe = PassthroughSubject<Void, Never>()

    private var posts: [StoredPost] = []
    private var tombstones: [StoredTombstone] = []
    private let queue = DispatchQueue(label: "chat.bitchat.board.store")
    private let fileURL: URL?
    private let now: () -> Date

    /// - Parameter fileURL: Overrides the on-disk location (tests). Ignored
    ///   when `persistsToDisk` is false.
    init(persistsToDisk: Bool = true, fileURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.now = now
        self.fileURL = persistsToDisk ? (fileURL ?? Self.defaultFileURL()) : nil
        loadFromDisk()
    }

    // MARK: - Ingest

    /// Ingest a board packet whose payload decodes to `wire`. The caller must
    /// have verified the wire signature already (`BoardWire.verifySignature`).
    @discardableResult
    func ingest(_ wire: BoardWire, packet: BitchatPacket) -> BoardIngestResult {
        guard let rawPacket = packet.toBinaryData(padding: false) else { return .rejected }
        let nowMs = currentMs()
        return queue.sync {
            let result = ingestLocked(wire, packet: packet, rawPacket: rawPacket, nowMs: nowMs)
            if result == .accepted {
                persistLocked()
                if case .post(let post) = wire {
                    DispatchQueue.main.async { [weak self] in
                        self?.postArrivals.send(post)
                    }
                }
            }
            return result
        }
    }

    // MARK: - Reads

    /// Live posts scoped to one board (geohash, or "" for the mesh board).
    func posts(forGeohash geohash: String) -> [BoardPostPacket] {
        let nowMs = currentMs()
        return queue.sync {
            pruneExpiredLocked(nowMs: nowMs)
            return posts.map(\.post).filter { $0.geohash == geohash }
        }
    }

    /// Raw signed packets (posts and live tombstones) for gossip sync rounds.
    func syncCandidates() -> [BitchatPacket] {
        let nowMs = currentMs()
        return queue.sync {
            pruneExpiredLocked(nowMs: nowMs)
            return posts.map(\.packet) + tombstones.map(\.packet)
        }
    }

    // MARK: - Maintenance

    /// Panic wipe: drop all board data from memory and disk.
    func wipe() {
        queue.sync {
            posts.removeAll()
            tombstones.removeAll()
            if let fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            publishSnapshotLocked()
        }
        DispatchQueue.main.async { [weak self] in
            self?.didWipe.send()
        }
    }

    // MARK: - Internals (call only on `queue`)

    private func ingestLocked(
        _ wire: BoardWire,
        packet: BitchatPacket,
        rawPacket: Data,
        nowMs: UInt64,
        retainUntilOverride: UInt64? = nil
    ) -> BoardIngestResult {
        pruneExpiredLocked(nowMs: nowMs)
        switch wire {
        case .post(let post):
            return ingestPostLocked(post, packet: packet, rawPacket: rawPacket, nowMs: nowMs)
        case .tombstone(let tombstone):
            return ingestTombstoneLocked(tombstone, packet: packet, rawPacket: rawPacket, nowMs: nowMs, retainUntilOverride: retainUntilOverride)
        }
    }

    private func ingestPostLocked(_ post: BoardPostPacket, packet: BitchatPacket, rawPacket: Data, nowMs: UInt64) -> BoardIngestResult {
        guard post.expiresAt > nowMs else { return .rejected }
        // Receive-time sanity (this is the single chokepoint for radio, sync,
        // and disk restores): the decoder only enforces the createdAt to
        // expiresAt span, so a forged future createdAt would sort ahead of
        // honest posts and hold a store slot without ever pruning.
        guard post.createdAt <= nowMs &+ Limits.clockSkewMs,
              post.expiresAt <= nowMs &+ BoardWireConstants.maxLifetimeMs &+ Limits.clockSkewMs else {
            return .rejected
        }
        if tombstones.contains(where: { $0.tombstone.postID == post.postID && $0.tombstone.authorSigningKey == post.authorSigningKey }) {
            return .rejected
        }
        guard !posts.contains(where: { $0.post.postID == post.postID }) else { return .duplicate }

        posts.append(StoredPost(post: post, packet: packet, rawPacket: rawPacket))

        // Per-author cap, then global cap; oldest posts are evicted first.
        let authorPosts = posts.filter { $0.post.authorSigningKey == post.authorSigningKey }
        if authorPosts.count > Limits.maxPostsPerAuthor {
            evictOldestLocked(from: authorPosts, keep: Limits.maxPostsPerAuthor)
        }
        if posts.count > Limits.maxPosts {
            evictOldestLocked(from: posts, keep: Limits.maxPosts)
        }
        publishSnapshotLocked()
        // Even when the new post itself was the eviction victim it stays
        // valid mesh-wide; peers with room should still receive it.
        return .accepted
    }

    private func ingestTombstoneLocked(
        _ tombstone: BoardTombstonePacket,
        packet: BitchatPacket,
        rawPacket: Data,
        nowMs: UInt64,
        retainUntilOverride: UInt64? = nil
    ) -> BoardIngestResult {
        guard !tombstones.contains(where: { $0.tombstone.postID == tombstone.postID }) else { return .duplicate }

        // Cap retention by both the claimed deletion time (so a doctored file
        // cannot pin a tombstone past any legal expiry) and the receive time:
        // deletedAt is sender-chosen, so a far-future value must not retain
        // the tombstone longer than any post still able to arrive could live.
        let maxRetain = min(
            tombstone.deletedAt &+ Limits.orphanTombstoneLifetimeMs,
            nowMs &+ Limits.orphanTombstoneLifetimeMs &+ Limits.clockSkewMs
        )
        let retainUntil: UInt64
        let isOrphan: Bool
        if let index = posts.firstIndex(where: { $0.post.postID == tombstone.postID }) {
            let target = posts[index].post
            // Only the author's key can delete: the tombstone signature was
            // already verified against its embedded key, so it suffices to
            // require that key to be the post's author key.
            guard target.authorSigningKey == tombstone.authorSigningKey else { return .rejected }
            retainUntil = target.expiresAt
            isOrphan = false
            posts.remove(at: index)
            publishSnapshotLocked()
        } else if let retainUntilOverride {
            // Restored from disk: the post is long gone, so trust the
            // retention deadline recorded when the delete was first applied.
            // Orphans were already capped when first ingested off the air.
            retainUntil = min(retainUntilOverride, maxRetain)
            isOrphan = false
        } else {
            // Post unknown (tombstone raced ahead); keep it around so the
            // post is suppressed if it arrives later.
            retainUntil = maxRetain
            isOrphan = true
        }
        guard retainUntil > nowMs else { return .rejected }
        tombstones.append(StoredTombstone(tombstone: tombstone, packet: packet, rawPacket: rawPacket, retainUntil: retainUntil, isOrphan: isOrphan))
        if isOrphan {
            enforceOrphanTombstoneCapsLocked(author: tombstone.authorSigningKey)
        }
        // Like posts, a locally evicted tombstone stays valid mesh-wide.
        return .accepted
    }

    /// Orphan tombstones reference posts we never saw, so a peer can mint
    /// unlimited valid ones for random IDs; bound them per author and
    /// globally, evicting the oldest received first (array order).
    private func enforceOrphanTombstoneCapsLocked(author: Data) {
        let authorOrphans = tombstones.filter { $0.isOrphan && $0.tombstone.authorSigningKey == author }
        if authorOrphans.count > Limits.maxOrphanTombstonesPerAuthor {
            removeTombstonesLocked(authorOrphans.prefix(authorOrphans.count - Limits.maxOrphanTombstonesPerAuthor))
        }
        let orphans = tombstones.filter(\.isOrphan)
        if orphans.count > Limits.maxOrphanTombstones {
            removeTombstonesLocked(orphans.prefix(orphans.count - Limits.maxOrphanTombstones))
        }
    }

    private func removeTombstonesLocked(_ victims: ArraySlice<StoredTombstone>) {
        guard !victims.isEmpty else { return }
        let victimIDs = Set(victims.map { $0.tombstone.postID })
        tombstones.removeAll { victimIDs.contains($0.tombstone.postID) }
    }

    private func evictOldestLocked(from candidates: [StoredPost], keep: Int) {
        let victims = candidates
            .sorted { $0.post.createdAt < $1.post.createdAt }
            .prefix(max(0, candidates.count - keep))
        guard !victims.isEmpty else { return }
        let victimIDs = Set(victims.map { $0.post.postID })
        posts.removeAll { victimIDs.contains($0.post.postID) }
    }

    private func pruneExpiredLocked(nowMs: UInt64) {
        let postsBefore = posts.count
        posts.removeAll { $0.post.expiresAt <= nowMs }
        tombstones.removeAll { $0.retainUntil <= nowMs }
        if posts.count != postsBefore {
            publishSnapshotLocked()
        }
    }

    private func publishSnapshotLocked() {
        let snapshot = posts.map(\.post)
        DispatchQueue.main.async { [weak self] in
            self?.postsSnapshot = snapshot
        }
    }

    private func currentMs() -> UInt64 {
        UInt64(max(0, now().timeIntervalSince1970) * 1000)
    }

    // MARK: - Persistence

    private func persistLocked() {
        guard let fileURL else { return }
        let payloads = posts.map { PersistedEntry(packet: $0.rawPacket, retainUntil: nil) }
            + tombstones.map { PersistedEntry(packet: $0.rawPacket, retainUntil: $0.retainUntil) }
        do {
            if payloads.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(payloads)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtection)
            #endif
            try data.write(to: fileURL, options: options)
        } catch {
            SecureLogger.error("Failed to persist board store: \(error)", category: .session)
        }
    }

    private func loadFromDisk() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let payloads = try? JSONDecoder().decode([PersistedEntry].self, from: data) else {
            return
        }
        let nowMs = currentMs()
        queue.sync {
            for entry in payloads {
                guard let packet = BitchatPacket.from(entry.packet),
                      packet.type == MessageType.boardPost.rawValue,
                      let wire = BoardWire.decode(from: packet.payload),
                      wire.verifySignature() else { continue }
                _ = ingestLocked(wire, packet: packet, rawPacket: entry.packet, nowMs: nowMs, retainUntilOverride: entry.retainUntil)
            }
            publishSnapshotLocked()
        }
    }

    private static func defaultFileURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return base
            .appendingPathComponent("board", isDirectory: true)
            .appendingPathComponent("posts.json")
    }
}
