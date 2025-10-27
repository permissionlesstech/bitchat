//
// PublicMessagePipeline.swift
// bitchat
//
// Handles batching and deduplication of public chat messages before surfacing them to the UI.
//

import Foundation

@MainActor
protocol PublicMessagePipelineDelegate: AnyObject {
    func pipelineCurrentMessages(_ pipeline: PublicMessagePipeline) -> [BitchatMessage]
    func pipeline(_ pipeline: PublicMessagePipeline, setMessages messages: [BitchatMessage])
    func pipeline(_ pipeline: PublicMessagePipeline, normalizeContent content: String) -> String
    func pipeline(_ pipeline: PublicMessagePipeline, contentTimestampForKey key: String) -> Date?
    func pipeline(_ pipeline: PublicMessagePipeline, recordContentKey key: String, timestamp: Date)
    func pipelineTrimMessages(_ pipeline: PublicMessagePipeline)
    func pipelinePrewarmMessage(_ pipeline: PublicMessagePipeline, message: BitchatMessage)
    func pipelineSetBatchingState(_ pipeline: PublicMessagePipeline, isBatching: Bool)
}

@MainActor
final class PublicMessagePipeline {
    weak var delegate: PublicMessagePipelineDelegate?

    private var buffer: [BitchatMessage] = []
    private var timer: Timer?
    private let baseFlushInterval: TimeInterval
    private var dynamicFlushInterval: TimeInterval
    private var recentBatchSizes: [Int] = []
    private let maxRecentBatchSamples: Int
    private let dedupWindow: TimeInterval
    private var activeChannel: ChannelID = .mesh

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

    func updateActiveChannel(_ channel: ChannelID) {
        activeChannel = channel
    }

    func enqueue(_ message: BitchatMessage) {
        buffer.append(message)
        scheduleFlush()
    }

    func flushIfNeeded() {
        flushBuffer()
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        buffer.removeAll(keepingCapacity: false)
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

        var existingIDs = Set(delegate.pipelineCurrentMessages(self).map { $0.id })
        var pending: [(message: BitchatMessage, contentKey: String)] = []
        var batchContentLatest: [String: Date] = [:]

        for message in buffer {
            if existingIDs.contains(message.id) { continue }
            let contentKey = delegate.pipeline(self, normalizeContent: message.content)
            if let ts = delegate.pipeline(self, contentTimestampForKey: contentKey),
               abs(ts.timeIntervalSince(message.timestamp)) < dedupWindow {
                continue
            }
            if let ts = batchContentLatest[contentKey],
               abs(ts.timeIntervalSince(message.timestamp)) < dedupWindow {
                continue
            }
            existingIDs.insert(message.id)
            pending.append((message, contentKey))
            batchContentLatest[contentKey] = message.timestamp
        }

        buffer.removeAll(keepingCapacity: true)
        guard !pending.isEmpty else {
            delegate.pipelineSetBatchingState(self, isBatching: false)
            if !buffer.isEmpty { scheduleFlush() }
            return
        }

        pending.sort { $0.message.timestamp < $1.message.timestamp }

        var messages = delegate.pipelineCurrentMessages(self)
        let threshold = lateInsertThreshold(for: activeChannel)
        let lastTimestamp = messages.last?.timestamp ?? .distantPast

        for item in pending {
            let message = item.message
            if threshold == 0 || message.timestamp < lastTimestamp.addingTimeInterval(-threshold) {
                let index = insertionIndex(for: message.timestamp, in: messages)
                if index >= messages.count {
                    messages.append(message)
                } else {
                    messages.insert(message, at: index)
                }
            } else {
                messages.append(message)
            }
            delegate.pipeline(self, recordContentKey: item.contentKey, timestamp: message.timestamp)
        }

        delegate.pipeline(self, setMessages: messages)
        delegate.pipelineTrimMessages(self)

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

    func lateInsertThreshold(for channel: ChannelID) -> TimeInterval {
        switch channel {
        case .mesh:
            return TransportConfig.uiLateInsertThreshold
        case .location:
            return TransportConfig.uiLateInsertThresholdGeo
        }
    }

    func insertionIndex(for timestamp: Date, in messages: [BitchatMessage]) -> Int {
        var low = 0
        var high = messages.count
        while low < high {
            let mid = (low + high) / 2
            if messages[mid].timestamp < timestamp {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
