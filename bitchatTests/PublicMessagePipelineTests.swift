//
// PublicMessagePipelineTests.swift
// bitchatTests
//
// Tests for PublicMessagePipeline batching, content dedup, and per-message
// conversation routing. Ordering and ID dedup live in the ConversationStore
// the flush commits into (the old late-insert threshold is gone; see
// ConversationStoreTests for ordered-insert coverage).
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

@MainActor
private final class TestPipelineDelegate: PublicMessagePipelineDelegate {
    private let dedupService = MessageDeduplicationService()
    /// Commits in arrival-at-commit order, per conversation.
    private(set) var committed: [(message: BitchatMessage, conversationID: ConversationID)] = []
    /// Message IDs the commit rejects (simulates the store's ID dedup).
    var rejectedMessageIDs: Set<String> = []
    private(set) var recordedContentKeys: [String] = []

    func messages(in conversationID: ConversationID) -> [BitchatMessage] {
        committed.filter { $0.conversationID == conversationID }.map(\.message)
    }

    func pipeline(_: PublicMessagePipeline, contentKeyFor content: String, in conversationID: ConversationID) -> String {
        dedupService.contentKey(content, in: conversationID)
    }

    func pipeline(_: PublicMessagePipeline, contentTimestampForKey key: String) -> Date? {
        dedupService.contentTimestamp(forKey: key)
    }

    func pipeline(_: PublicMessagePipeline, recordContentKey key: String, timestamp: Date) {
        dedupService.recordContentKey(key, timestamp: timestamp)
        recordedContentKeys.append(key)
    }

    func pipeline(_: PublicMessagePipeline, commit message: BitchatMessage, to conversationID: ConversationID) -> Bool {
        guard !rejectedMessageIDs.contains(message.id) else { return false }
        committed.append((message, conversationID))
        return true
    }

    func pipelinePrewarmMessage(_: PublicMessagePipeline, message: BitchatMessage) {}
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

struct PublicMessagePipelineTests {

    @Test @MainActor
    func flush_commitsInTimestampOrder() async {
        let pipeline = PublicMessagePipeline()
        let delegate = TestPipelineDelegate()
        pipeline.delegate = delegate

        let earlier = Date().addingTimeInterval(-10)
        let later = Date()

        pipeline.enqueue(makeMessage(id: "a", content: "Later", timestamp: later), to: .mesh)
        pipeline.enqueue(makeMessage(id: "b", content: "Earlier", timestamp: earlier), to: .mesh)
        pipeline.flushIfNeeded()

        #expect(delegate.messages(in: .mesh).map { $0.id } == ["b", "a"])
    }

    @Test @MainActor
    func flush_deduplicatesByContentWithinWindow() async {
        let pipeline = PublicMessagePipeline()
        let delegate = TestPipelineDelegate()
        pipeline.delegate = delegate

        let now = Date()
        pipeline.enqueue(makeMessage(id: "a", content: "Same", timestamp: now), to: .mesh)
        pipeline.enqueue(makeMessage(id: "b", content: "Same", timestamp: now.addingTimeInterval(0.2)), to: .mesh)
        pipeline.flushIfNeeded()

        #expect(delegate.messages(in: .mesh).count == 1)
        #expect(delegate.messages(in: .mesh).first?.content == "Same")
    }

    /// The split layout shows #mesh beside a geohash: the same short text
    /// arriving in both within the window is two messages, not a duplicate.
    @Test @MainActor
    func flush_sameContentInTwoConversationsWithinWindow_commitsBoth() async {
        let pipeline = PublicMessagePipeline()
        let delegate = TestPipelineDelegate()
        pipeline.delegate = delegate

        let now = Date()
        pipeline.enqueue(makeMessage(id: "mesh-gm", content: "gm", timestamp: now), to: .mesh)
        pipeline.enqueue(makeMessage(id: "geo-gm", content: "gm", timestamp: now.addingTimeInterval(0.2)), to: .geohash("u4pruydq"))
        pipeline.flushIfNeeded()

        #expect(delegate.messages(in: .mesh).map(\.id) == ["mesh-gm"])
        #expect(delegate.messages(in: .geohash("u4pruydq")).map(\.id) == ["geo-gm"])
    }

    /// Within one conversation the window still holds, in a batch and
    /// across flushes.
    @Test @MainActor
    func flush_sameContentTwiceInOneConversationWithinWindow_dedups() async {
        let pipeline = PublicMessagePipeline()
        let delegate = TestPipelineDelegate()
        pipeline.delegate = delegate

        let now = Date()
        pipeline.enqueue(makeMessage(id: "gm-1", content: "gm", timestamp: now), to: .mesh)
        pipeline.flushIfNeeded()
        pipeline.enqueue(makeMessage(id: "gm-2", content: "GM", timestamp: now.addingTimeInterval(0.3)), to: .mesh)
        pipeline.flushIfNeeded()

        #expect(delegate.messages(in: .mesh).map(\.id) == ["gm-1"])
    }

    /// A marker committed for one conversation (e.g. the #mesh row of an
    /// earlier flush) does not suppress the same text in another one.
    @Test @MainActor
    func flush_markerFromAnotherConversation_doesNotSuppressArrival() async {
        let pipeline = PublicMessagePipeline()
        let delegate = TestPipelineDelegate()
        pipeline.delegate = delegate

        let now = Date()
        pipeline.enqueue(makeMessage(id: "mesh-wave", content: "👋", timestamp: now), to: .mesh)
        pipeline.flushIfNeeded()
        pipeline.enqueue(makeMessage(id: "geo-wave", content: "👋", timestamp: now.addingTimeInterval(0.5)), to: .geohash("u4pruydq"))
        pipeline.flushIfNeeded()

        #expect(delegate.messages(in: .mesh).map(\.id) == ["mesh-wave"])
        #expect(delegate.messages(in: .geohash("u4pruydq")).map(\.id) == ["geo-wave"])
        #expect(delegate.recordedContentKeys.count == 2)
        #expect(Set(delegate.recordedContentKeys).count == 2)
    }

    @Test @MainActor
    func flush_routesEachMessageToItsConversation() async {
        let pipeline = PublicMessagePipeline()
        let delegate = TestPipelineDelegate()
        pipeline.delegate = delegate

        let base = Date()
        pipeline.enqueue(makeMessage(id: "mesh-1", content: "mesh hello", timestamp: base), to: .mesh)
        // A channel switch mid-batch must not misroute already-buffered messages.
        pipeline.enqueue(makeMessage(id: "geo-1", content: "geo hello", timestamp: base.addingTimeInterval(1)), to: .geohash("u4pruydq"))
        pipeline.flushIfNeeded()

        #expect(delegate.messages(in: .mesh).map { $0.id } == ["mesh-1"])
        #expect(delegate.messages(in: .geohash("u4pruydq")).map { $0.id } == ["geo-1"])
    }

    @Test @MainActor
    func flush_rejectedCommitDoesNotRecordContentKey() async {
        let pipeline = PublicMessagePipeline()
        let delegate = TestPipelineDelegate()
        pipeline.delegate = delegate
        delegate.rejectedMessageIDs = ["dup"]

        pipeline.enqueue(makeMessage(id: "dup", content: "already stored", timestamp: Date()), to: .mesh)
        pipeline.flushIfNeeded()

        #expect(delegate.messages(in: .mesh).isEmpty)
        #expect(delegate.recordedContentKeys.isEmpty)
    }

    @Test @MainActor
    func removeMessage_discardsBridgeAliasBeforeBatchFlush() {
        let pipeline = PublicMessagePipeline()
        let delegate = TestPipelineDelegate()
        pipeline.delegate = delegate

        pipeline.enqueue(makeMessage(id: "bridge-event", content: "same radio payload", timestamp: Date()), to: .mesh)
        pipeline.removeMessage(withID: "bridge-event")
        pipeline.flushIfNeeded()

        #expect(delegate.committed.isEmpty)
        #expect(delegate.recordedContentKeys.isEmpty)
    }

    /// Panic: nothing buffered for either on-screen timeline survives to a
    /// later flush, and the pipeline keeps working afterwards.
    @Test @MainActor
    func discardAll_dropsEveryBufferedMessage() {
        let pipeline = PublicMessagePipeline()
        let delegate = TestPipelineDelegate()
        pipeline.delegate = delegate
        let now = Date()

        pipeline.enqueue(makeMessage(id: "mesh-1", content: "mesh hello", timestamp: now), to: .mesh)
        pipeline.enqueue(makeMessage(id: "geo-1", content: "geo hello", timestamp: now), to: .geohash("u4pruydq"))
        pipeline.discardAll()

        #expect(!pipeline.containsMessage(withID: "mesh-1"))
        #expect(!pipeline.containsMessage(withID: "geo-1"))
        pipeline.flushIfNeeded()
        #expect(delegate.committed.isEmpty)
        #expect(delegate.recordedContentKeys.isEmpty)

        pipeline.enqueue(makeMessage(id: "mesh-2", content: "after the wipe", timestamp: now), to: .mesh)
        pipeline.flushIfNeeded()
        #expect(delegate.messages(in: .mesh).map(\.id) == ["mesh-2"])
    }
}
