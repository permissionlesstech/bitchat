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
    /// Commits a batch of messages to one conversation in a single store
    /// mutation so a crowded-room burst triggers one SwiftUI publish instead
    /// of one per message. Returns the messages actually inserted.
    @discardableResult
    func pipeline(
        _: PublicMessagePipeline,
        commitBatch messages: [BitchatMessage],
        to conversationID: ConversationID
    ) -> [BitchatMessage]
    func pipelinePrewarmMessage(_: PublicMessagePipeline, message: BitchatMessage)
}

extension PublicMessagePipelineDelegate {
    func pipeline(
        _ pipeline: PublicMessagePipeline,
        commitBatch messages: [BitchatMessage],
        to conversationID: ConversationID
    ) -> [BitchatMessage] {
        messages.filter { self.pipeline(pipeline, commit: $0, to: conversationID) }
    }
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

    /// Panic-wipe hook: cancels any scheduled batch flush and drops all
    /// uncommitted public messages so pre-wipe traffic cannot resurface.
    func reset() {
        timer?.invalidate()
        timer = nil
        buffer.removeAll(keepingCapacity: false)
        recentBatchSizes.removeAll(keepingCapacity: false)
        dynamicFlushInterval = baseFlushInterval
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
        guard !pending.isEmpty else { return }

        if pending.count > 1 {
            var needsSort = false
            for idx in 1..<pending.count where pending[idx].message.timestamp < pending[idx - 1].message.timestamp {
                needsSort = true
                break
            }
            if needsSort {
                pending.sort { $0.message.timestamp < $1.message.timestamp }
            }
        }

        // Commit contiguous same-conversation runs in one store write each so
        // crowded-room bursts trigger a single SwiftUI publish per flush.
        var committedMessages: [BitchatMessage] = []
        committedMessages.reserveCapacity(pending.count)
        var runStart = 0
        while runStart < pending.count {
            let convID = pending[runStart].conversationID
            var runEnd = runStart + 1
            while runEnd < pending.count, pending[runEnd].conversationID == convID {
                runEnd += 1
            }

            let run = pending[runStart..<runEnd]
            let inserted = delegate.pipeline(
                self,
                commitBatch: run.map(\.message),
                to: convID
            )
            if !inserted.isEmpty {
                if inserted.count == run.count {
                    for item in run {
                        delegate.pipeline(self, recordContentKey: item.contentKey, timestamp: item.message.timestamp)
                    }
                } else {
                    let insertedIDs = Set(inserted.map(\.id))
                    for item in run where insertedIDs.contains(item.message.id) {
                        delegate.pipeline(self, recordContentKey: item.contentKey, timestamp: item.message.timestamp)
                    }
                }
                committedMessages.append(contentsOf: inserted)
            }
            runStart = runEnd
        }

        updateFlushInterval(withBatchSize: pending.count)

        // Prewarm only the tail rows visible near the bottom viewport so a
        // sudden history-replay burst never stalls the main thread formatting
        // hundreds of off-screen rows.
        for message in committedMessages.suffix(TransportConfig.uiBatchPrewarmLimit) {
            delegate.pipelinePrewarmMessage(self, message: message)
        }

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
