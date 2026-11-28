//
// MessageInteractionCodec.swift
// bitchat
//
// Backwards-compatible wire encoding/parsing for quoted replies and emoji
// reactions across BLE mesh, Nostr DMs, location channels, and hybrid groups.
// This is free and unencumbered software released into the public domain.
//

import BitFoundation
import Foundation

struct MessageReplyTarget: Equatable {
    let messageID: String
    let sender: String
    let snippet: String

    init(messageID: String, sender: String, content: String) {
        self.messageID = messageID
        self.sender = sender
        self.snippet = MessageInteractionCodec.makeSnippet(from: content)
    }
}

struct ParsedReplyContent: Equatable {
    let quotedSender: String
    let quotedSnippet: String
    let body: String
}

struct ParsedReaction: Equatable {
    let targetShortID: String
    let emoji: String
}

struct AggregatedReaction: Equatable, Identifiable {
    let emoji: String
    let count: Int
    let includesCurrentUser: Bool

    var id: String { emoji }
}

enum MessageInteractionCodec {
    static let quickReactionPalette: [String] = ["👍", "❤️", "😂", "😮", "😢", "🔥"]
    static let maxSnippetLength = 80
    static let reactionTargetPrefixLength = 8

    // MARK: - Quoted Replies

    /// Condenses a message into a single-line bounded preview suitable for reply quotes.
    static func makeSnippet(from content: String) -> String {
        let stripped: String
        if let parsed = parseReply(from: content) {
            stripped = parsed.body
        } else {
            stripped = content
        }
        let collapsed = stripped
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= maxSnippetLength {
            return collapsed
        }
        return String(collapsed.prefix(maxSnippetLength - 1)) + "…"
    }

    /// Encodes a quoted reply in a human-readable format that degrades gracefully
    /// on older iOS/Android clients (`> @sender: snippet\nbody`).
    static func encodeReply(to target: MessageReplyTarget, body: String) -> String {
        var cleanSender = target.sender
            .replacingOccurrences(of: "\r\n", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleanSender.contains(": ") {
            cleanSender = cleanSender.replacingOccurrences(of: ": ", with: " ")
        }
        while cleanSender.hasPrefix("> ") {
            cleanSender = String(cleanSender.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        cleanSender = cleanSender.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSnippet = makeSnippet(from: target.snippet)
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSender.isEmpty, !cleanSnippet.isEmpty else {
            return cleanBody
        }
        return "> @\(cleanSender): \(cleanSnippet)\n\(cleanBody)"
    }

    /// Parses a `> @sender: snippet\nbody` reply message back into structured parts.
    static func parseReply(from content: String) -> ParsedReplyContent? {
        guard content.hasPrefix("> @"),
              let newlineIndex = content.firstIndex(of: "\n") else {
            return nil
        }
        let header = content[content.index(content.startIndex, offsetBy: 3)..<newlineIndex]
        guard let colonRange = header.range(of: ": ") else {
            return nil
        }
        let sender = String(header[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let snippet = String(header[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        let body = String(content[content.index(after: newlineIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sender.isEmpty, !snippet.isEmpty, !body.isEmpty else {
            return nil
        }
        return ParsedReplyContent(
            quotedSender: sender,
            quotedSnippet: snippet,
            body: body
        )
    }

    // MARK: - Emoji Reactions

    static func shortID(for messageID: String) -> String {
        String(messageID.prefix(reactionTargetPrefixLength))
    }

    /// Encodes a compact reaction packet payload (`[react:<id8>:<emoji>]`).
    static func encodeReaction(emoji: String, toMessageID messageID: String) -> String {
        let cleanEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[react:\(shortID(for: messageID)):\(cleanEmoji)]"
    }

    /// Parses `[react:<id8>:<emoji>]` if `content` is a standalone reaction message.
    static func parseReaction(from content: String) -> ParsedReaction? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[react:"), trimmed.hasSuffix("]") else {
            return nil
        }
        let inner = trimmed.dropFirst("[react:".count).dropLast()
        guard let sep = inner.firstIndex(of: ":") else {
            return nil
        }
        let targetShortID = String(inner[..<sep])
        let emoji = String(inner[inner.index(after: sep)...])
        guard !targetShortID.isEmpty,
              targetShortID.count <= 16,
              !emoji.isEmpty,
              emoji.count <= 4 else {
            return nil
        }
        return ParsedReaction(targetShortID: targetShortID, emoji: emoji)
    }

    struct ReactionSummary {
        let reactionsByMessageID: [String: [AggregatedReaction]]
        let consumedControlMessageIDs: Set<String>
    }

    /// Aggregates reactions across a timeline, toggling when the same actor
    /// reacts with the same emoji twice, and returns IDs of reaction control
    /// messages that should be hidden because their target is in the timeline.
    static func aggregateReactions(
        in messages: [BitchatMessage],
        isCurrentUser: (BitchatMessage) -> Bool
    ) -> ReactionSummary {
        var targetIDByShortID: [String: String] = [:]
        for message in messages where message.sender != "system" {
            if parseReaction(from: message.content) == nil {
                targetIDByShortID[shortID(for: message.id)] = message.id
            }
        }

        // targetMessageID -> emoji -> Set<actorKey>
        var actorsByTargetAndEmoji: [String: [String: Set<String>]] = [:]
        var emojiOrderByTarget: [String: [String]] = [:]
        var currentUserActorKeys = Set<String>()
        var consumedIDs = Set<String>()

        for message in messages where message.sender != "system" {
            guard let parsed = parseReaction(from: message.content) else { continue }
            guard let targetMessageID = targetIDByShortID[parsed.targetShortID] else {
                // Hide orphan reaction control syntax so timelines stay clean.
                consumedIDs.insert(message.id)
                continue
            }
            consumedIDs.insert(message.id)

            let isMe = isCurrentUser(message)
            let actorKey = isMe ? "__me__" : (message.senderPeerID?.id ?? "name:\(message.sender)")
            if isMe {
                currentUserActorKeys.insert(actorKey)
            }

            var byEmoji = actorsByTargetAndEmoji[targetMessageID, default: [:]]
            var actors = byEmoji[parsed.emoji, default: []]
            if actors.contains(actorKey) {
                actors.remove(actorKey)
            } else {
                actors.insert(actorKey)
                var order = emojiOrderByTarget[targetMessageID, default: []]
                if !order.contains(parsed.emoji) {
                    order.append(parsed.emoji)
                    emojiOrderByTarget[targetMessageID] = order
                }
            }
            if actors.isEmpty {
                byEmoji.removeValue(forKey: parsed.emoji)
            } else {
                byEmoji[parsed.emoji] = actors
            }
            actorsByTargetAndEmoji[targetMessageID] = byEmoji
        }

        var result: [String: [AggregatedReaction]] = [:]
        for (targetID, byEmoji) in actorsByTargetAndEmoji where !byEmoji.isEmpty {
            let order = emojiOrderByTarget[targetID] ?? Array(byEmoji.keys)
            let items: [AggregatedReaction] = order.compactMap { emoji in
                guard let actors = byEmoji[emoji], !actors.isEmpty else { return nil }
                return AggregatedReaction(
                    emoji: emoji,
                    count: actors.count,
                    includesCurrentUser: !actors.isDisjoint(with: currentUserActorKeys)
                )
            }
            if !items.isEmpty {
                result[targetID] = items
            }
        }

        return ReactionSummary(
            reactionsByMessageID: result,
            consumedControlMessageIDs: consumedIDs
        )
    }

    // MARK: - In-Chat Search

    /// Returns matching message IDs in chronological order (oldest → newest),
    /// excluding system lines and hidden reaction control messages.
    static func matchingMessageIDs(
        in messages: [BitchatMessage],
        query: String
    ) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return messages.compactMap { message in
            guard message.sender != "system",
                  parseReaction(from: message.content) == nil else {
                return nil
            }
            let searchableBody = parseReply(from: message.content)?.body ?? message.content
            if searchableBody.localizedCaseInsensitiveContains(trimmed)
                || message.sender.localizedCaseInsensitiveContains(trimmed) {
                return message.id
            }
            return nil
        }
    }
}
