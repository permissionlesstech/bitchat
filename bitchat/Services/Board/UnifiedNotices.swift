//
// UnifiedNotices.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// One row in the unified notices sheet: a mesh board post or a Nostr
/// location note, normalized for display.
struct NoticeItem: Identifiable, Equatable {
    enum Source: Equatable {
        /// Signed board post carried by the mesh.
        case board(BoardPostPacket)
        /// Kind-1 location note seen on geo relays.
        case nostr(LocationNotesManager.Note)
    }

    let id: String
    let author: String
    let content: String
    let createdAt: Date
    let isUrgent: Bool
    /// When the notice fades (board expiry or a note's NIP-40 tag, as dead
    /// drops carry). Nil means it only ages out of the relay window.
    let expiresAt: Date?
    let source: Source

    var isBoardPost: Bool {
        if case .board = source { return true }
        return false
    }

    init(post: BoardPostPacket) {
        id = post.postID.hexEncodedString()
        author = post.authorNickname.trimmedOrNilIfEmpty ?? "anon"
        content = post.content
        createdAt = Date(timeIntervalSince1970: TimeInterval(post.createdAt) / 1000)
        isUrgent = post.isUrgent
        expiresAt = post.expiresAt > 0
            ? Date(timeIntervalSince1970: TimeInterval(post.expiresAt) / 1000)
            : nil
        source = .board(post)
    }

    init(note: LocationNotesManager.Note) {
        id = note.id
        let display = note.displayName
        author = display.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? display
        content = note.content
        createdAt = note.createdAt
        isUrgent = note.isUrgent
        expiresAt = note.expiresAt
        source = .nostr(note)
    }
}

/// Merges mesh board posts and Nostr location notes into one deduplicated
/// list for the notices sheet's geo tab.
enum UnifiedNotices {
    /// Board posts on geohash channels are bridged to Nostr as kind-1 notes at
    /// post time, so the same notice arrives twice. The copies share content
    /// and nickname but are signed by unlinkable keys; match them
    /// heuristically by content + author within a time window.
    static let bridgeDedupeWindow: TimeInterval = 15 * 60

    /// Returns board posts and notes as one list, urgent posts first, then
    /// newest first. Notes that look like bridged copies of a board post are
    /// dropped — the board copy wins because it carries urgency and supports
    /// merged deletion. The geohash must match exactly: the notes
    /// subscription also surfaces neighboring cells, and a same-text note
    /// from a neighbor is not the bridged copy.
    static func merge(posts: [BoardPostPacket], notes: [LocationNotesManager.Note]) -> [NoticeItem] {
        var items = posts.map(NoticeItem.init(post:))
        for note in notes {
            let noteNickname = note.nickname?.trimmedOrNilIfEmpty ?? "anon"
            let isBridgedCopy = posts.contains { post in
                post.geohash == note.geohash
                    && post.content == note.content
                    && (post.authorNickname.trimmedOrNilIfEmpty ?? "anon") == noteNickname
                    && abs(Date(timeIntervalSince1970: TimeInterval(post.createdAt) / 1000).timeIntervalSince(note.createdAt)) <= bridgeDedupeWindow
            }
            if !isBridgedCopy {
                items.append(NoticeItem(note: note))
            }
        }
        return items.sorted {
            if $0.isUrgent != $1.isUrgent { return $0.isUrgent }
            return $0.createdAt > $1.createdAt
        }
    }
}
