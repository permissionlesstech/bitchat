//
// PublicMessagePipelineBatchTests.swift
// bitchatTests
//
// Tests for the batch commit in PublicMessagePipeline's flush: one
// `commitBatch` call per same-conversation run, content keys only for the
// messages the store inserted, and prewarm only for the newest inserted
// messages.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

/// Implements `commitBatch` itself, as the production coordinator does, so
/// the flush never falls back to the per-message `commit` default.
@MainActor
private final class BatchRecordingDelegate: PublicMessagePipelineDelegate {
    private let dedupService = MessageDeduplicationService()
    /// Message IDs the store rejects (simulates its ID dedup).
    var rejectedMessageIDs: Set<String> = []
    /// Each `commitBatch` call: its conversation and the IDs it was given.
    private(set) var batchCalls: [(conversationID: ConversationID, messageIDs: [String])] = []
    private(set) var committed: [(message: BitchatMessage, conversationID: ConversationID)] = []
    private(set) var prewarmedMessageIDs: [String] = []

    func messageIDs(in conversationID: ConversationID) -> [String] {
        committed.filter { $0.conversationID == conversationID }.map(\.message.id)
    }

    func pipeline(_: PublicMessagePipeline, normalizeContent content: String) -> String {
        dedupService.normalizedContentKey(content)
    }

    func pipeline(_: PublicMessagePipeline, contentTimestampForKey key: String) -> Date? {
        dedupService.contentTimestamp(forKey: key)
    }

    func pipeline(_: PublicMessagePipeline, recordContentKey key: String, timestamp: Date) {
        dedupService.recordContentKey(key, timestamp: timestamp)
    }

    func pipeline(_: PublicMessagePipeline, commit message: BitchatMessage, to conversationID: ConversationID) -> Bool {
        Issue.record("The flush commits through commitBatch, not commit")
        return false
    }

    func pipeline(
        _: PublicMessagePipeline,
        commitBatch messages: [BitchatMessage],
        to conversationID: ConversationID
    ) -> [BitchatMessage] {
        batchCalls.append((conversationID, messages.map(\.id)))
        let inserted = messages.filter { !rejectedMessageIDs.contains($0.id) }
        committed.append(contentsOf: inserted.map { ($0, conversationID) })
        return inserted
    }

    func pipelinePrewarmMessage(_: PublicMessagePipeline, message: BitchatMessage) {
        prewarmedMessageIDs.append(message.id)
    }
}

@MainActor
private func makeMessage(id: String, content: String, timestamp: Date) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: "A",
        content: content,
        timestamp: timestamp,
        isRelay: false
    )
}

struct PublicMessagePipelineBatchTests {

    @Test @MainActor
    func flush_partialInsertRecordsContentKeysOnlyForInsertedMessages() {
        let pipeline = PublicMessagePipeline()
        let delegate = BatchRecordingDelegate()
        pipeline.delegate = delegate
        delegate.rejectedMessageIDs = ["b"]

        let base = Date()
        pipeline.enqueue(makeMessage(id: "a", content: "first", timestamp: base), to: .mesh)
        pipeline.enqueue(makeMessage(id: "b", content: "second", timestamp: base.addingTimeInterval(0.1)), to: .mesh)
        pipeline.enqueue(makeMessage(id: "c", content: "third", timestamp: base.addingTimeInterval(0.2)), to: .mesh)
        pipeline.flushIfNeeded()

        #expect(delegate.batchCalls.map(\.messageIDs) == [["a", "b", "c"]])
        #expect(delegate.messageIDs(in: .mesh) == ["a", "c"])

        // The rejected message left no content key, so a new message with
        // the same text inside the dedup window still lands.
        pipeline.enqueue(makeMessage(id: "d", content: "second", timestamp: base.addingTimeInterval(0.5)), to: .mesh)
        pipeline.flushIfNeeded()

        #expect(delegate.messageIDs(in: .mesh) == ["a", "c", "d"])
    }

    @Test @MainActor
    func flush_commitsEachSameConversationRunInOneBatch() {
        let pipeline = PublicMessagePipeline()
        let delegate = BatchRecordingDelegate()
        pipeline.delegate = delegate
        let geo = ConversationID.geohash("u4pruydq")

        let base = Date()
        pipeline.enqueue(makeMessage(id: "m1", content: "mesh one", timestamp: base), to: .mesh)
        pipeline.enqueue(makeMessage(id: "m2", content: "mesh two", timestamp: base.addingTimeInterval(1)), to: .mesh)
        pipeline.enqueue(makeMessage(id: "g1", content: "geo one", timestamp: base.addingTimeInterval(2)), to: geo)
        pipeline.enqueue(makeMessage(id: "m3", content: "mesh three", timestamp: base.addingTimeInterval(3)), to: .mesh)
        pipeline.flushIfNeeded()

        #expect(delegate.batchCalls.map(\.conversationID) == [.mesh, geo, .mesh])
        #expect(delegate.batchCalls.map(\.messageIDs) == [["m1", "m2"], ["g1"], ["m3"]])
        #expect(delegate.messageIDs(in: .mesh) == ["m1", "m2", "m3"])
        #expect(delegate.messageIDs(in: geo) == ["g1"])
    }

    @Test @MainActor
    func flush_prewarmsOnlyTheNewestInsertedMessages() {
        let pipeline = PublicMessagePipeline()
        let delegate = BatchRecordingDelegate()
        pipeline.delegate = delegate

        let limit = TransportConfig.uiBatchPrewarmLimit
        let ids = (0..<(limit + 5)).map { "msg-\($0)" }
        // The newest message is a duplicate the store rejects: it must not
        // take one of the prewarm slots.
        delegate.rejectedMessageIDs = [ids[ids.count - 1]]

        let base = Date()
        for (index, id) in ids.enumerated() {
            pipeline.enqueue(
                makeMessage(id: id, content: "crowded room line \(index)", timestamp: base.addingTimeInterval(Double(index))),
                to: .mesh
            )
        }
        pipeline.flushIfNeeded()

        let inserted = Array(ids.dropLast())
        #expect(delegate.messageIDs(in: .mesh) == inserted)
        #expect(delegate.prewarmedMessageIDs == Array(inserted.suffix(limit)))
    }
}
