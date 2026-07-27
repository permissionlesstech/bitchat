//
// GeohashChatActivityTracker.swift
// bitchat
//
// Tracks actual chat-message activity per sampled geohash so the empty mesh
// timeline can point at a nearby channel where a conversation is happening —
// not merely where participants are present.
// This is free and unencumbered software released into the public domain.
//

import Foundation

/// A recent chat message observed in a sampled geohash channel.
struct GeohashChatPreview: Equatable, Sendable {
    let senderName: String
    let content: String
    let timestamp: Date
}

/// The liveliest nearby conversation, resolved against the user's regional
/// channels.
struct NearbyConversation: Equatable, Sendable {
    let channel: GeohashChannel
    /// Chat messages seen within the activity window.
    let messageCount: Int
    let lastMessage: GeohashChatPreview
}

/// Records kind-20000 chat events seen by the background geohash sampling
/// subscriptions (blocked and self senders are filtered by the caller) and
/// answers "where nearby is a conversation actually happening?".
@MainActor
final class GeohashChatActivityTracker: ObservableObject {
    static let shared = GeohashChatActivityTracker()

    /// How far back a message still counts as "a conversation is happening".
    private let window: TimeInterval
    /// Per-geohash recent message timestamps (pruned to the window).
    private var messageTimes: [String: [Date]] = [:]
    /// Per-geohash newest message preview.
    private var lastMessages: [String: GeohashChatPreview] = [:]
    private let now: () -> Date

    init(
        window: TimeInterval = TransportConfig.uiGeohashChatActivityWindowSeconds,
        now: @escaping () -> Date = { Date() }
    ) {
        self.window = window
        self.now = now
    }

    func recordChatMessage(
        geohash: String,
        senderName: String,
        content: String,
        timestamp: Date
    ) {
        let gh = geohash.lowercased()
        let clamped = min(timestamp, now())
        guard now().timeIntervalSince(clamped) < window else { return }

        var times = messageTimes[gh] ?? []
        times.append(clamped)
        messageTimes[gh] = prune(times)

        if let existing = lastMessages[gh], existing.timestamp > clamped {
            // Keep the newer preview.
        } else {
            lastMessages[gh] = GeohashChatPreview(senderName: senderName, content: content, timestamp: clamped)
        }
        objectWillChange.send()
    }

    /// Messages seen in the window for one geohash.
    func messageCount(for geohash: String) -> Int {
        prune(messageTimes[geohash.lowercased()] ?? []).count
    }

    func lastMessage(for geohash: String) -> GeohashChatPreview? {
        let gh = geohash.lowercased()
        guard messageCount(for: gh) > 0 else { return nil }
        return lastMessages[gh]
    }

    /// The busiest channel with at least one chat message in the window.
    /// Ties go to the more local (higher-precision) channel, so a lone
    /// message on your block beats a lone message across the region.
    func mostActiveConversation(among channels: [GeohashChannel]) -> NearbyConversation? {
        var best: NearbyConversation?
        for channel in channels {
            let count = messageCount(for: channel.geohash)
            guard count > 0, let last = lastMessage(for: channel.geohash) else { continue }
            let candidate = NearbyConversation(channel: channel, messageCount: count, lastMessage: last)
            if let current = best {
                let better = count > current.messageCount
                    || (count == current.messageCount
                        && channel.level.precision > current.channel.level.precision)
                if better { best = candidate }
            } else {
                best = candidate
            }
        }
        return best
    }

    func clear() {
        messageTimes.removeAll()
        lastMessages.removeAll()
        objectWillChange.send()
    }

    private func prune(_ times: [Date]) -> [Date] {
        let cutoff = now().addingTimeInterval(-window)
        return times.filter { $0 >= cutoff }
    }
}
