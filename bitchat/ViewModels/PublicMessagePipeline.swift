//
// PublicMessagePipeline.swift
// bitchat
//
// Batches visible-channel public messages before committing them to the
// ConversationStore: the deliberate ~80 ms UI flush cadence survives the
// store cutover, while ordering, dedup, and caps live in the store itself
// (its timestamp-ordered insert replaced this pipeline's late-insert
// threshold positioning; see docs/CONVERSATION-STORE-DESIGN.md).
//

import BitFoundation
import Foundation

@MainActor
protocol PublicMessagePipelineDelegate: AnyObject {
    func pipeline(_: PublicMessagePipeline, normalizeContent content: String) -> String
    func pipeline(_: PublicMessagePipeline, contentTimestampForKey key: String) -> Date?
    func pipeline(_: PublicMessagePipeline, recordContentKey key: String, timestamp: Date)
    /// Commits a batched message to its conversation in the store.
    /// Returns `false` when the message was already present (ID dedup).
    @discardableResult
    func pipeline(_: PublicMessagePipeline, commit message: BitchatMessage, to conversationID: ConversationID) -> Bool
    func pipelinePrewarmMessage(_: PublicMessagePipeline, message: BitchatMessage)
    func pipelineSetBatchingState(_: PublicMessagePipeline, isBatching: Bool)
}

@MainActor
final class PublicMessagePipeline {
    weak var delegate: PublicMessagePipelineDelegate?

    private var buffer: [(message: BitchatMessage, conversationID: ConversationID)] = []
    private var timer: Timer?
    private let baseFlushInterval: TimeInterval
    private var dynamicFlushInterval: TimeInterval
    private var recentBatchSizes: [Int] = []
    private let maxRecentBatchSamples: Int
    private let dedupWindow: TimeInterval

    init(
        baseFlushInterval: TimeInterval = TransportConfig.basePublicFlushInterval,
        maxRecentBatchSamples: Int = 10,
        dedupWindow: TimeInterval = 1.0
    ) {
        self.baseFlushInterval = baseFlushInterval
        self.dynamicFlushInterval = baseFlushInterval
        self.maxRecentBatchSamples = maxRecentBatchSamples
        self.dedupWindow = dedupWindow
    }

    deinit {
        timer?.invalidate()
    }

    /// Buffers a message destined for `conversationID`; the next batched
    /// flush commits it to the store. Each entry carries its destination so
    /// a channel switch mid-batch can never misroute buffered messages.
    func enqueue(_ message: BitchatMessage, to conversationID: ConversationID) {
        buffer.append((message, conversationID))
        scheduleFlush()
    }

    /// Discards an uncommitted row by ID. Bridge-first/radio-second dedup uses
    /// this before inserting the authenticated radio copy, so the ~80 ms UI
    /// batch cannot resurrect the replaced bridge alias after store removal.
    func removeMessage(withID messageID: String) {
        buffer.removeAll { $0.message.id == messageID }
        if buffer.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    func containsMessage(withID messageID: String) -> Bool {
        buffer.contains { $0.message.id == messageID }
    }

    func flushIfNeeded() {
        flushBuffer()
    }
}

private extension PublicMessagePipeline {
    func scheduleFlush() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: dynamicFlushInterval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.flushBuffer()
            }
        }
    }

    func flushBuffer() {
        timer?.invalidate()
        timer = nil
        guard !buffer.isEmpty else { return }
        guard let delegate = delegate else {
            buffer.removeAll(keepingCapacity: false)
            return
        }

        delegate.pipelineSetBatchingState(self, isBatching: true)

        // Content-window dedup against recorded keys and within the batch;
        // ID dedup happens in the store at commit time.
        var pending: [(message: BitchatMessage, conversationID: ConversationID, contentKey: String)] = []
        var batchContentLatest: [String: Date] = [:]

        for item in buffer {
            let contentKey = delegate.pipeline(self, normalizeContent: item.message.content)
            if let ts = delegate.pipeline(self, contentTimestampForKey: contentKey),
               abs(ts.timeIntervalSince(item.message.timestamp)) < dedupWindow {
                continue
            }
            if let ts = batchContentLatest[contentKey],
               abs(ts.timeIntervalSince(item.message.timestamp)) < dedupWindow {
                continue
            }
            pending.append((item.message, item.conversationID, contentKey))
            batchContentLatest[contentKey] = item.message.timestamp
        }

        buffer.removeAll(keepingCapacity: true)
        guard !pending.isEmpty else {
            delegate.pipelineSetBatchingState(self, isBatching: false)
            return
        }

        pending.sort { $0.message.timestamp < $1.message.timestamp }

        for item in pending {
            guard delegate.pipeline(self, commit: item.message, to: item.conversationID) else { continue }
            delegate.pipeline(self, recordContentKey: item.contentKey, timestamp: item.message.timestamp)
        }

        updateFlushInterval(withBatchSize: pending.count)

        for item in pending {
            delegate.pipelinePrewarmMessage(self, message: item.message)
        }

        delegate.pipelineSetBatchingState(self, isBatching: false)

        if !buffer.isEmpty {
            scheduleFlush()
        }
    }

    func updateFlushInterval(withBatchSize size: Int) {
        recentBatchSizes.append(size)
        if recentBatchSizes.count > maxRecentBatchSamples {
            recentBatchSizes.removeFirst(recentBatchSizes.count - maxRecentBatchSamples)
        }
        let avg = recentBatchSizes.isEmpty
            ? 0.0
            : Double(recentBatchSizes.reduce(0, +)) / Double(recentBatchSizes.count)
        dynamicFlushInterval = avg > 100.0 ? 0.12 : baseFlushInterval
    }
}
