//
// VideoStreamAssembler.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Output of `VideoStreamAssembler`, in decode order per track.
enum LiveVideoOutput: Equatable {
    case config(LiveVideoConfig)
    /// A decodable video access unit: a keyframe, or a delta frame whose
    /// references all arrived.
    case video(sequence: Int64, ptsMs: Int64, keyframe: Bool, data: Data)
    case audio(sequence: Int64, ptsMs: Int64, data: Data)
    /// Video units that were lost (or undecodable after a loss) and skipped.
    case videoSkipped(Int)
    case ended(durationMs: Int64)
    case canceled
}

struct LiveVideoReceiveStats: Equatable {
    let packets: Int
    let bytes: Int64
    let recoveredShards: Int
    let videoUnits: Int
    let audioUnits: Int
    let skippedVideoUnits: Int
    /// Packet loss over the most recent sequence window, 0.0...1.0.
    let recentLoss: Double
}

/// Receiver state machine for one live video stream. Pure logic; the caller
/// supplies time.
///
/// Packets may arrive duplicated, reordered, or not at all. Source shards are
/// parsed the moment they arrive; parity rebuilds lost shards once any `k`
/// symbols of a block are present. Units are released per track in sequence
/// order. A gap is skipped after `gapMs`; a skipped video unit breaks the
/// reference chain, so delta frames are withheld until the next keyframe (the
/// player freezes on the last good picture instead of showing corruption).
///
/// Not thread-safe — confine to one queue.
final class VideoStreamAssembler {
    private static let maxTrackedBlocks = 48
    private static let maxPendingUnits = 192
    private static let maxReadyUnits = 192
    private static let lossWindow = 128

    private final class BlockState {
        var sources: [Int: Data] = [:]
        var parities: [Int: Data] = [:]
        var sourceCount: Int?
        var parityCount: Int?
        var complete = false
    }

    private final class PendingUnit {
        let keyframe: Bool
        let ptsMs: Int64
        let count: Int
        var fragments: [Data?]
        var received = 0
        var bytes = 0

        init(keyframe: Bool, ptsMs: Int64, count: Int) {
            self.keyframe = keyframe
            self.ptsMs = ptsMs
            self.count = count
            self.fragments = Array(repeating: nil, count: count)
        }
    }

    private struct ReadyUnit {
        let ptsMs: Int64
        let keyframe: Bool
        let data: Data
    }

    private final class TrackState {
        var pending: [Int64: PendingUnit] = [:]
        /// Insertion order of `pending`, so the oldest unit is evicted first.
        var pendingOrder: [Int64] = []
        var ready: [Int64: ReadyUnit] = [:]
        var next: Int64?
        var lastReference: Int64?
        var gapSinceMs: Int64?
        var released = 0

        func removePending(_ sequence: Int64) {
            guard pending.removeValue(forKey: sequence) != nil else { return }
            pendingOrder.removeAll { $0 == sequence }
        }

        func removePending(below target: Int64) {
            pendingOrder.removeAll { $0 < target }
            pending = pending.filter { $0.key >= target }
        }
    }

    /// Longer than the widest FEC block window plus relay jitter, so parity can still land.
    private let gapMs: Int64
    private let maxUnitBytes: Int

    private var blocks: [Int: BlockState] = [:]
    private var blockOrder: [Int] = []
    private let tracks: [TrackState] = LiveVideoTrack.allCases.map { _ in TrackState() }
    private var lastConfig: LiveVideoConfig?
    private var videoChainBroken = true
    private var expectedUnits: [LiveVideoTrack: Int]?
    private var endDurationMs: Int64?
    private var finished = false

    private var packets = 0
    private var bytes: Int64 = 0
    private var recoveredShards = 0
    private var skippedVideo = 0
    private var highestSequence: Int64?
    private var recentSequences: [Int64] = []
    private var recentSet = Set<Int64>()

    init(gapMs: Int64 = 900, maxUnitBytes: Int = 256 * 1024) {
        self.gapMs = gapMs
        self.maxUnitBytes = maxUnitBytes
    }

    var config: LiveVideoConfig? { lastConfig }
    /// The sender's END arrived; anything still missing is tail loss, not a pause.
    var endReceived: Bool { expectedUnits != nil }
    var isFinished: Bool { finished }

    func stats() -> LiveVideoReceiveStats {
        var loss = 0.0
        if let high = highestSequence {
            let window = min(Int64(Self.lossWindow), high + 1)
            let seen = recentSet.filter { $0 > high - window }.count
            loss = min(max(1.0 - Double(seen) / Double(window), 0.0), 1.0)
        }
        return LiveVideoReceiveStats(
            packets: packets,
            bytes: bytes,
            recoveredShards: recoveredShards,
            videoUnits: trackState(.video).released,
            audioUnits: trackState(.audio).released,
            skippedVideoUnits: skippedVideo,
            recentLoss: loss
        )
    }

    func onPacket(_ packet: VideoBurstPacket, sizeBytes: Int, nowMs: Int64) -> [LiveVideoOutput] {
        if finished { return [] }
        packets += 1
        bytes += Int64(sizeBytes)
        recordSequence(packet.sequence)
        var output: [LiveVideoOutput] = []
        switch packet.kind {
        case .start(let config):
            if config != lastConfig {
                lastConfig = config
                output.append(.config(config))
            }
        case .data(let block, let index, let region):
            onData(block: block, index: index, region: region, nowMs: nowMs)
        case .parity(let block, let parityIndex, let sourceCount, let parityCount, let symbol):
            onParity(
                block: block,
                parityIndex: parityIndex,
                sourceCount: sourceCount,
                parityCount: parityCount,
                symbol: symbol,
                nowMs: nowMs
            )
        case .end(let durationMs, let videoUnits, let audioUnits, _):
            expectedUnits = [.video: videoUnits, .audio: audioUnits]
            endDurationMs = durationMs
        case .canceled:
            finished = true
            return [.canceled]
        }
        output += release(nowMs: nowMs)
        return output
    }

    /// Skips gaps whose deadline passed; call periodically.
    func onTick(nowMs: Int64) -> [LiveVideoOutput] {
        finished ? [] : release(nowMs: nowMs)
    }

    /// Releases everything buffered (skipping open gaps) without ending the
    /// stream, so a viewer whose link went quiet keeps all it received and can
    /// carry on when packets return.
    func drain() -> [LiveVideoOutput] {
        finished ? [] : release(nowMs: .max)
    }

    /// Forces every buffered unit out (skipping all gaps) and ends the stream.
    func flush() -> [LiveVideoOutput] {
        if finished { return [] }
        var output = release(nowMs: .max)
        // release() may already have ended the stream if END's totals were met.
        if !finished {
            finished = true
            output.append(.ended(durationMs: endDurationMs ?? 0))
        }
        return output
    }

    // MARK: - Blocks

    private func onData(block: Int, index: Int, region: Data, nowMs: Int64) {
        let state = blockState(block)
        if state.complete || state.sources[index] != nil { return }
        if let limit = state.sourceCount, index >= limit { return }
        state.sources[index] = region
        ingestRegion(region, nowMs: nowMs)
        tryRecover(state, nowMs: nowMs)
    }

    private func onParity(
        block: Int,
        parityIndex: Int,
        sourceCount: Int,
        parityCount: Int,
        symbol: Data,
        nowMs: Int64
    ) {
        let state = blockState(block)
        if state.complete { return }
        if let knownK = state.sourceCount,
           knownK != sourceCount || state.parityCount != parityCount {
            return
        }
        if let existing = state.parities.values.first, existing.count != symbol.count { return }
        if state.sources.keys.contains(where: { $0 >= sourceCount }) { return }
        state.sourceCount = sourceCount
        state.parityCount = parityCount
        if state.parities[parityIndex] == nil { state.parities[parityIndex] = symbol }
        tryRecover(state, nowMs: nowMs)
    }

    private func tryRecover(_ state: BlockState, nowMs: Int64) {
        guard let k = state.sourceCount else { return }
        if state.sources.count >= k {
            state.complete = true
            return
        }
        guard state.sources.count + state.parities.count >= k,
              let symbolLength = state.parities.values.first?.count
        else { return }
        if state.sources.values.contains(where: { $0.count + 2 > symbolLength }) {
            state.complete = true
            return
        }
        let slots: [Data?] = (0..<k).map { index in
            state.sources[index].map { LiveVideoSymbols.symbol($0, length: symbolLength) }
        }
        let rebuilt = ReedSolomonErasure.reconstruct(slots, parities: state.parities)
        state.complete = true
        guard let rebuilt else { return }
        for index in 0..<k where state.sources[index] == nil {
            guard let region = LiveVideoSymbols.region(rebuilt[index]) else { continue }
            state.sources[index] = region
            recoveredShards += 1
            ingestRegion(region, nowMs: nowMs)
        }
    }

    private func blockState(_ block: Int) -> BlockState {
        if let state = blocks[block] { return state }
        while blocks.count >= Self.maxTrackedBlocks, let oldest = blockOrder.first {
            blockOrder.removeFirst()
            blocks.removeValue(forKey: oldest)
        }
        let state = BlockState()
        blocks[block] = state
        blockOrder.append(block)
        return state
    }

    // MARK: - Units

    private func ingestRegion(_ region: Data, nowMs: Int64) {
        guard let entries = LiveVideoEntry.decodeAll(region) else { return }
        for entry in entries { ingestEntry(entry, nowMs: nowMs) }
    }

    private func ingestEntry(_ entry: LiveVideoEntry, nowMs: Int64) {
        let track = trackState(entry.track)
        let reference = track.next ?? track.lastReference ?? Int64(entry.unitSequence)
        let sequence = Self.expand(entry.unitSequence, reference: reference)
        if let next = track.next, sequence < next { return }
        if track.ready[sequence] != nil { return }
        let pending: PendingUnit
        if let existing = track.pending[sequence] {
            pending = existing
        } else {
            if track.pending.count >= Self.maxPendingUnits, let oldest = track.pendingOrder.first {
                track.removePending(oldest)
            }
            pending = PendingUnit(keyframe: entry.keyframe, ptsMs: entry.ptsMs, count: entry.fragmentCount)
            track.pending[sequence] = pending
            track.pendingOrder.append(sequence)
        }
        if pending.count != entry.fragmentCount || pending.keyframe != entry.keyframe { return }
        if pending.fragments[entry.fragmentIndex] != nil { return }
        pending.bytes += entry.bytes.count
        if pending.bytes > maxUnitBytes {
            track.removePending(sequence)
            return
        }
        pending.fragments[entry.fragmentIndex] = entry.bytes
        pending.received += 1
        if pending.received < pending.count { return }
        track.removePending(sequence)
        var data = Data(capacity: pending.bytes)
        for fragment in pending.fragments {
            data.append(fragment!)
        }
        if track.next == nil {
            track.next = sequence
        }
        track.lastReference = sequence
        track.ready[sequence] = ReadyUnit(ptsMs: pending.ptsMs, keyframe: pending.keyframe, data: data)
        if track.ready.count > Self.maxReadyUnits, let oldest = track.ready.keys.min() {
            // A runaway backlog means the head gap will never fill; skip to the oldest ready unit.
            _ = skip(entry.track, track, to: oldest)
        }
    }

    private func release(nowMs: Int64) -> [LiveVideoOutput] {
        var output: [LiveVideoOutput] = []
        for type in LiveVideoTrack.allCases {
            let track = trackState(type)
            while let next = track.next {
                if let unit = track.ready.removeValue(forKey: next) {
                    track.gapSinceMs = nil
                    track.next = next + 1
                    track.released += 1
                    emit(type, sequence: next, unit: unit, into: &output)
                    continue
                }
                guard let target = track.ready.keys.min() else {
                    track.gapSinceMs = nil
                    break
                }
                let since = track.gapSinceMs ?? nowMs
                track.gapSinceMs = since
                if nowMs == .max || nowMs &- since >= gapMs {
                    let skipped = skip(type, track, to: target)
                    if type == .video && skipped > 0 { output.append(.videoSkipped(skipped)) }
                    track.gapSinceMs = nil
                    continue
                }
                break
            }
        }
        if let expected = expectedUnits, !finished {
            let done = expected.allSatisfy { type, total in
                guard total != 0 else { return true }
                guard let next = trackState(type).next else { return false }
                return next >= Self.expandCount(total, reference: next)
            }
            if done {
                finished = true
                output.append(.ended(durationMs: endDurationMs ?? 0))
            }
        }
        return output
    }

    private func emit(_ type: LiveVideoTrack, sequence: Int64, unit: ReadyUnit, into output: inout [LiveVideoOutput]) {
        switch type {
        case .audio:
            output.append(.audio(sequence: sequence, ptsMs: unit.ptsMs, data: unit.data))
        case .video:
            if unit.keyframe { videoChainBroken = false }
            if videoChainBroken {
                skippedVideo += 1
                output.append(.videoSkipped(1))
            } else {
                output.append(.video(sequence: sequence, ptsMs: unit.ptsMs, keyframe: unit.keyframe, data: unit.data))
            }
        }
    }

    private func skip(_ type: LiveVideoTrack, _ track: TrackState, to target: Int64) -> Int {
        guard let next = track.next else { return 0 }
        let skipped = Int(max(target - next, 0))
        if skipped > 0 {
            track.removePending(below: target)
            if type == .video {
                videoChainBroken = true
                skippedVideo += skipped
            }
        }
        track.next = target
        return skipped
    }

    private func trackState(_ type: LiveVideoTrack) -> TrackState {
        tracks[Int(type.rawValue)]
    }

    // MARK: - Sequence numbers

    private func recordSequence(_ sequence: Int) {
        let expanded = Self.expand(sequence, reference: highestSequence ?? Int64(sequence))
        guard recentSet.insert(expanded).inserted else { return }
        recentSequences.append(expanded)
        if highestSequence.map({ expanded > $0 }) ?? true { highestSequence = expanded }
        while recentSequences.count > Self.lossWindow {
            recentSet.remove(recentSequences.removeFirst())
        }
    }

    /// Maps a 16-bit wire counter to the 64-bit value closest to `reference`.
    static func expand(_ value: Int, reference: Int64) -> Int64 {
        let base = reference - (reference & 0xFFFF)
        var candidate = base + Int64(value)
        if candidate - reference > 0x8000 { candidate -= 0x10000 }
        if reference - candidate > 0x8000 { candidate += 0x10000 }
        return candidate
    }

    /// END counts units (not sequence numbers); a count of N means sequences 0..<N.
    static func expandCount(_ count: Int, reference: Int64) -> Int64 {
        let base = reference - (reference & 0xFFFF)
        var candidate = base + Int64(count)
        if candidate < reference - 0x8000 { candidate += 0x10000 }
        return candidate
    }
}
