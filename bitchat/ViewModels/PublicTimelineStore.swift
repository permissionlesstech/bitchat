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

    private let meshCap: Int
    private let geohashCap: Int

    init(meshCap: Int, geohashCap: Int) {
        self.meshCap = meshCap
        self.geohashCap = geohashCap
    }

    mutating func append(_ message: BitchatMessage, to channel: ChannelID) {
        switch channel {
        case .mesh:
            guard !meshTimeline.contains(where: { $0.id == message.id }) else { return }
            meshTimeline.append(message)
            trimMeshTimelineIfNeeded()
        case .location(let channel):
            append(message, toGeohash: channel.geohash)
        }
    }

    mutating func append(_ message: BitchatMessage, toGeohash geohash: String) {
        var timeline = geohashTimelines[geohash] ?? []
        guard !timeline.contains(where: { $0.id == message.id }) else { return }
        timeline.append(message)
        trimGeohashTimelineIfNeeded(&timeline)
        geohashTimelines[geohash] = timeline
    }

    /// Append message if absent, returning true when stored.
    mutating func appendIfAbsent(_ message: BitchatMessage, toGeohash geohash: String) -> Bool {
        var timeline = geohashTimelines[geohash] ?? []
        guard !timeline.contains(where: { $0.id == message.id }) else { return false }
        timeline.append(message)
        trimGeohashTimelineIfNeeded(&timeline)
        geohashTimelines[geohash] = timeline
        return true
    }

    mutating func messages(for channel: ChannelID) -> [BitchatMessage] {
        switch channel {
        case .mesh:
            return meshTimeline
        case .location(let channel):
            let cleaned = geohashTimelines[channel.geohash]?.cleanedAndDeduped() ?? []
            geohashTimelines[channel.geohash] = cleaned
            return cleaned
        }
    }

    mutating func clear(channel: ChannelID) {
        switch channel {
        case .mesh:
            meshTimeline.removeAll()
        case .location(let channel):
            geohashTimelines[channel.geohash] = []
        }
    }

    @discardableResult
    mutating func removeMessage(withID id: String) -> BitchatMessage? {
        if let index = meshTimeline.firstIndex(where: { $0.id == id }) {
            return meshTimeline.remove(at: index)
        }

        for key in Array(geohashTimelines.keys) {
            var timeline = geohashTimelines[key] ?? []
            if let index = timeline.firstIndex(where: { $0.id == id }) {
                let removed = timeline.remove(at: index)
                geohashTimelines[key] = timeline.isEmpty ? nil : timeline
                return removed
            }
        }

        return nil
    }

    mutating func removeMessages(in geohash: String, where predicate: (BitchatMessage) -> Bool) {
        var timeline = geohashTimelines[geohash] ?? []
        timeline.removeAll(where: predicate)
        geohashTimelines[geohash] = timeline.isEmpty ? nil : timeline
    }

    mutating func mutateGeohash(_ geohash: String, _ transform: (inout [BitchatMessage]) -> Void) {
        var timeline = geohashTimelines[geohash] ?? []
        transform(&timeline)
        geohashTimelines[geohash] = timeline.isEmpty ? nil : timeline
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
        meshTimeline = Array(meshTimeline.suffix(meshCap))
    }

    private func trimGeohashTimelineIfNeeded(_ timeline: inout [BitchatMessage]) {
        guard timeline.count > geohashCap else { return }
        timeline = Array(timeline.suffix(geohashCap))
    }
}
