//
// PlaceFeedModel.swift
// bitchat
//
// Pure sorting, filtering, and search organizer for the Place Feed, plus
// the Chat / Feed mode enum shared by active Place rooms.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Active surface inside a Place room (`Places` tab).
enum PlaceRoomMode: String, CaseIterable, Identifiable {
    case chat
    case feed

    var id: String { rawValue }
}

/// Top-level surface inside the Places tab (`Explore` directory vs. merged `Feed` home stream).
enum PlacesTabMode: String, CaseIterable, Identifiable {
    case explore
    case feed

    var id: String { rawValue }
}

/// Scope filter inside the Home Feed stream.
enum HomeFeedScope: String, CaseIterable, Identifiable {
    case all
    case savedPlaces
    case following

    var id: String { rawValue }
}

/// Cryptographic identity posture used when publishing a post or reply.
enum PostingIdentityMode: String, CaseIterable, Identifiable {
    /// Default: deterministic, unlinkable per-geohash key (`HMAC(deviceSeed, geohash)`).
    case placePersona
    /// Opt-in: persistent primary Nostr identity (`kind 0` public handle) so followers can follow across places.
    case publicHandle

    var id: String { rawValue }
}

/// Sort order for the Place Feed timeline.
enum PlaceFeedSort: String, CaseIterable, Identifiable {
    case latest
    case top

    var id: String { rawValue }
}

/// Signal filter for the Place Feed timeline.
enum PlaceFeedFilter: String, CaseIterable, Identifiable {
    case all
    case localOnly
    case verifiedPoW
    case vouched

    var id: String { rawValue }
}

/// Deterministic organizer for merged Nostr + mesh-board Place Feed items.
enum PlaceFeedOrganizer {
    /// Engagement score used by `.top` sort. Gives higher weight to discussion
    /// (replies), then reactions, plus a small bonus for validated NIP-13 PoW.
    static func engagementScore(
        for item: NoticeItem,
        replyCount: Int,
        reactionCount: Int
    ) -> Int {
        let powBonus = item.powDifficulty >= NostrProtocol.verifiedPoWThresholdBits ? 2 : 0
        return reactionCount * 2 + replyCount * 3 + powBonus
    }

    static func organize(
        items: [NoticeItem],
        sort: PlaceFeedSort,
        filter: PlaceFeedFilter,
        query: String = "",
        replyCount: (String) -> Int = { _ in 0 },
        reactionCount: (String) -> Int = { _ in 0 },
        isVouched: (NoticeItem) -> Bool = { _ in false }
    ) -> [NoticeItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let filtered = items.filter { item in
            switch filter {
            case .all:
                break
            case .localOnly:
                if item.isTeleported { return false }
            case .verifiedPoW:
                if !item.hasVerifiedPoW { return false }
            case .vouched:
                if !isVouched(item) { return false }
            }

            if !trimmedQuery.isEmpty {
                let matchesContent = item.content.localizedCaseInsensitiveContains(trimmedQuery)
                let matchesAuthor = item.author.localizedCaseInsensitiveContains(trimmedQuery)
                if !matchesContent && !matchesAuthor {
                    return false
                }
            }
            return true
        }

        return filtered.sorted { lhs, rhs in
            if lhs.isUrgent != rhs.isUrgent {
                return lhs.isUrgent
            }
            switch sort {
            case .latest:
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.id < rhs.id
            case .top:
                let lhsScore = engagementScore(
                    for: lhs,
                    replyCount: replyCount(lhs.id),
                    reactionCount: reactionCount(lhs.id)
                )
                let rhsScore = engagementScore(
                    for: rhs,
                    replyCount: replyCount(rhs.id),
                    reactionCount: reactionCount(rhs.id)
                )
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.id < rhs.id
            }
        }
    }
}
