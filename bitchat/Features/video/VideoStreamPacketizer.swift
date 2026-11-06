//
// VideoStreamPacketizer.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// One encoded access unit handed to the packetizer.
struct LiveMediaUnit {
    let track: LiveVideoTrack
    let ptsMs: Int64
    let keyframe: Bool
    let data: Data
}

/// How much Reed-Solomon parity accompanies each block of source shards.
struct LiveVideoFecPolicy: Equatable {
    let parityRatio: Double
    let keyframeParityRatio: Double
    let maxSourceShards: Int
    let shardFlushMs: Int64
    let blockWindowMs: Int64

    init(
        parityRatio: Double,
        keyframeParityRatio: Double,
        maxSourceShards: Int = 12,
        shardFlushMs: Int64 = 150,
        blockWindowMs: Int64 = 400
    ) {
        self.parityRatio = parityRatio
        self.keyframeParityRatio = keyframeParityRatio
        self.maxSourceShards = maxSourceShards
        self.shardFlushMs = shardFlushMs
        self.blockWindowMs = blockWindowMs
    }

    func parityCount(sourceCount: Int, containsKeyframe: Bool) -> Int {
        let ratio = containsKeyframe ? keyframeParityRatio : parityRatio
        if ratio <= 0 { return 0 }
        // Two parity shards from four sources up: one lost delta frame freezes
        // the picture until the next keyframe, so double losses are worth absorbing.
        let floor = sourceCount >= 4 ? 2 : 1
        let count = max(Int((Double(sourceCount) * ratio).rounded(.up)), floor)
        return min(max(count, 1), VideoBurstPacket.maxBlockParityShards)
    }
}

/// FEC symbol framing shared by sender and receiver:
/// `[regionLength: UInt16][region][zero pad]`.
enum LiveVideoSymbols {
    static func symbol(_ region: Data, length: Int) -> Data {
        var symbol = Data(capacity: length)
        symbol.append(UInt8((region.count >> 8) & 0xFF))
        symbol.append(UInt8(region.count & 0xFF))
        symbol.append(region)
        if symbol.count < length {
            symbol.append(Data(count: length - symbol.count))
        }
        return symbol
    }

    static func region(_ symbol: Data) -> Data? {
        let bytes = [UInt8](symbol)
        guard bytes.count >= 2 else { return nil }
        let length = (Int(bytes[0]) << 8) | Int(bytes[1])
        guard length > 0, length <= bytes.count - 2,
              bytes[(2 + length)...].allSatisfy({ $0 == 0 })
        else { return nil }
        return Data(bytes[2..<(2 + length)])
    }
}

/// Turns encoded audio/video units into wire packets.
///
/// Small units are aggregated into one shard, large ones fragmented across
/// shards (in the spirit of RTP STAP-A/FU-A), so every packet is
/// independently parseable and a lost packet only damages the units it
/// carried. Consecutive source shards form a block that is closed by size, by
/// time, or before a keyframe, and then protected by Reed-Solomon parity.
/// Source shards are emitted immediately; parity only costs latency when a
/// shard is actually lost.
///
/// Not thread-safe — one sender queue owns it. Callers supply time.
final class VideoStreamPacketizer {
    /// Do not open a fragment that would carry less than this many bytes.
    private static let minFragmentBytes = 24

    let streamID: Data
    private let config: LiveVideoConfig
    private let fec: LiveVideoFecPolicy
    private let maxEntriesRegion: Int

    private var sequence = 0
    private var block = 0
    private var openEntries: [LiveVideoEntry] = []
    private var openSize = 0
    private var openSinceMs: Int64 = 0
    private var blockSymbols: [Data] = []
    private var blockSinceMs: Int64 = 0
    private var blockHasKeyframe = false
    private var unitSequence = [Int](repeating: 0, count: LiveVideoTrack.allCases.count)
    private var unitCount = [Int](repeating: 0, count: LiveVideoTrack.allCases.count)

    private(set) var packetCount = 0
    private(set) var droppedUnits = 0
    private(set) var parityPackets = 0

    init(
        streamID: Data,
        config: LiveVideoConfig,
        fec: LiveVideoFecPolicy,
        maxEntriesRegion: Int = VideoBurstPacket.maxEntriesRegion
    ) {
        self.streamID = streamID
        self.config = config
        self.fec = fec
        self.maxEntriesRegion = maxEntriesRegion
    }

    func unitsEmitted(_ track: LiveVideoTrack) -> Int {
        unitCount[Int(track.rawValue)]
    }

    func start() -> [Data] {
        packet(.start(config)).map { [$0] } ?? []
    }

    func add(_ unit: LiveMediaUnit, nowMs: Int64) -> [Data] {
        var output: [Data] = []
        if unit.data.isEmpty { return output }
        let bodyBudget = maxEntriesRegion - LiveVideoEntry.headerSize
        if unit.keyframe && unit.track == .video {
            // Give each keyframe its own, more strongly protected block,
            // announced by a repeated START so a viewer joining mid-stream can
            // configure its decoder.
            output += flushShard(nowMs: nowMs)
            output += closeBlock()
            output += start()
        }
        let firstCapacity = maxEntriesRegion - openSize - LiveVideoEntry.headerSize
        let useOpenShard = !openEntries.isEmpty
            && firstCapacity >= min(unit.data.count, Self.minFragmentBytes)
        if !openEntries.isEmpty && !useOpenShard { output += flushShard(nowMs: nowMs) }
        let firstChunk = useOpenShard ? min(firstCapacity, unit.data.count) : min(bodyBudget, unit.data.count)
        let remaining = unit.data.count - firstChunk
        let fragmentCount = 1 + (remaining + bodyBudget - 1) / bodyBudget
        if fragmentCount > 0xFF {
            droppedUnits += 1
            return output
        }
        let trackIndex = Int(unit.track.rawValue)
        let seq = unitSequence[trackIndex]
        unitSequence[trackIndex] = (seq + 1) & 0xFFFF
        unitCount[trackIndex] = min(unitCount[trackIndex] + 1, 0xFFFF)
        let pts = min(max(unit.ptsMs, 0), 0xFFFF_FFFF)
        let bytes = Data(unit.data)
        var offset = 0
        for fragment in 0..<fragmentCount {
            let chunk = fragment == 0 ? firstChunk : min(bodyBudget, bytes.count - offset)
            let entry = LiveVideoEntry(
                track: unit.track,
                keyframe: unit.keyframe,
                unitSequence: seq,
                ptsMs: pts,
                fragmentIndex: fragment,
                fragmentCount: fragmentCount,
                bytes: bytes.subdata(in: offset..<(offset + chunk))
            )
            offset += chunk
            if openEntries.isEmpty { openSinceMs = nowMs }
            openEntries.append(entry)
            openSize += entry.encodedSize
            if unit.keyframe { blockHasKeyframe = true }
            if maxEntriesRegion - openSize < LiveVideoEntry.headerSize + Self.minFragmentBytes {
                output += flushShard(nowMs: nowMs)
            }
        }
        return output
    }

    /// Emits shards and parity whose latency deadlines have passed.
    func tick(nowMs: Int64) -> [Data] {
        var output: [Data] = []
        if !openEntries.isEmpty && nowMs - openSinceMs >= fec.shardFlushMs {
            output += flushShard(nowMs: nowMs)
        }
        if !blockSymbols.isEmpty && nowMs - blockSinceMs >= fec.blockWindowMs {
            output += closeBlock()
        }
        return output
    }

    /// Flushes and emits END. END is repeated (`endCopies`) because a lost END
    /// would leave viewers waiting out their reconnect window; receivers treat
    /// the copies as duplicates.
    func finish(durationMs: Int64, nowMs: Int64, endCopies: Int = 3) -> [Data] {
        var output: [Data] = []
        output += flushShard(nowMs: nowMs)
        output += closeBlock()
        let end = VideoBurstPacket.Kind.end(
            durationMs: min(max(durationMs, 0), 0xFFFF_FFFF),
            videoUnits: unitCount[Int(LiveVideoTrack.video.rawValue)],
            audioUnits: unitCount[Int(LiveVideoTrack.audio.rawValue)],
            packets: min(packetCount, 0xFFFF)
        )
        for _ in 0..<max(endCopies, 1) {
            if let packet = packet(end) { output.append(packet) }
        }
        return output
    }

    func cancel() -> Data? {
        packet(.canceled)
    }

    private func flushShard(nowMs: Int64) -> [Data] {
        if openEntries.isEmpty { return [] }
        let region = VideoBurstPacket.encodeEntries(openEntries)
        openEntries.removeAll()
        openSize = 0
        if blockSymbols.isEmpty { blockSinceMs = nowMs }
        let index = blockSymbols.count
        blockSymbols.append(region)
        var output: [Data] = []
        if let packet = packet(.data(block: block, index: index, entriesRegion: region)) {
            output.append(packet)
        }
        if blockSymbols.count >= min(fec.maxSourceShards, VideoBurstPacket.maxBlockSourceShards) {
            output += closeBlock()
        }
        return output
    }

    private func closeBlock() -> [Data] {
        if blockSymbols.isEmpty { return [] }
        let k = blockSymbols.count
        let r = fec.parityCount(sourceCount: k, containsKeyframe: blockHasKeyframe)
        var output: [Data] = []
        if r > 0 {
            let length = 2 + (blockSymbols.map(\.count).max() ?? 0)
            let symbols = blockSymbols.map { LiveVideoSymbols.symbol($0, length: length) }
            for (row, parity) in ReedSolomonErasure.encode(symbols, parityCount: r).enumerated() {
                let kind = VideoBurstPacket.Kind.parity(
                    block: block,
                    parityIndex: row,
                    sourceCount: k,
                    parityCount: r,
                    symbol: parity
                )
                if let packet = packet(kind) {
                    output.append(packet)
                    parityPackets += 1
                }
            }
        }
        blockSymbols.removeAll()
        blockHasKeyframe = false
        block = (block + 1) & 0xFFFF
        return output
    }

    private func packet(_ kind: VideoBurstPacket.Kind) -> Data? {
        guard let encoded = VideoBurstPacket(streamID: streamID, sequence: sequence, kind: kind)?.encode() else {
            return nil
        }
        sequence = (sequence + 1) & 0xFFFF
        packetCount += 1
        return encoded
    }
}
