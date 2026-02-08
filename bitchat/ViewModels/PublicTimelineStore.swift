//
// PublicTimelineStore.swift
// bitchat
//
// Maintains mesh and geohash public timelines with simple caps and helpers.
//

import Foundation

struct PublicTimelineStore {
    private var meshTimeline: [BitchatMessage] = []
    private var geohashTimelines: [String: [BitchatMessage]] = [:]
    private var pendingGeohashSystemMessages: [String] = []
    private var meshMessageIDs: Set<String> = []
    private var geohashMessageIDs: [String: Set<String>] = [:]

    private let meshCap: Int
    private let geohashCap: Int

    init(meshCap: Int, geohashCap: Int) {
        self.meshCap = meshCap
        self.geohashCap = geohashCap
    }

    mutating func append(_ message: BitchatMessage, to channel: ChannelID) {
        switch channel {
        case .mesh:
            guard meshMessageIDs.insert(message.id).inserted else { return }
            meshTimeline.append(message)
            trimMeshTimelineIfNeeded()
        case .location(let channel):
            append(message, toGeohash: channel.geohash)
        }
    }

    mutating func append(_ message: BitchatMessage, toGeohash geohash: String) {
        var timeline = geohashTimelines[geohash] ?? []
        var idSet = geohashMessageIDs[geohash] ?? Set()
        guard idSet.insert(message.id).inserted else { return }
        timeline.append(message)
        trimGeohashTimelineIfNeeded(&timeline, ids: &idSet)
        geohashTimelines[geohash] = timeline
        geohashMessageIDs[geohash] = idSet
    }

    /// Append message if absent, returning true when stored.
    mutating func appendIfAbsent(_ message: BitchatMessage, toGeohash geohash: String) -> Bool {
        var timeline = geohashTimelines[geohash] ?? []
        var idSet = geohashMessageIDs[geohash] ?? Set()
        guard idSet.insert(message.id).inserted else { return false }
        timeline.append(message)
        trimGeohashTimelineIfNeeded(&timeline, ids: &idSet)
        geohashTimelines[geohash] = timeline
        geohashMessageIDs[geohash] = idSet
        return true
    }

    mutating func messages(for channel: ChannelID) -> [BitchatMessage] {
        switch channel {
        case .mesh:
            return meshTimeline
        case .location(let channel):
            let cleaned = geohashTimelines[channel.geohash]?.cleanedAndDeduped() ?? []
            geohashTimelines[channel.geohash] = cleaned
            geohashMessageIDs[channel.geohash] = Set(cleaned.map { $0.id })
            return cleaned
        }
    }

    mutating func clear(channel: ChannelID) {
        switch channel {
        case .mesh:
            meshTimeline.removeAll()
            meshMessageIDs.removeAll()
        case .location(let channel):
            geohashTimelines[channel.geohash] = []
            geohashMessageIDs.removeValue(forKey: channel.geohash)
        }
    }

    @discardableResult
    mutating func removeMessage(withID id: String) -> BitchatMessage? {
        if let index = meshTimeline.firstIndex(where: { $0.id == id }) {
            let removed = meshTimeline.remove(at: index)
            meshMessageIDs.remove(id)
            return removed
        }

        for key in Array(geohashTimelines.keys) {
            var timeline = geohashTimelines[key] ?? []
            if let index = timeline.firstIndex(where: { $0.id == id }) {
                let removed = timeline.remove(at: index)
                if timeline.isEmpty {
                    geohashTimelines[key] = nil
                    geohashMessageIDs.removeValue(forKey: key)
                } else {
                    geohashTimelines[key] = timeline
                    var idSet = geohashMessageIDs[key] ?? Set()
                    idSet.remove(id)
                    geohashMessageIDs[key] = idSet
                }
                return removed
            }
        }

        return nil
    }

    mutating func removeMessages(in geohash: String, where predicate: (BitchatMessage) -> Bool) {
        var timeline = geohashTimelines[geohash] ?? []
        timeline.removeAll(where: predicate)
        if timeline.isEmpty {
            geohashTimelines[geohash] = nil
            geohashMessageIDs.removeValue(forKey: geohash)
        } else {
            geohashTimelines[geohash] = timeline
            geohashMessageIDs[geohash] = Set(timeline.map { $0.id })
        }
    }

    mutating func mutateGeohash(_ geohash: String, _ transform: (inout [BitchatMessage]) -> Void) {
        var timeline = geohashTimelines[geohash] ?? []
        transform(&timeline)
        if timeline.isEmpty {
            geohashTimelines[geohash] = nil
            geohashMessageIDs.removeValue(forKey: geohash)
        } else {
            var idSet = Set(timeline.map { $0.id })
            trimGeohashTimelineIfNeeded(&timeline, ids: &idSet)
            geohashTimelines[geohash] = timeline
            geohashMessageIDs[geohash] = idSet
        }
    }

    mutating func queueGeohashSystemMessage(_ content: String) {
        pendingGeohashSystemMessages.append(content)
    }

    mutating func drainPendingGeohashSystemMessages() -> [String] {
        defer { pendingGeohashSystemMessages.removeAll(keepingCapacity: false) }
        return pendingGeohashSystemMessages
    }

    func geohashKeys() -> [String] {
        Array(geohashTimelines.keys)
    }

    private mutating func trimMeshTimelineIfNeeded() {
        guard meshTimeline.count > meshCap else { return }
        let trimmed = Array(meshTimeline.suffix(meshCap))
        meshTimeline = trimmed
        meshMessageIDs = Set(trimmed.map { $0.id })
    }

    private func trimGeohashTimelineIfNeeded(_ timeline: inout [BitchatMessage], ids: inout Set<String>) {
        guard timeline.count > geohashCap else { return }
        let trimmed = Array(timeline.suffix(geohashCap))
        timeline = trimmed
        ids = Set(trimmed.map { $0.id })
    }
}
