//
// PublicTimelineStore.swift
// bitchat
//
// Maintains mesh and geohash public timelines and owns the currently visible
// public message window so views can observe the store directly.
//

import Combine
import Foundation

@MainActor
final class PublicTimelineStore: ObservableObject, PublicTimelineStoreProtocol {
    @Published private(set) var visibleMessages: [BitchatMessage] = []
    @Published private(set) var activeChannel: ChannelID = .mesh

    private var meshTimeline: [BitchatMessage] = []
    private var geohashTimelines: [String: [BitchatMessage]] = [:]
    private var pendingGeohashSystemMessages: [String] = []

    private let meshCap: Int
    private let geohashCap: Int

    init(meshCap: Int, geohashCap: Int) {
        self.meshCap = meshCap
        self.geohashCap = geohashCap
    }

    func activate(channel: ChannelID) {
        activeChannel = channel
        visibleMessages = messages(for: channel)
    }

    func append(_ message: BitchatMessage, to channel: ChannelID) {
        switch channel {
        case .mesh:
            guard !meshTimeline.contains(where: { $0.id == message.id }) else { return }
            meshTimeline.append(message)
            trimMeshTimelineIfNeeded()
        case .location(let channel):
            append(message, toGeohash: channel.geohash)
        }
    }

    func append(_ message: BitchatMessage, toGeohash geohash: String) {
        var timeline = geohashTimelines[geohash] ?? []
        guard !timeline.contains(where: { $0.id == message.id }) else { return }
        timeline.append(message)
        trimGeohashTimelineIfNeeded(&timeline)
        geohashTimelines[geohash] = timeline
    }

    @discardableResult
    func appendIfAbsent(_ message: BitchatMessage, toGeohash geohash: String) -> Bool {
        var timeline = geohashTimelines[geohash] ?? []
        guard !timeline.contains(where: { $0.id == message.id }) else { return false }
        timeline.append(message)
        trimGeohashTimelineIfNeeded(&timeline)
        geohashTimelines[geohash] = timeline
        return true
    }

    func messages(for channel: ChannelID) -> [BitchatMessage] {
        switch channel {
        case .mesh:
            return meshTimeline
        case .location(let channel):
            let cleaned = geohashTimelines[channel.geohash]?.cleanedAndDeduped() ?? []
            geohashTimelines[channel.geohash] = cleaned
            return cleaned
        }
    }

    func refreshVisibleMessages(from channel: ChannelID? = nil) {
        let target = channel ?? activeChannel
        activeChannel = target
        visibleMessages = messages(for: target)
    }

    func setVisibleMessages(_ messages: [BitchatMessage]) {
        visibleMessages = messages
    }

    func trimVisibleMessages(to limit: Int) {
        guard visibleMessages.count > limit else { return }
        visibleMessages = Array(visibleMessages.suffix(limit))
    }

    func clear(channel: ChannelID) {
        switch channel {
        case .mesh:
            meshTimeline.removeAll()
        case .location(let channel):
            geohashTimelines[channel.geohash] = []
        }

        if channel == activeChannel {
            visibleMessages.removeAll()
        }
    }

    func clearAll() {
        meshTimeline.removeAll()
        geohashTimelines.removeAll()
        pendingGeohashSystemMessages.removeAll()
        visibleMessages.removeAll()
    }

    @discardableResult
    func removeMessage(withID id: String) -> BitchatMessage? {
        if let index = visibleMessages.firstIndex(where: { $0.id == id }) {
            _ = visibleMessages.remove(at: index)
        }

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

    func removeMessages(in geohash: String, where predicate: (BitchatMessage) -> Bool) {
        var timeline = geohashTimelines[geohash] ?? []
        timeline.removeAll(where: predicate)
        geohashTimelines[geohash] = timeline.isEmpty ? nil : timeline

        if case .location(let channel) = activeChannel, channel.geohash == geohash {
            visibleMessages.removeAll(where: predicate)
        }
    }

    func mutateGeohash(_ geohash: String, _ transform: (inout [BitchatMessage]) -> Void) {
        var timeline = geohashTimelines[geohash] ?? []
        transform(&timeline)
        geohashTimelines[geohash] = timeline.isEmpty ? nil : timeline

        if case .location(let channel) = activeChannel, channel.geohash == geohash {
            visibleMessages = messages(for: activeChannel)
        }
    }

    func queueGeohashSystemMessage(_ content: String) {
        pendingGeohashSystemMessages.append(content)
    }

    func drainPendingGeohashSystemMessages() -> [String] {
        defer { pendingGeohashSystemMessages.removeAll(keepingCapacity: false) }
        return pendingGeohashSystemMessages
    }

    func geohashKeys() -> [String] {
        Array(geohashTimelines.keys)
    }

    @discardableResult
    func updateMessage(id: String, transform: (BitchatMessage) -> BitchatMessage) -> Bool {
        var updated = false

        if let index = meshTimeline.firstIndex(where: { $0.id == id }) {
            meshTimeline[index] = transform(meshTimeline[index])
            updated = true
        }

        for key in Array(geohashTimelines.keys) {
            guard var timeline = geohashTimelines[key],
                  let index = timeline.firstIndex(where: { $0.id == id }) else {
                continue
            }
            timeline[index] = transform(timeline[index])
            geohashTimelines[key] = timeline
            updated = true
        }

        if let index = visibleMessages.firstIndex(where: { $0.id == id }) {
            visibleMessages[index] = transform(visibleMessages[index])
            updated = true
        }

        return updated
    }

    private func trimMeshTimelineIfNeeded() {
        guard meshTimeline.count > meshCap else { return }
        meshTimeline = Array(meshTimeline.suffix(meshCap))
    }

    private func trimGeohashTimelineIfNeeded(_ timeline: inout [BitchatMessage]) {
        guard timeline.count > geohashCap else { return }
        timeline = Array(timeline.suffix(geohashCap))
    }
}
