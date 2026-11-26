//
// GeohashActivity.swift
// bitchat
//
// The one rule for "who is in a geohash channel", shared by the location
// channels sheet and the globe picker.
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Recent public activity in one exact geohash channel, as seen on the globe picker.
struct GeohashChannelActivity: Equatable, Identifiable, Sendable {
    let geohash: String
    let latitude: Double
    let longitude: Double
    /// Distinct people with a heartbeat or message inside the presence window.
    let online: Int
    /// Distinct people who wrote in the channel inside the chat window.
    let chatters: Int
    /// Chat messages inside the chat window (history is capped per channel, so a
    /// very busy channel reads as at most the cap).
    let messages: Int
    /// Distinct people across both windows; this is what a marker shows.
    let people: Int
    /// Newest activity of any kind.
    let lastActiveAt: Date

    var id: String { geohash }
}

struct GeohashActivitySnapshot: Equatable {
    /// Channels ordered by `people`, busiest first.
    let channels: [GeohashChannelActivity]
    /// Estimated people online worldwide; see `estimateDistinctPeople`.
    let totalOnline: Int
    /// Channels with at least one message inside the chat window.
    let activeChats: Int

    private let byGeohash: [String: GeohashChannelActivity]

    init(channels: [GeohashChannelActivity], totalOnline: Int, activeChats: Int) {
        self.channels = channels
        self.totalOnline = totalOnline
        self.activeChats = activeChats
        byGeohash = Dictionary(channels.map { ($0.geohash, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static let empty = GeohashActivitySnapshot(channels: [], totalOnline: 0, activeChats: 0)

    func channel(_ geohash: String) -> GeohashChannelActivity? {
        byGeohash[geohash]
    }

    /// The liveliest conversation nested inside `geohash`, when it is livelier than
    /// `geohash` itself. Chats rank above heartbeats.
    func busiestInside(_ geohash: String) -> GeohashChannelActivity? {
        guard !geohash.isEmpty else { return nil }
        let selectedMessages = channel(geohash)?.messages ?? 0
        return channels
            .filter { $0.geohash.count > geohash.count && $0.geohash.hasPrefix(geohash) && $0.messages > selectedMessages }
            .max { ($0.messages, $0.people) < ($1.messages, $1.people) }
    }

    /// Estimates distinct people across `channels`.
    ///
    /// Clients heartbeat into several nested channels at once (region, province and
    /// city), each under a channel-specific identity, so summing double counts. Each
    /// person appears about once per precision level, so the busiest level is the
    /// honest estimate.
    static func estimateDistinctPeople(
        _ channels: [GeohashChannelActivity],
        count: (GeohashChannelActivity) -> Int = { $0.people }
    ) -> Int {
        var perLevel = [Int](repeating: 0, count: 13)
        for channel in channels {
            perLevel[min(max(channel.geohash.count, 0), 12)] += count(channel)
        }
        return perLevel.max() ?? 0
    }
}

/// Who counts in a geohash channel: anyone with a heartbeat or message in the last
/// five minutes, plus anyone who wrote in the last hour. Chat messages are counted
/// for the hour as well.
///
/// Geohash identities are derived per channel, so a person active in several
/// channels is counted once in each. Activity time is clamped to now so a skewed
/// clock cannot pin anyone online. Channel keys are lowercased but not validated;
/// callers decide what a channel is. A value type: owners serialize access.
struct GeohashActivityAggregator {
    static let presenceWindow: TimeInterval = 5 * 60
    static let chatWindow: TimeInterval = 60 * 60

    private struct Message {
        let pubkey: String
        let at: Date
    }

    private struct Channel {
        /// Center of the cell; nil for keys that aren't geohashes.
        let center: (lat: Double, lon: Double)?
        /// pubkey -> newest activity of any kind.
        var lastSeen: [String: Date] = [:]
        /// pubkey -> newest chat message. Kept apart from `messages` so the size cap
        /// on message history never drops an author who wrote inside the window.
        var lastChat: [String: Date] = [:]
        /// Chat messages by event id, plus their arrival order for the size cap.
        var messages: [String: Message] = [:]
        var messageOrder: [String] = []
        var lastActiveAt = Date.distantPast
    }

    private struct Tally {
        let people: Set<String>
        let online: Int
        let chatters: Int
        let messages: Int
    }

    let presenceWindow: TimeInterval
    let chatWindow: TimeInterval
    private let maxChannels: Int
    private let maxMessagesPerChannel: Int
    private var channels: [String: Channel] = [:]

    init(
        presenceWindow: TimeInterval = Self.presenceWindow,
        chatWindow: TimeInterval = Self.chatWindow,
        maxChannels: Int = 600,
        maxMessagesPerChannel: Int = 500
    ) {
        self.presenceWindow = presenceWindow
        self.chatWindow = max(chatWindow, presenceWindow)
        self.maxChannels = maxChannels
        self.maxMessagesPerChannel = maxMessagesPerChannel
    }

    var isEmpty: Bool { channels.isEmpty }

    /// Records one heartbeat (`chatEventID` nil) or chat message seen in `geohash` at
    /// `at`. Returns whether the activity counts, i.e. fell inside its window.
    @discardableResult
    mutating func record(geohash: String, pubkey: String, at: Date, chatEventID: String? = nil, now: Date = Date()) -> Bool {
        let cell = geohash.lowercased()
        guard !cell.isEmpty else { return false }
        let stamp = min(at, now)
        let window = chatEventID == nil ? presenceWindow : chatWindow
        guard stamp >= now.addingTimeInterval(-window) else { return false }

        let key = pubkey.lowercased()
        // Mutated in place: copying the channel out and back would copy its per-person
        // tables on every heartbeat, which runs for every inbound geohash event.
        Self.add(
            to: &channels[cell, default: Channel(center: Geohash.isValidGeohash(cell) ? Geohash.decodeCenter(cell) : nil)],
            key: key,
            at: stamp,
            chatEventID: chatEventID,
            maxMessages: maxMessagesPerChannel
        )
        if channels.count > maxChannels { evictStalest() }
        return true
    }

    private static func add(to channel: inout Channel, key: String, at stamp: Date, chatEventID: String?, maxMessages: Int) {
        if stamp > (channel.lastSeen[key] ?? .distantPast) {
            channel.lastSeen[key] = stamp
        }
        if chatEventID != nil, stamp > (channel.lastChat[key] ?? .distantPast) {
            channel.lastChat[key] = stamp
        }
        if let chatEventID, channel.messages[chatEventID] == nil {
            channel.messages[chatEventID] = Message(pubkey: key, at: stamp)
            channel.messageOrder.append(chatEventID)
            if channel.messageOrder.count > maxMessages {
                channel.messages.removeValue(forKey: channel.messageOrder.removeFirst())
            }
        }
        channel.lastActiveAt = max(channel.lastActiveAt, stamp)
    }

    /// Whether `pubkey` currently counts in `geohash`.
    func isActive(_ pubkey: String, in geohash: String, now: Date = Date()) -> Bool {
        guard let channel = channels[geohash.lowercased()] else { return false }
        let key = pubkey.lowercased()
        if let seen = channel.lastSeen[key], seen >= now.addingTimeInterval(-presenceWindow) { return true }
        if let wrote = channel.lastChat[key], wrote >= now.addingTimeInterval(-chatWindow) { return true }
        return false
    }

    /// People counted in `geohash` right now, with their newest activity.
    func activePeople(in geohash: String, now: Date = Date(), excluding exclude: (String) -> Bool = { _ in false }) -> [String: Date] {
        guard let channel = channels[geohash.lowercased()] else { return [:] }
        let tally = tally(channel, now: now, excluding: exclude)
        var people: [String: Date] = [:]
        for pubkey in tally.people {
            people[pubkey] = channel.lastSeen[pubkey] ?? channel.lastActiveAt
        }
        return people
    }

    func count(in geohash: String, now: Date = Date(), excluding exclude: (String) -> Bool = { _ in false }) -> Int {
        guard let channel = channels[geohash.lowercased()] else { return 0 }
        return tally(channel, now: now, excluding: exclude).people.count
    }

    /// Every geohash channel under the rule. `exclude` drops identities (blocked
    /// users) from every count so the globe and the channel sheet agree.
    func snapshot(now: Date = Date(), excluding exclude: (String) -> Bool = { _ in false }) -> GeohashActivitySnapshot {
        var activeChats = 0
        var result: [GeohashChannelActivity] = []
        result.reserveCapacity(channels.count)
        for (geohash, channel) in channels {
            guard let center = channel.center else { continue }
            let tally = tally(channel, now: now, excluding: exclude)
            guard !tally.people.isEmpty else { continue }
            if tally.messages > 0 { activeChats += 1 }
            result.append(GeohashChannelActivity(
                geohash: geohash,
                latitude: center.lat,
                longitude: center.lon,
                online: tally.online,
                chatters: tally.chatters,
                messages: tally.messages,
                people: tally.people.count,
                lastActiveAt: channel.lastActiveAt
            ))
        }
        // Geohash breaks ties so the order (and the clustering built on it) is stable.
        result.sort { ($0.people, $0.messages, $1.geohash) > ($1.people, $1.messages, $0.geohash) }
        return GeohashActivitySnapshot(
            channels: result,
            totalOnline: GeohashActivitySnapshot.estimateDistinctPeople(result) { $0.online },
            activeChats: activeChats
        )
    }

    /// Drops activity that left its window. Returns true when anything was removed.
    @discardableResult
    mutating func prune(now: Date = Date()) -> Bool {
        let chatCutoff = now.addingTimeInterval(-chatWindow)
        let presenceCutoff = now.addingTimeInterval(-presenceWindow)
        var changed = false
        for (geohash, var channel) in channels {
            let counts = (channel.messages.count, channel.lastChat.count, channel.lastSeen.count)
            channel.messages = channel.messages.filter { $0.value.at >= chatCutoff }
            channel.lastChat = channel.lastChat.filter { $0.value >= chatCutoff }
            channel.lastSeen = channel.lastSeen.filter { $0.value >= presenceCutoff || channel.lastChat[$0.key] != nil }
            guard (channel.messages.count, channel.lastChat.count, channel.lastSeen.count) != counts else { continue }
            changed = true
            if channel.lastSeen.isEmpty && channel.lastChat.isEmpty && channel.messages.isEmpty {
                channels.removeValue(forKey: geohash)
            } else {
                channel.messageOrder.removeAll { channel.messages[$0] == nil }
                channels[geohash] = channel
            }
        }
        return changed
    }

    /// Forgets `pubkey` everywhere (used when blocking).
    mutating func remove(pubkey: String) {
        let key = pubkey.lowercased()
        for (geohash, var channel) in channels {
            channel.lastSeen.removeValue(forKey: key)
            channel.lastChat.removeValue(forKey: key)
            channel.messages = channel.messages.filter { $0.value.pubkey != key }
            channel.messageOrder.removeAll { channel.messages[$0] == nil }
            channels[geohash] = channel
        }
    }

    mutating func removeChannel(_ geohash: String) {
        channels.removeValue(forKey: geohash.lowercased())
    }

    mutating func removeAll() {
        channels.removeAll()
    }

    /// The rule itself: online in the presence window, or wrote in the chat window.
    private func tally(_ channel: Channel, now: Date, excluding exclude: (String) -> Bool) -> Tally {
        let chatCutoff = now.addingTimeInterval(-chatWindow)
        let presenceCutoff = now.addingTimeInterval(-presenceWindow)
        var chatters = Set<String>()
        for (pubkey, wrote) in channel.lastChat where wrote >= chatCutoff && !exclude(pubkey) {
            chatters.insert(pubkey)
        }
        var messages = 0
        for message in channel.messages.values where message.at >= chatCutoff && !exclude(message.pubkey) {
            messages += 1
        }
        var people = chatters
        var online = 0
        for (pubkey, seen) in channel.lastSeen where seen >= presenceCutoff && !exclude(pubkey) {
            online += 1
            people.insert(pubkey)
        }
        return Tally(people: people, online: online, chatters: chatters.count, messages: messages)
    }

    private mutating func evictStalest() {
        guard let stalest = channels.min(by: { $0.value.lastActiveAt < $1.value.lastActiveAt })?.key else { return }
        channels.removeValue(forKey: stalest)
    }
}
