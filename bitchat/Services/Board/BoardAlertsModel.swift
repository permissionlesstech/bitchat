//
// BoardAlertsModel.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import Foundation

/// Turns newly arriving board posts into local, scope-matched chat alerts.
/// Everything here is derived from posts the mesh already synced — no extra
/// wire traffic, nothing another peer can't already see.
///
/// - Urgent, recent pins get one system line in the matching chat (geo pin →
///   that geohash's timeline, mesh pin → mesh chat), collapsed when several
///   arrive together.
/// - Every other new pin just marks the header's pin icon until the notices
///   sheet is opened.
@MainActor
final class BoardAlertsModel: ObservableObject {
    struct Dependencies {
        /// Own posts never alert; the author already knows.
        var isOwnPost: @MainActor (BoardPostPacket) -> Bool
        /// Appends a local system line to a scope's chat timeline
        /// (geohash, or "" for mesh chat).
        var emitSystemLine: @MainActor (_ content: String, _ geohash: String) -> Void
        var now: () -> Date = Date.init
        /// Schedules the collapsed flush of pending urgent alerts; tests
        /// inject a synchronous hook.
        var scheduleFlush: (_ flush: @escaping @MainActor () -> Void) -> Void = { flush in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(BoardAlertsModel.collapseDelaySeconds * 1_000_000_000))
                flush()
            }
        }
    }

    /// Posts older than this at arrival are backfilled history carried in by
    /// a peer, not something happening now; they badge but never line the chat.
    static let inlineRecencyWindow: TimeInterval = 30 * 60
    /// Urgent arrivals within this window collapse into one line.
    static let collapseDelaySeconds: TimeInterval = 4
    private static let alertContentMaxChars = 120

    /// Unseen new pins by postID (hex) → geohash scope, cleared when the
    /// notices sheet opens.
    @Published private(set) var unseenPostScopes: [String: String] = [:]

    /// PostIDs already handled this session, so store eviction/re-sync churn
    /// can't re-alert. Bounded by session wire volume (32-byte strings).
    private var handledPostIDs = Set<String>()
    private var pendingUrgent: [String: [BoardPostPacket]] = [:]
    private var flushScheduled = false
    private let dependencies: Dependencies
    private var cancellable: AnyCancellable?
    private var wipeCancellable: AnyCancellable?

    private enum Strings {
        static func urgentSingle(author: String, content: String) -> String {
            String(
                format: String(localized: "notices.alert.urgent_single", defaultValue: "📌 urgent notice from @%@: %@", comment: "Local chat line when one urgent notice is pinned nearby"),
                locale: .current,
                author, content
            )
        }

        static func urgentCollapsed(_ count: Int) -> String {
            String(
                format: String(localized: "notices.alert.urgent_collapsed", defaultValue: "📌 %lld new urgent notices — tap the pin to view", comment: "Local chat line when several urgent notices arrive together"),
                locale: .current,
                count
            )
        }
    }

    init(
        arrivals: AnyPublisher<BoardPostPacket, Never>,
        wipes: AnyPublisher<Void, Never> = Empty(completeImmediately: false).eraseToAnyPublisher(),
        dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        cancellable = arrivals
            .receive(on: DispatchQueue.main)
            .sink { [weak self] post in
                self?.handleArrival(post)
            }
        wipeCancellable = wipes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.reset()
            }
    }

    func unseenCount(forGeohash geohash: String) -> Int {
        unseenPostScopes.values.reduce(0) { $0 + ($1 == geohash ? 1 : 0) }
    }

    /// Marks pins in the given scopes as seen — only the scopes the notices
    /// sheet actually shows, so unseen pins for other geohash channels keep
    /// their badge until visited.
    func markSeen(forScopes scopes: Set<String>) {
        guard unseenPostScopes.contains(where: { scopes.contains($0.value) }) else { return }
        unseenPostScopes = unseenPostScopes.filter { !scopes.contains($0.value) }
    }

    /// Panic wipe: drop everything derived from pre-wipe posts, including
    /// urgent lines still waiting on the collapse flush.
    func reset() {
        pendingUrgent.removeAll()
        handledPostIDs.removeAll()
        guard !unseenPostScopes.isEmpty else { return }
        unseenPostScopes.removeAll()
    }

    func handleArrival(_ post: BoardPostPacket) {
        let postID = post.postID.hexEncodedString()
        guard !handledPostIDs.contains(postID) else { return }
        handledPostIDs.insert(postID)
        guard !dependencies.isOwnPost(post) else { return }

        unseenPostScopes[postID] = post.geohash

        let createdAt = Date(timeIntervalSince1970: TimeInterval(post.createdAt) / 1000)
        guard post.isUrgent,
              dependencies.now().timeIntervalSince(createdAt) <= Self.inlineRecencyWindow else {
            return
        }
        pendingUrgent[post.geohash, default: []].append(post)
        if !flushScheduled {
            flushScheduled = true
            dependencies.scheduleFlush { [weak self] in
                self?.flushPendingUrgent()
            }
        }
    }

    private func flushPendingUrgent() {
        flushScheduled = false
        let pending = pendingUrgent
        pendingUrgent.removeAll()
        for (geohash, posts) in pending {
            guard let first = posts.first else { continue }
            let line: String
            if posts.count == 1 {
                let author = first.authorNickname.trimmedOrNilIfEmpty ?? "anon"
                line = Strings.urgentSingle(author: author, content: Self.truncated(first.content))
            } else {
                line = Strings.urgentCollapsed(posts.count)
            }
            dependencies.emitSystemLine(line, geohash)
        }
    }

    private static func truncated(_ content: String) -> String {
        guard content.count > alertContentMaxChars else { return content }
        return content.prefix(alertContentMaxChars) + "…"
    }
}
