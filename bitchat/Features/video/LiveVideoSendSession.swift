//
// LiveVideoSendSession.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import CoreVideo
import Foundation

/// Where one live stream's packets go. Closures are called on the session's
/// sender queue.
struct LiveVideoTarget {
    let send: (Data) -> Void
    /// Packets queued on the busiest outbound link (0 when unknown); drives
    /// congestion control.
    let backlog: () -> Int
    /// Packets per second the route carries without building hidden queues.
    let packetBudgetPerSecond: Int
    /// Reference-counted fast-link request while the stream is live.
    let linkBoost: (Bool) -> Void
}

struct LiveVideoSendStats: Equatable {
    var elapsedMs: Int64 = 0
    var framesEncoded = 0
    var packetsSent = 0
    var parityPackets = 0
    var bytesSent = 0
    var videoBitrate = 0
    var congestionSkippedUnits = 0
    var staleDropped = 0
    var maxBacklog = 0
}

/// Encodes pushed camera frames to H.264 (+ optional AAC frames), streams it as
/// `VideoBurstPacket`s when a target is set, and records the same encoded
/// samples into an MP4 the caller sends as the reliable final file. With no
/// target it only records, which is how clips are made. Port of Android's
/// `LiveVideoCapture`; see docs/LIVE_VIDEO_V1.md.
///
/// The caller owns the camera/microphone source (so a viewfinder can run
/// before and after recording) and pushes frames in with `offerVideo` and
/// `offerAudio`. Encoder output, packetizing, pacing and recording are
/// confined to one serial queue, so the sender state needs no locks.
final class LiveVideoSendSession: @unchecked Sendable {
    private static let minValidDurationMs: Int64 = 1_000
    private static let pacingHeadroom = 1.8
    private static let pacingBurstPackets = 6.0
    private static let senderDrainTimeout: TimeInterval = 8
    /// Packets older than this in the pacing queue are dropped: they would
    /// arrive stale.
    private static let outboundDeadlineMs: Int64 = 1_200
    private static let congestionCheckMs: Int64 = 250
    private static let tickMs = 10

    static func fileName(for streamID: Data) -> String {
        "video_\(VideoBurstPacket.streamIDHex(streamID)).mp4"
    }

    let streamID: Data
    let quality: LiveVideoQuality
    let outputURL: URL

    private let target: LiveVideoTarget?
    private let audioEnabled: Bool
    private let queue = DispatchQueue(label: "chat.bitchat.livevideo.send", qos: .userInitiated)

    // Queue-confined state.
    private var encoder: LiveVideoH264Encoder?
    private var writer: LiveVideoMp4Writer?
    private var packetizer: VideoStreamPacketizer
    private var congestion: LiveVideoCongestionController
    private var outbound: [(queuedAtMs: Int64, packet: Data)] = []
    private var outboundHead = 0
    private var timer: DispatchSourceTimer?
    private var startUptime: TimeInterval = 0
    private var lastFrameUptime: TimeInterval = 0
    private var audioOffsetUs: Int64?
    private var audioFrames: Int64 = 0
    private var byteTokens: Double
    private var packetTokens: Double
    private var lastRefill: TimeInterval = 0
    private var lastCongestionCheckMs: Int64 = -1_000
    private var awaitingKeyframe = false
    private var running = false
    private var stats = LiveVideoSendStats()
    private let bytesPerSecond: Double
    private let packetsPerSecond: Double
    private let byteBurst: Double

    init(
        outputDirectory: URL,
        fileName: String? = nil,
        target: LiveVideoTarget?,
        quality: LiveVideoQuality,
        audioEnabled: Bool,
        streamID: Data = VideoBurstPacket.makeStreamID()
    ) {
        self.streamID = streamID
        self.quality = quality
        self.target = target
        self.audioEnabled = audioEnabled
        self.outputURL = outputDirectory.appendingPathComponent(fileName ?? Self.fileName(for: streamID))
        let config = LiveVideoConfig(
            videoCodec: .h264AnnexB,
            width: quality.width,
            height: quality.height,
            fps: quality.fps,
            bitrateKbps: quality.videoBitrate / 1_000,
            audioCodec: audioEnabled ? .aacLC16kMono : .none
        )
        packetizer = VideoStreamPacketizer(streamID: streamID, config: config, fec: quality.fec)

        // Pace to the lower of what the preset needs and what the route can
        // carry: the queue in front of the pacer is then ours to observe,
        // rather than an invisible buffer deep in the Bluetooth stack.
        let budget = max(4, target?.packetBudgetPerSecond ?? TransportConfig.liveVideoBLEPacketBudget)
        let presetBytesPerSecond = Double(quality.totalBitrate) / 8 * (1 + quality.fec.parityRatio) * Self.pacingHeadroom
        bytesPerSecond = min(presetBytesPerSecond, Double(budget * VideoBurstPacket.maxPacketBytes))
        packetsPerSecond = Double(budget)
        byteBurst = Self.pacingBurstPackets * Double(VideoBurstPacket.maxPacketBytes)
        byteTokens = byteBurst
        packetTokens = Self.pacingBurstPackets
        congestion = LiveVideoCongestionController(
            maxBitrate: quality.videoBitrate,
            highWater: max(6, budget * 6 / 10),
            skipWater: max(18, budget * 3 / 2)
        )
    }

    func currentStats() -> LiveVideoSendStats {
        queue.sync {
            var snapshot = stats
            snapshot.elapsedMs = running || startUptime > 0 ? nowMs() : 0
            snapshot.parityPackets = packetizer.parityPackets
            snapshot.videoBitrate = congestion.bitrate
            return snapshot
        }
    }

    func elapsedSeconds() -> TimeInterval {
        startUptime == 0 ? 0 : ProcessInfo.processInfo.systemUptime - startUptime
    }

    /// Starts encoding, recording and (with a target) streaming.
    func start() async throws {
        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: BLEIncomingFileStore.mediaProtectionAttributes
        )
        let encoder = try LiveVideoH264Encoder(
            width: quality.width,
            height: quality.height,
            fps: quality.fps,
            bitrate: quality.videoBitrate,
            keyframeIntervalSeconds: quality.keyframeIntervalSeconds
        )
        let writer = LiveVideoMp4Writer(url: outputURL, hasAudio: audioEnabled)
        encoder.onFrame = { [weak self] frame in
            self?.queue.async { self?.handleEncoded(frame) }
        }
        queue.sync {
            self.encoder = encoder
            self.writer = writer
            self.startUptime = ProcessInfo.processInfo.systemUptime
            self.lastRefill = self.startUptime
            self.running = true
            if target != nil {
                enqueue(packetizer.start())
                startTimer()
            }
        }
        target?.linkBoost(true)
    }

    /// Stops capture. Returns the finalized MP4, or nil when canceled or
    /// shorter than a second. With a target, END (or CANCELED) is sent and
    /// the pacing queue drained before this returns.
    func stop(canceled: Bool) async -> URL? {
        let encoder = queue.sync { () -> LiveVideoH264Encoder? in
            running = false
            return self.encoder
        }
        // Flush the encoder; its last frames land on the queue before the
        // block below runs.
        encoder?.finish()
        let result: URL? = await withCheckedContinuation { continuation in
            queue.async {
                let durationMs = self.nowMs()
                let wrote = self.writer?.finish() == true
                let valid = !canceled && wrote && durationMs >= Self.minValidDurationMs
                self.encoder?.invalidate()
                self.encoder = nil
                self.writer = nil
                if self.target != nil {
                    if valid {
                        self.enqueue(self.packetizer.finish(durationMs: durationMs, nowMs: durationMs))
                    } else if let cancel = self.packetizer.cancel() {
                        self.enqueue([cancel])
                    }
                    self.finalDrain()
                }
                if !valid {
                    try? FileManager.default.removeItem(at: self.outputURL)
                }
                continuation.resume(returning: valid ? self.outputURL : nil)
            }
        }
        target?.linkBoost(false)
        return result
    }

    // MARK: - Capture input

    /// Called on the source's queue; drops pictures beyond the preset rate.
    func offerVideo(_ pixelBuffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        let interval = 1 / Double(quality.fps)
        // Allow 15% early so a 30 fps camera reliably yields the target rate.
        let accepted: Bool = queue.sync {
            guard running else { return false }
            if lastFrameUptime != 0, now - lastFrameUptime < interval * 0.85 { return false }
            lastFrameUptime = now
            return true
        }
        guard accepted, let encoder = queue.sync(execute: { self.encoder }) else { return }
        encoder.encode(pixelBuffer, ptsUs: Int64((now - startUptime) * 1_000_000))
    }

    private func handleEncoded(_ frame: LiveVideoEncodedFrame) {
        writer?.writeVideo(annexB: frame.annexB, ptsUs: frame.ptsUs, keyframe: frame.keyframe)
        stats.framesEncoded += 1
        guard target != nil else { return }
        let unit = LiveMediaUnit(track: .video, ptsMs: frame.ptsUs / 1_000, keyframe: frame.keyframe, data: frame.annexB)
        guard admit(unit) else { return }
        enqueue(packetizer.add(unit, nowMs: nowMs()))
    }

    /// Raw AAC-LC 16 kHz mono frames, in capture order.
    func offerAudio(_ frames: [Data]) {
        guard audioEnabled else { return }
        queue.async { self.handleAudio(frames) }
    }

    private func handleAudio(_ frames: [Data]) {
        guard running else { return }
        let offset = audioOffsetUs ?? {
            let value = Int64((ProcessInfo.processInfo.systemUptime - startUptime) * 1_000_000)
            audioOffsetUs = value
            return value
        }()
        for frame in frames {
            let ptsUs = offset + audioFrames * Int64(PTTAudioFormat.samplesPerFrame) * 1_000_000 / Int64(PTTAudioFormat.sampleRate)
            audioFrames += 1
            writer?.writeAudio(aac: frame, ptsUs: ptsUs)
            if target != nil {
                enqueue(packetizer.add(LiveMediaUnit(track: .audio, ptsMs: ptsUs / 1_000, keyframe: false, data: frame), nowMs: nowMs()))
            }
        }
    }

    // MARK: - Sender (queue-confined)

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(Self.tickMs), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let now = nowMs()
        if now - lastCongestionCheckMs >= Self.congestionCheckMs, let target {
            lastCongestionCheckMs = now
            let backlog = max(target.backlog(), outbound.count - outboundHead)
            stats.maxBacklog = max(stats.maxBacklog, backlog)
            let decision = congestion.onBacklog(backlog, nowMs: now)
            encoder?.setBitrate(decision.bitrate)
            if decision.skipVideo { awaitingKeyframe = true }
            if decision.requestKeyframe { encoder?.requestKeyframe() }
        }
        if running {
            enqueue(packetizer.tick(nowMs: now))
        }
        drainPaced(finalDrain: false)
    }

    /// While the link is far behind (and until a fresh keyframe once it
    /// drains) video is dropped at the source: queued deltas would only
    /// arrive stale. Audio keeps flowing.
    private func admit(_ unit: LiveMediaUnit) -> Bool {
        guard unit.track == .video else { return true }
        if congestion.skipping || (awaitingKeyframe && !unit.keyframe) {
            stats.congestionSkippedUnits += 1
            return false
        }
        if unit.keyframe { awaitingKeyframe = false }
        return true
    }

    private func enqueue(_ packets: [Data]) {
        guard !packets.isEmpty else { return }
        let now = nowMs()
        outbound.append(contentsOf: packets.map { (now, $0) })
    }

    /// Sends what the token buckets allow.
    @discardableResult
    private func drainPaced(finalDrain: Bool) -> TimeInterval {
        guard let target else { return 0 }
        while outboundHead < outbound.count {
            let (queuedAt, packet) = outbound[outboundHead]
            if !finalDrain, nowMs() - queuedAt > Self.outboundDeadlineMs {
                outboundHead += 1
                stats.staleDropped += 1
                continue
            }
            let uptime = ProcessInfo.processInfo.systemUptime
            let elapsed = uptime - lastRefill
            lastRefill = uptime
            byteTokens = min(byteBurst, byteTokens + elapsed * bytesPerSecond)
            packetTokens = min(Self.pacingBurstPackets, packetTokens + elapsed * packetsPerSecond)
            if byteTokens < Double(packet.count) || packetTokens < 1 {
                if outboundHead > 256 {
                    outbound.removeFirst(outboundHead)
                    outboundHead = 0
                }
                let byteWait = max(0, Double(packet.count) - byteTokens) / bytesPerSecond
                let packetWait = max(0, 1 - packetTokens) / packetsPerSecond
                return max(byteWait, packetWait)
            }
            byteTokens -= Double(packet.count)
            packetTokens -= 1
            outboundHead += 1
            target.send(packet)
            stats.packetsSent += 1
            stats.bytesSent += packet.count
        }
        outbound.removeAll(keepingCapacity: true)
        outboundHead = 0
        return 0
    }

    private func finalDrain() {
        timer?.cancel()
        timer = nil
        let deadline = ProcessInfo.processInfo.systemUptime + Self.senderDrainTimeout
        while outboundHead < outbound.count, ProcessInfo.processInfo.systemUptime < deadline {
            let wait = drainPaced(finalDrain: true)
            if wait > 0 {
                Thread.sleep(forTimeInterval: min(wait, 0.02))
            }
        }
        outbound.removeAll()
        outboundHead = 0
    }

    private func nowMs() -> Int64 {
        guard startUptime > 0 else { return 0 }
        return Int64((ProcessInfo.processInfo.systemUptime - startUptime) * 1_000)
    }
}
