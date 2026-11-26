//
// VideoStreamLossSimulationTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

/// Packetizer -> lossy, reordering channel -> assembler, with synthetic units and a fake clock.
struct VideoStreamLossSimulationTests {
    private let config = LiveVideoConfig(
        videoCodec: .h264AnnexB,
        width: 144,
        height: 192,
        fps: 8,
        bitrateKbps: 24,
        audioCodec: .aacLC16kMono
    )

    private struct SentUnit {
        let keyframe: Bool
        let data: Data
    }

    private struct VideoOut {
        let sequence: Int64
        let ptsMs: Int64
        let keyframe: Bool
        let data: Data
    }

    private struct Result {
        let outputs: [LiveVideoOutput]
        let sentVideo: [SentUnit]
        let sentAudio: [SentUnit]
        let assembler: VideoStreamAssembler
        let packetizer: VideoStreamPacketizer

        var video: [VideoOut] { videoOutputs(outputs) }
        var audio: [Data] {
            outputs.compactMap { if case .audio(_, _, let data) = $0 { return data } else { return nil } }
        }
        var ended: Bool { outputs.contains { if case .ended = $0 { return true } else { return false } } }
    }

    private static func videoOutputs(_ outputs: [LiveVideoOutput]) -> [VideoOut] {
        outputs.compactMap {
            if case .video(let sequence, let pts, let keyframe, let data) = $0 {
                return VideoOut(sequence: sequence, ptsMs: pts, keyframe: keyframe, data: data)
            }
            return nil
        }
    }

    private func videoOutputs(_ outputs: [LiveVideoOutput]) -> [VideoOut] {
        Self.videoOutputs(outputs)
    }

    private static func count(_ outputs: [LiveVideoOutput], where match: (LiveVideoOutput) -> Bool) -> Int {
        outputs.filter(match).count
    }

    private static func isEnded(_ output: LiveVideoOutput) -> Bool {
        if case .ended = output { return true }
        return false
    }

    /// 10 s stream: 8 fps video with a 2 s GOP (keyframes ~2.4 KB, deltas
    /// 120-260 B) and 64 ms audio frames (~96 B). `lose` decides per packet
    /// whether the channel drops it.
    private func run(
        seed: UInt64,
        fec: LiveVideoFecPolicy = LiveVideoFecPolicy(parityRatio: 0.25, keyframeParityRatio: 0.5),
        reorderMs: Int64 = 0,
        lose: @escaping (Int, Data) -> Bool
    ) throws -> Result {
        let random = VideoTestRandom(seed: seed)
        let packetizer = VideoStreamPacketizer(streamID: Data(repeating: 9, count: 8), config: config, fec: fec)
        let assembler = VideoStreamAssembler()
        var sentVideo: [SentUnit] = []
        var sentAudio: [SentUnit] = []
        var inFlight: [(due: Int64, order: Int, packet: Data)] = []
        var outputs: [LiveVideoOutput] = []
        var packetIndex = 0

        func send(_ now: Int64, _ packets: [Data]) {
            for packet in packets {
                let index = packetIndex
                packetIndex += 1
                if !lose(index, packet) {
                    let delay = reorderMs > 0 ? Int64(random.int(0..<Int(reorderMs))) : 0
                    inFlight.append((now + delay, index, packet))
                }
            }
        }

        func deliver(_ now: Int64) throws {
            let due = inFlight.filter { $0.due <= now }.sorted { ($0.due, $0.order) < ($1.due, $1.order) }
            inFlight.removeAll { $0.due <= now }
            for item in due {
                let packet = try #require(VideoBurstPacket.decode(item.packet))
                outputs += assembler.onPacket(packet, sizeBytes: item.packet.count, nowMs: now)
            }
            outputs += assembler.onTick(nowMs: now)
        }

        send(0, packetizer.start())
        var nextVideo: Int64 = 0
        var nextAudio: Int64 = 0
        var frame = 0
        for now in stride(from: Int64(0), through: 10_000, by: 4) {
            if now >= nextVideo {
                let key = frame % 16 == 0
                let data = random.bytes(key ? 2_400 : random.int(120..<260))
                sentVideo.append(SentUnit(keyframe: key, data: data))
                send(now, packetizer.add(LiveMediaUnit(track: .video, ptsMs: now, keyframe: key, data: data), nowMs: now))
                frame += 1
                nextVideo += 125
            }
            if now >= nextAudio {
                let data = random.bytes(random.int(80..<110))
                sentAudio.append(SentUnit(keyframe: false, data: data))
                send(now, packetizer.add(LiveMediaUnit(track: .audio, ptsMs: now, keyframe: false, data: data), nowMs: now))
                nextAudio += 64
            }
            send(now, packetizer.tick(nowMs: now))
            try deliver(now)
        }
        send(10_000, packetizer.finish(durationMs: 10_000, nowMs: 10_000))
        for now in stride(from: Int64(10_000), through: 13_000, by: 10) { try deliver(now) }
        if !assembler.isFinished { outputs += assembler.flush() }
        return Result(outputs: outputs, sentVideo: sentVideo, sentAudio: sentAudio,
                      assembler: assembler, packetizer: packetizer)
    }

    @Test func losslessChannelDeliversEveryUnitInOrder() throws {
        let result = try run(seed: 1) { _, _ in false }
        #expect(result.video.count == result.sentVideo.count)
        #expect(result.audio.count == result.sentAudio.count)
        for (index, unit) in result.video.enumerated() {
            #expect(unit.data == result.sentVideo[index].data)
            #expect(unit.keyframe == result.sentVideo[index].keyframe)
            #expect(unit.sequence == Int64(index))
        }
        for (index, data) in result.audio.enumerated() {
            #expect(data == result.sentAudio[index].data)
        }
        #expect(result.ended)
        #expect(Self.count(result.outputs, where: Self.isEnded) == 1)
        #expect(result.assembler.stats().skippedVideoUnits == 0)
        #expect(result.assembler.stats().recentLoss == 0)
        #expect(result.assembler.endReceived)
        #expect(result.assembler.config == config)
        #expect(result.packetizer.unitsEmitted(.video) == result.sentVideo.count)
        #expect(result.packetizer.unitsEmitted(.audio) == result.sentAudio.count)
        #expect(result.packetizer.droppedUnits == 0)
    }

    @Test func aggregationKeepsPacketsFull() throws {
        let result = try run(seed: 2) { _, _ in false }
        let bytes = result.sentVideo.reduce(0) { $0 + $1.data.count } + result.sentAudio.reduce(0) { $0 + $1.data.count }
        let sourcePackets = result.packetizer.packetCount - result.packetizer.parityPackets
        // Far fewer packets than units: small audio/delta units share shards.
        #expect(sourcePackets < (result.sentVideo.count + result.sentAudio.count) * 2 / 3)
        #expect(bytes / sourcePackets > 180)
    }

    @Test(arguments: Array(UInt64(70)..<UInt64(78)))
    func fecRepairsIndependentLossWithoutVisibleGaps(seed: UInt64) throws {
        let loss = VideoTestRandom(seed: seed)
        let result = try run(seed: seed, reorderMs: 120) { _, _ in loss.double() < 0.05 }
        let stats = result.assembler.stats()
        #expect(stats.recoveredShards > 0, "recovered \(stats.recoveredShards)")
        // 5% random loss is mostly absorbed by parity; a rare unrecoverable
        // block costs at most the rest of its GOP.
        #expect(Double(result.video.count) >= Double(result.sentVideo.count) * 0.8,
                "video \(result.video.count)/\(result.sentVideo.count)")
        #expect(Double(result.audio.count) >= Double(result.sentAudio.count) * 0.95,
                "audio \(result.audio.count)/\(result.sentAudio.count)")
        #expect(result.ended)
    }

    @Test func heavyBurstLossFreezesUntilNextKeyframeAndNeverEmitsBrokenDeltas() throws {
        // Drop 40 consecutive packets (an entire GOP's worth of shards plus its parity).
        let result = try run(seed: 4) { index, _ in (60...99).contains(index) }
        var sentByContent: [Data: SentUnit] = [:]
        for unit in result.sentVideo { sentByContent[unit.data] = unit }
        var chainValid = false
        var previousSequence: Int64 = -1
        for unit in result.video {
            #expect(sentByContent[unit.data] != nil)
            if unit.keyframe { chainValid = true }
            #expect(chainValid, "delta emitted without an intact chain")
            if !unit.keyframe { #expect(unit.sequence == previousSequence + 1) }
            previousSequence = unit.sequence
        }
        #expect(result.assembler.stats().skippedVideoUnits > 0)
        // Recovers at the next keyframe and keeps playing.
        #expect(result.video.count > result.sentVideo.count / 2)
    }

    @Test func lateJoinerStartsAtTheFirstKeyframe() throws {
        let result = try run(seed: 5) { index, _ in index < 150 }
        let first = try #require(result.video.first)
        #expect(first.keyframe)
        #expect(result.outputs.contains { if case .config = $0 { return true } else { return false } })
    }

    @Test func duplicatedPacketsAreIgnored() throws {
        let packetizer = VideoStreamPacketizer(
            streamID: Data(count: 8), config: config,
            fec: LiveVideoFecPolicy(parityRatio: 0.25, keyframeParityRatio: 0.5)
        )
        let assembler = VideoStreamAssembler()
        let packets = packetizer.start()
            + packetizer.add(LiveMediaUnit(track: .video, ptsMs: 0, keyframe: true, data: Data(repeating: 3, count: 900)), nowMs: 0)
            + packetizer.finish(durationMs: 1_000, nowMs: 1_000)
        var outputs: [LiveVideoOutput] = []
        for bytes in packets + packets {
            let packet = try #require(VideoBurstPacket.decode(bytes))
            outputs += assembler.onPacket(packet, sizeBytes: bytes.count, nowMs: 0)
        }
        #expect(videoOutputs(outputs).count == 1)
        #expect(Self.count(outputs, where: Self.isEnded) == 1)
        #expect(outputs.last == .ended(durationMs: 1_000))
    }

    @Test func streamResumesAfterALongSilenceAtTheNextKeyframe() throws {
        // 10 s of total silence mid-stream (a link dropout); the viewer drains
        // what it has, keeps the stream open, and carries on at the first
        // keyframe after the gap.
        var silenceDrained = false
        let packetizer = VideoStreamPacketizer(
            streamID: Data(repeating: 4, count: 8), config: config,
            fec: LiveVideoFecPolicy(parityRatio: 0.2, keyframeParityRatio: 0.4)
        )
        let assembler = VideoStreamAssembler()
        var outputs: [LiveVideoOutput] = []
        let random = VideoTestRandom(seed: 9)
        func deliver(_ packets: [Data], _ now: Int64, silent: Bool) throws {
            if silent { return }
            for bytes in packets {
                let packet = try #require(VideoBurstPacket.decode(bytes))
                outputs += assembler.onPacket(packet, sizeBytes: bytes.count, nowMs: now)
            }
        }
        try deliver(packetizer.start(), 0, silent: false)
        var frame = 0
        for now in stride(from: Int64(0), through: 30_000, by: 125) {
            let silent = (10_000..<20_000).contains(now)
            if silent && !silenceDrained && now >= 14_000 {
                outputs += assembler.drain()
                silenceDrained = true
            }
            let key = frame % 16 == 0
            let data = random.bytes(key ? 2_000 : random.int(100..<200))
            try deliver(packetizer.add(LiveMediaUnit(track: .video, ptsMs: now, keyframe: key, data: data), nowMs: now),
                        now, silent: silent)
            try deliver(packetizer.tick(nowMs: now), now, silent: silent)
            outputs += assembler.onTick(nowMs: now)
            frame += 1
        }
        try deliver(packetizer.finish(durationMs: 30_000, nowMs: 30_000), 30_000, silent: false)
        outputs += assembler.onTick(nowMs: 31_000)

        let video = videoOutputs(outputs)
        let before = video.filter { $0.ptsMs < 10_000 }.count
        let after = video.filter { $0.ptsMs >= 20_000 }
        #expect(before >= 75, "before \(before)")
        #expect(after.count >= 60, "resumed \(after.count)")
        #expect(after.first?.keyframe == true)
        #expect(silenceDrained)
        #expect(Self.count(outputs, where: Self.isEnded) == 1)
    }

    // MARK: - Assembler edge cases

    private func dataPacket(block: Int, sequence: Int, entries: [LiveVideoEntry]) throws -> VideoBurstPacket {
        try #require(VideoBurstPacket(
            streamID: Data(count: 8),
            sequence: sequence,
            kind: .data(block: block, index: 0, entriesRegion: VideoBurstPacket.encodeEntries(entries))
        ))
    }

    private func unit(_ track: LiveVideoTrack, _ sequence: Int, keyframe: Bool = false) -> LiveVideoEntry {
        LiveVideoEntry(track: track, keyframe: keyframe, unitSequence: sequence, ptsMs: Int64(sequence),
                       fragmentIndex: 0, fragmentCount: 1, bytes: Data([UInt8(truncatingIfNeeded: sequence)]))
    }

    @Test func unitSequencesExpandAcrossThe16BitWrap() throws {
        let assembler = VideoStreamAssembler()
        var outputs: [LiveVideoOutput] = []
        for (index, sequence) in [65_534, 65_535, 0, 1].enumerated() {
            let packet = try dataPacket(block: index, sequence: index,
                                        entries: [unit(.video, sequence, keyframe: index == 0)])
            outputs += assembler.onPacket(packet, sizeBytes: 0, nowMs: 0)
        }
        #expect(videoOutputs(outputs).map(\.sequence) == [65_534, 65_535, 65_536, 65_537])
        #expect(VideoStreamAssembler.expand(2, reference: 65_535) == 65_538)
        #expect(VideoStreamAssembler.expand(65_535, reference: 65_538) == 65_535)
        #expect(VideoStreamAssembler.expand(65_535, reference: 0) == -1)
        #expect(VideoStreamAssembler.expandCount(3, reference: 65_537) == 65_539)
        #expect(VideoStreamAssembler.expandCount(0, reference: 0) == 0)
    }

    @Test func gapIsSkippedAfterTheDeadlineAndBreaksTheVideoChain() throws {
        let assembler = VideoStreamAssembler(gapMs: 900)
        var outputs: [LiveVideoOutput] = []
        outputs += assembler.onPacket(try dataPacket(block: 0, sequence: 0, entries: [unit(.video, 0, keyframe: true)]),
                                      sizeBytes: 0, nowMs: 0)
        // Unit 1 lost; unit 2 (a delta) waits for it.
        outputs += assembler.onPacket(try dataPacket(block: 1, sequence: 2, entries: [unit(.video, 2)]),
                                      sizeBytes: 0, nowMs: 100)
        #expect(videoOutputs(outputs).count == 1)
        #expect(assembler.onTick(nowMs: 999).isEmpty)
        let skipped = assembler.onTick(nowMs: 1_000)
        // The gap is skipped, and the delta after it is withheld rather than decoded.
        #expect(skipped == [.videoSkipped(1), .videoSkipped(1)])
        #expect(assembler.stats().skippedVideoUnits == 2)
        let resumed = assembler.onPacket(try dataPacket(block: 2, sequence: 3, entries: [unit(.video, 3, keyframe: true)]),
                                         sizeBytes: 0, nowMs: 1_100)
        #expect(videoOutputs(resumed).map(\.sequence) == [3])
    }

    @Test func readyBacklogBeyondTheCapSkipsTheHeadGap() throws {
        let assembler = VideoStreamAssembler()
        var outputs: [LiveVideoOutput] = []
        outputs += assembler.onPacket(try dataPacket(block: 0, sequence: 0, entries: [unit(.audio, 0)]),
                                      sizeBytes: 0, nowMs: 0)
        // Unit 1 never arrives; 193 later units pile up behind it.
        for sequence in 2...194 {
            outputs += assembler.onPacket(try dataPacket(block: sequence, sequence: sequence, entries: [unit(.audio, sequence)]),
                                          sizeBytes: 0, nowMs: 0)
        }
        let released: [Int64] = outputs.compactMap { if case .audio(let sequence, _, _) = $0 { return sequence } else { return nil } }
        #expect(released == [0] + (2...194).map { Int64($0) })
        #expect(assembler.stats().audioUnits == 194)
    }

    @Test func cancelEndsTheStreamImmediately() throws {
        let assembler = VideoStreamAssembler()
        let cancel = try #require(VideoBurstPacket(streamID: Data(count: 8), sequence: 1, kind: .canceled))
        #expect(assembler.onPacket(cancel, sizeBytes: 11, nowMs: 0) == [.canceled])
        #expect(assembler.isFinished)
        #expect(assembler.onPacket(try dataPacket(block: 0, sequence: 2, entries: [unit(.audio, 0)]),
                                   sizeBytes: 0, nowMs: 0).isEmpty)
        #expect(assembler.flush().isEmpty)
    }

    @Test func flushEndsOnceWithoutAnEndPacket() throws {
        let assembler = VideoStreamAssembler()
        _ = assembler.onPacket(try dataPacket(block: 0, sequence: 0, entries: [unit(.video, 0, keyframe: true)]),
                               sizeBytes: 0, nowMs: 0)
        #expect(assembler.flush() == [.ended(durationMs: 0)])
        #expect(assembler.isFinished)
        #expect(assembler.flush().isEmpty)
    }

    @Test func recentLossReflectsMissingSequences() throws {
        let assembler = VideoStreamAssembler()
        for sequence in stride(from: 0, to: 128, by: 2) {
            _ = assembler.onPacket(try dataPacket(block: sequence, sequence: sequence, entries: [unit(.audio, sequence)]),
                                   sizeBytes: 10, nowMs: 0)
        }
        let stats = assembler.stats()
        #expect(stats.packets == 64)
        #expect(stats.bytes == 640)
        #expect(abs(stats.recentLoss - (1.0 - 64.0 / 127.0)) < 1e-9)
    }
}
