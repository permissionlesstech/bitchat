import BitFoundation
import BitLogger
import CoreGraphics
import Foundation

/// What a live bubble or the full-screen viewer shows for one stream that is
/// still streaming in. One instance per stream, kept for the stream's life so
/// views can observe it directly.
@MainActor
final class LiveVideoStreamModel: ObservableObject, Identifiable {
    let id: String
    let senderNickname: String
    let startedAt: Date

    @Published fileprivate(set) var frame: CGImage?
    @Published fileprivate(set) var width: Int = LiveVideoQuality.low.width
    @Published fileprivate(set) var height: Int = LiveVideoQuality.low.height
    @Published fileprivate(set) var hasAudio = false
    /// Recent packet loss before FEC, 0...1.
    @Published fileprivate(set) var loss: Double = 0
    @Published fileprivate(set) var receivedKbps: Double = 0
    @Published fileprivate(set) var waitingForKeyframe = true
    /// No new picture for a while (loss the FEC could not repair).
    @Published fileprivate(set) var frozen = false
    /// No packets for a while: still open, resumes at the next keyframe.
    @Published fileprivate(set) var reconnecting = false
    @Published fileprivate(set) var isMuted = false
    /// Set once the stream ended, so an open full-screen viewer can offer
    /// the replay instead of a dead picture.
    @Published fileprivate(set) var endedFileURL: URL?
    @Published fileprivate(set) var hasEnded = false

    init(id: String, senderNickname: String, startedAt: Date) {
        self.id = id
        self.senderNickname = senderNickname
        self.startedAt = startedAt
    }

    /// Signal strength for the bubble's meter, 0...3 bars.
    var signalBars: Int {
        if reconnecting { return 0 }
        switch loss {
        case ..<0.05: return 3
        case ..<0.2: return 2
        case ..<0.4: return 1
        default: return 0
        }
    }
}

/// Receives live video streams (`VideoBurstPacket`s over `MessageType.videoFrame`
/// or `NoisePayloadType.videoFrame`): bounded per-stream assembly with FEC,
/// decoding for the bubble and full-screen viewer, optional live audio, a
/// locally reconstructed MP4, and replacement by the sender's finalized
/// `video_<streamID>.mp4`. Mirrors `ChatLiveVoiceCoordinator` and Android's
/// `LiveVideoManager`; see docs/LIVE_VIDEO_V1.md.
@MainActor
final class ChatLiveVideoCoordinator {
    /// Stream IDs are sender-chosen, so they only identify a stream within an
    /// authenticated (peer, scope) pair.
    private struct StreamKey: Hashable {
        let peerID: PeerID
        let scope: VoiceBurstScope
        let streamID: String
    }

    private struct RecordedSegment {
        let url: URL
        let firstVideoPtsUs: Int64
    }

    private final class Stream {
        let key: StreamKey
        let nickname: String
        let message: BitchatMessage
        let model: LiveVideoStreamModel
        let fileURL: URL
        let startedAt: Date
        /// Recordings of earlier sessions of this stream (closed by silence,
        /// then reopened), joined in on finalize.
        let earlierSegments: [RecordedSegment]
        let assembler = VideoStreamAssembler()
        var config: LiveVideoConfig?
        var decoder: LiveVideoH264Decoder?
        var player: PTTBurstPlayer?
        var writer: LiveVideoMp4Writer?
        var firstVideoPtsUs: Int64?
        var lastPacketAt = Date()
        var lastFrameAt: Date?
        var receivedBytes = 0
        var reconnecting = false
        var decoderStale = false

        init(key: StreamKey, nickname: String, message: BitchatMessage, model: LiveVideoStreamModel, fileURL: URL, startedAt: Date, earlierSegments: [RecordedSegment]) {
            self.key = key
            self.nickname = nickname
            self.message = message
            self.model = model
            self.fileURL = fileURL
            self.startedAt = startedAt
            self.earlierSegments = earlierSegments
        }
    }

    private struct FinishedStream {
        let key: StreamKey
        let messageID: String
        let nickname: String
        let messageTimestamp: Date
        let startedAt: Date
        let fileURL: URL?
        let expiresAt: Date
        /// False when closed by silence: the sender may still be live, so
        /// later packets reopen the same bubble.
        let endedBySender: Bool
        let segments: [RecordedSegment]
    }

    private static let tickInterval: UInt64 = 50_000_000
    private static let infoRefreshSeconds: TimeInterval = 0.5
    private static let frozenAfterSeconds: TimeInterval = 1.5
    private static let finishedStreamsCap = 16
    private static let incomingSubdirectory = "\(MimeType.Category.video.mediaDir)/incoming"

    private unowned let context: any ChatLiveVoiceContext
    private let fileStore: BLEIncomingFileStore
    private let linkBoost: (Bool) -> Void
    private var fileManager: FileManager { fileStore.fileManager }
    private var streams: [StreamKey: Stream] = [:]
    private var finished: [StreamKey: FinishedStream] = [:]
    private var models: [String: LiveVideoStreamModel] = [:]
    private var mutedMessageIDs: Set<String> = []
    private var drainingPlayers: [ObjectIdentifier: PTTBurstPlayer] = [:]
    private var tickTask: Task<Void, Never>?
    private var lastInfoPublish = Date.distantPast
    private var epoch = Date()
    /// Debug hooks shorten this to exercise reopening a closed stream.
    var reconnectWindowSeconds = TransportConfig.liveVideoReconnectWindowSeconds

    init(
        context: any ChatLiveVoiceContext,
        fileStore: BLEIncomingFileStore = BLEIncomingFileStore(),
        linkBoost: @escaping (Bool) -> Void = { _ in },
        sweepsOnInit: Bool = true
    ) {
        self.context = context
        self.fileStore = fileStore
        self.linkBoost = linkBoost
        if sweepsOnInit {
            sweepStaleLiveCaptures()
        }
    }

    // MARK: - Inbound packets

    /// Inbound DM packet (`NoisePayloadType.videoFrame`).
    func handleVideoFramePayload(from peerID: PeerID, payload: Data, timestamp: Date) {
        handle(payload, from: peerID, scope: .directMessage, nickname: context.resolveNickname(for: peerID), timestamp: timestamp)
    }

    /// Inbound public packet (`MessageType.videoFrame`), already signature
    /// verified by the transport, which resolved the nickname.
    func handlePublicVideoFramePayload(from peerID: PeerID, nickname: String, payload: Data, timestamp: Date) {
        handle(payload, from: peerID, scope: .publicMesh, nickname: nickname, timestamp: timestamp)
    }

    private func handle(_ payload: Data, from peerID: PeerID, scope: VoiceBurstScope, nickname: String, timestamp: Date) {
        guard let packet = VideoBurstPacket.decode(payload) else {
            SecureLogger.debug("Video: undecodable packet from \(peerID.id.prefix(8))… (\(payload.count) bytes)", category: .session)
            return
        }
        guard !context.isPeerBlocked(peerID) else { return }

        let key = StreamKey(peerID: peerID, scope: scope, streamID: VideoBurstPacket.streamIDHex(packet.streamID))
        let stream: Stream
        if let existing = streams[key] {
            stream = existing
        } else {
            let closed = finished[key]
            // A stream the sender ended stays closed; one closed by silence
            // reopens in place.
            if closed?.endedBySender == true { return }
            switch packet.kind {
            case .end, .canceled: return
            default: break
            }
            guard streams.count < TransportConfig.liveVideoMaxConcurrentStreams else {
                SecureLogger.debug("Video: dropping stream from \(peerID.id.prefix(8))… — stream cap reached", category: .session)
                return
            }
            let opened = closed.flatMap(reopen) ?? makeStream(key: key, nickname: nickname, timestamp: timestamp)
            guard let opened else { return }
            stream = opened
            ensureTicking()
        }

        let now = Date()
        if stream.reconnecting {
            stream.reconnecting = false
            publishInfo(force: true)
        }
        stream.receivedBytes += payload.count
        let elapsed = max(0, now.timeIntervalSince(stream.startedAt)) + TransportConfig.liveVideoInboundAllowanceSeconds
        guard stream.receivedBytes <= TransportConfig.liveVideoMaxStreamBytes,
              Double(stream.receivedBytes) <= Double(TransportConfig.liveVideoInboundMaxBytesPerSecond) * elapsed
        else {
            SecureLogger.warning("Video: stream from \(peerID.id.prefix(8))… exceeded rate/size caps — finalizing", category: .security)
            finalize(stream, endedBySender: true)
            return
        }
        stream.lastPacketAt = now
        handleOutputs(stream.assembler.onPacket(packet, sizeBytes: payload.count, nowMs: nowMs(now)), for: stream)
    }

    // MARK: - Queries for the UI

    func isLiveVideoMessage(_ message: BitchatMessage) -> Bool {
        streams.values.contains { $0.message.id == message.id }
    }

    /// The live model of a bubble while its stream is open, or of a recently
    /// ended stream (so an open viewer can switch to the replay).
    func streamModel(forMessageID messageID: String) -> LiveVideoStreamModel? {
        models[messageID]
    }

    func setMuted(_ muted: Bool, messageID: String) {
        if muted { mutedMessageIDs.insert(messageID) } else { mutedMessageIDs.remove(messageID) }
        models[messageID]?.isMuted = muted
        if let stream = streams.values.first(where: { $0.message.id == messageID }) {
            updateAudio(stream)
        }
    }

    /// Re-evaluates live audio after the visible conversation or app state
    /// changed (audio plays only for the conversation on screen).
    func visibilityChanged() {
        for stream in streams.values {
            updateAudio(stream)
        }
    }

    func resetForPanic() {
        for stream in Array(streams.values) {
            cancel(stream, emit: false)
        }
        for player in drainingPlayers.values {
            player.stop()
        }
        drainingPlayers.removeAll()
        finished.removeAll()
        models.removeAll()
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Finalized file

    /// Called for every inbound message: when it is the sender's finalized
    /// `video_<streamID>.mp4` of a stream we watched, swap it into the live
    /// bubble and report `true` so the caller skips normal handling.
    func absorbFinalizedVideo(_ message: BitchatMessage) -> Bool {
        let prefix = MimeType.Category.video.messagePrefix
        guard message.content.hasPrefix(prefix),
              let streamID = Self.streamID(fromVideoFileName: String(message.content.dropFirst(prefix.count)))
        else { return false }

        func matches(_ key: StreamKey) -> Bool {
            key.streamID == streamID
                && (message.senderPeerID == nil || key.peerID == message.senderPeerID)
                && message.isPrivate == (key.scope == .directMessage)
        }

        // A fast transfer can beat END; close out the live stream first.
        if let stream = streams.first(where: { matches($0.key) })?.value {
            finalize(stream, endedBySender: true)
        }
        pruneFinished()
        guard let entry = finished.first(where: { matches($0.key) }) else { return false }
        let done = entry.value

        // Like voice: a DM bubble adopts the finalized message's deterministic
        // ID so receipts address the sender's row; public keeps the live ID.
        let replacementID = done.key.scope == .directMessage ? message.id : done.messageID
        let replacement = BitchatMessage(
            id: replacementID,
            sender: message.sender,
            content: message.content,
            timestamp: done.messageTimestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: done.key.scope == .directMessage,
            recipientNickname: done.key.scope == .directMessage ? context.nickname : nil,
            senderPeerID: done.key.peerID,
            mentions: nil,
            deliveryStatus: message.deliveryStatus
        )
        switch done.key.scope {
        case .directMessage:
            let shouldSendAdoptedReadReceipt = context.hasSentReadReceipt(done.messageID)
                || context.selectedPrivateChatPeer == done.key.peerID
            context.upsertPrivateMessage(replacement, in: done.key.peerID)
            if replacementID != done.messageID {
                context.removePrivateMessage(withID: done.messageID)
            }
            if shouldSendAdoptedReadReceipt, context.markReadReceiptSent(replacementID) {
                context.sendMeshReadReceipt(
                    ReadReceipt(originalMessageID: replacementID, readerID: context.myPeerID, readerNickname: context.nickname),
                    to: done.key.peerID
                )
            }
        case .publicMesh:
            context.upsertPublicMeshMessage(replacement)
        }

        if let url = done.fileURL {
            try? fileManager.removeItem(at: url)
        }
        finished.removeValue(forKey: entry.key)
        models.removeValue(forKey: done.messageID)
        context.notifyUIChanged()
        SecureLogger.debug("Video: absorbed finalized file for stream \(streamID)", category: .session)
        return true
    }

    // MARK: - Stream lifecycle

    private func makeStream(key: StreamKey, nickname: String, timestamp: Date) -> Stream? {
        guard let fileURL = liveCaptureURL(for: key, segment: 0) else { return nil }
        let isPrivate = key.scope == .directMessage
        let message = BitchatMessage(
            sender: nickname,
            content: "\(MimeType.Category.video.messagePrefix)\(fileURL.lastPathComponent)",
            timestamp: timestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: isPrivate,
            recipientNickname: isPrivate ? context.nickname : nil,
            senderPeerID: key.peerID
        )
        let model = LiveVideoStreamModel(id: message.id, senderNickname: nickname, startedAt: Date())
        let stream = Stream(key: key, nickname: nickname, message: message, model: model, fileURL: fileURL, startedAt: Date(), earlierSegments: [])
        // Publish live state before the bubble so it never renders as a
        // missing file.
        register(stream)
        switch key.scope {
        case .directMessage:
            context.handlePrivateMessage(message)
        case .publicMesh:
            context.appendPublicMeshMessage(message)
        }
        SecureLogger.debug("Video: stream \(key.streamID) started from \(key.peerID.id.prefix(8))…", category: .session)
        return stream
    }

    /// Continues a stream closed by silence: same bubble, a new segment.
    private func reopen(_ closed: FinishedStream) -> Stream? {
        guard let fileURL = liveCaptureURL(for: closed.key, segment: closed.segments.count) else { return nil }
        finished.removeValue(forKey: closed.key)
        let isPrivate = closed.key.scope == .directMessage
        let message = BitchatMessage(
            id: closed.messageID,
            sender: closed.nickname,
            content: "\(MimeType.Category.video.messagePrefix)\(fileURL.lastPathComponent)",
            timestamp: closed.messageTimestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: isPrivate,
            recipientNickname: isPrivate ? context.nickname : nil,
            senderPeerID: closed.key.peerID
        )
        let model = LiveVideoStreamModel(id: closed.messageID, senderNickname: closed.nickname, startedAt: closed.startedAt)
        let stream = Stream(key: closed.key, nickname: closed.nickname, message: message, model: model, fileURL: fileURL, startedAt: closed.startedAt, earlierSegments: closed.segments)
        register(stream)
        republish(stream.message, scope: closed.key.scope, peerID: closed.key.peerID)
        return stream
    }

    private func register(_ stream: Stream) {
        fileStore.enforceQuota(reservingBytes: 4 * 1024 * 1024)
        try? fileManager.removeItem(at: stream.fileURL)
        streams[stream.key] = stream
        models[stream.message.id] = stream.model
        stream.model.isMuted = mutedMessageIDs.contains(stream.message.id)
        // Watching (and relaying) wants the fast link interval too.
        linkBoost(true)
        publishInfo(force: true)
    }

    private func handleOutputs(_ outputs: [LiveVideoOutput], for stream: Stream) {
        for output in outputs {
            switch output {
            case .config(let config):
                apply(config, to: stream)
            case let .video(_, ptsMs, keyframe, data):
                handleVideo(data, ptsMs: ptsMs, keyframe: keyframe, stream: stream)
            case let .audio(_, ptsMs, data):
                stream.writer?.writeAudio(aac: data, ptsUs: ptsMs * 1_000)
                stream.player?.enqueue([data])
            case .videoSkipped:
                break
            case .ended:
                finalize(stream, endedBySender: true)
                return
            case .canceled:
                cancel(stream, emit: true)
                return
            }
        }
        publishInfo(force: false)
    }

    private func apply(_ config: LiveVideoConfig, to stream: Stream) {
        if let current = stream.config, current != config {
            // A resolution change needs a new decoder; the recording keeps
            // its first geometry.
            stream.decoder?.stop()
            stream.decoder = nil
        }
        stream.config = config
        if stream.decoder == nil {
            let model = stream.model
            let decoder = LiveVideoH264Decoder { [weak self, weak model] image in
                Task { @MainActor in
                    guard let model else { return }
                    model.frame = image
                    self?.noteFrame(forMessageID: model.id)
                }
            }
            decoder.configure(width: config.width, height: config.height)
            stream.decoder = decoder
        }
        stream.model.width = config.width
        stream.model.height = config.height
        stream.model.hasAudio = config.hasAudio
        updateAudio(stream)
        publishInfo(force: true)
    }

    private func handleVideo(_ data: Data, ptsMs: Int64, keyframe: Bool, stream: Stream) {
        guard let config = stream.config else { return }
        if keyframe, stream.writer == nil, H264NalUnits.parameterSets(data) != nil {
            stream.writer = LiveVideoMp4Writer(url: stream.fileURL, hasAudio: config.hasAudio)
        }
        if stream.writer != nil, stream.firstVideoPtsUs == nil {
            stream.firstVideoPtsUs = ptsMs * 1_000
        }
        stream.writer?.writeVideo(annexB: data, ptsUs: ptsMs * 1_000, keyframe: keyframe)
        if keyframe {
            stream.model.waitingForKeyframe = false
        }
        // Nobody sees pictures in the background; keep recording but skip
        // the decode work, then resync at the next keyframe.
        if PTTSettings.isAppActive {
            if stream.decoderStale {
                stream.decoder?.resyncAtKeyframe()
                stream.decoderStale = false
            }
            stream.decoder?.submit(annexB: data, ptsMs: ptsMs, keyframe: keyframe)
        } else {
            stream.decoderStale = true
        }
    }

    private func noteFrame(forMessageID messageID: String) {
        guard let stream = streams.values.first(where: { $0.message.id == messageID }) else { return }
        stream.lastFrameAt = Date()
        if stream.model.frozen {
            stream.model.frozen = false
        }
    }

    private func updateAudio(_ stream: Stream) {
        let isViewing = switch stream.key.scope {
        case .directMessage: context.selectedPrivateChatPeer == stream.key.peerID
        case .publicMesh: context.isViewingPublicMeshTimeline
        }
        let wanted = stream.config?.hasAudio == true
            && PTTSettings.liveVoiceEnabled
            && PTTSettings.isAppActive
            && isViewing
            && !mutedMessageIDs.contains(stream.message.id)
        if wanted, stream.player == nil {
            stream.player = PTTBurstPlayer()
        } else if !wanted, let player = stream.player {
            player.stop()
            stream.player = nil
        }
    }

    private func finalize(_ stream: Stream, endedBySender: Bool) {
        guard streams.removeValue(forKey: stream.key) != nil else { return }
        linkBoost(false)
        stream.decoder?.finishAfterDrain()
        if let player = stream.player, !player.stopped {
            let id = ObjectIdentifier(player)
            drainingPlayers[id] = player
            player.onStopped = { [weak self] in
                self?.drainingPlayers.removeValue(forKey: id)
            }
            player.finishAfterDrain()
        }
        stream.player = nil

        let wroteSegment = stream.writer?.finish() == true
        var segments = stream.earlierSegments
        if wroteSegment {
            segments.append(RecordedSegment(url: stream.fileURL, firstVideoPtsUs: stream.firstVideoPtsUs ?? 0))
        } else {
            try? fileManager.removeItem(at: stream.fileURL)
        }
        stream.model.hasEnded = true

        guard !segments.isEmpty else {
            // Nothing decodable ever arrived — drop the empty bubble.
            removeBubble(of: stream)
            models.removeValue(forKey: stream.message.id)
            rememberFinished(stream, fileURL: nil, endedBySender: endedBySender, segments: [])
            publishInfo(force: true)
            context.notifyUIChanged()
            return
        }

        let target = finalURL(for: stream.key)
        let key = stream.key
        if segments.count == 1 {
            let url = move(segments[0].url, to: target)
            completeFinalize(stream, fileURL: url, endedBySender: endedBySender, firstVideoPtsUs: segments[0].firstVideoPtsUs)
        } else {
            // Sessions separated by a dropout play back as one video. Keep
            // the last segment visible until the join lands.
            completeFinalize(stream, fileURL: segments.last!.url, endedBySender: endedBySender, firstVideoPtsUs: segments[0].firstVideoPtsUs)
            let joinURL = target.deletingLastPathComponent().appendingPathComponent("video_join_\(key.streamID).mp4")
            let inputs = segments.map { (url: $0.url, firstVideoPtsUs: $0.firstVideoPtsUs) }
            Task { [weak self] in
                try? FileManager.default.removeItem(at: joinURL)
                let joined = await LiveVideoMp4Segments.join(inputs, to: joinURL)
                guard let self else { return }
                guard joined, self.streams[key] == nil, let entry = self.finished[key] else {
                    try? FileManager.default.removeItem(at: joinURL)
                    return
                }
                inputs.forEach { try? FileManager.default.removeItem(at: $0.url) }
                let url = self.move(joinURL, to: target)
                self.finished[key] = FinishedStream(
                    key: key,
                    messageID: entry.messageID,
                    nickname: entry.nickname,
                    messageTimestamp: entry.messageTimestamp,
                    startedAt: entry.startedAt,
                    fileURL: url,
                    expiresAt: entry.expiresAt,
                    endedBySender: entry.endedBySender,
                    segments: [RecordedSegment(url: url, firstVideoPtsUs: inputs[0].firstVideoPtsUs)]
                )
                self.republish(self.message(for: entry, fileURL: url), scope: key.scope, peerID: key.peerID)
                self.models[entry.messageID]?.endedFileURL = url
                self.context.notifyUIChanged()
            }
        }
    }

    private func completeFinalize(_ stream: Stream, fileURL: URL, endedBySender: Bool, firstVideoPtsUs: Int64) {
        rememberFinished(stream, fileURL: fileURL, endedBySender: endedBySender, segments: [RecordedSegment(url: fileURL, firstVideoPtsUs: firstVideoPtsUs)])
        stream.model.endedFileURL = fileURL
        republish(message(for: finished[stream.key]!, fileURL: fileURL), scope: stream.key.scope, peerID: stream.key.peerID)
        publishInfo(force: true)
        context.notifyUIChanged()
        SecureLogger.debug("Video: stream \(stream.key.streamID) finalized (endedBySender=\(endedBySender))", category: .session)
    }

    private func rememberFinished(_ stream: Stream, fileURL: URL?, endedBySender: Bool, segments: [RecordedSegment]) {
        pruneFinished()
        finished[stream.key] = FinishedStream(
            key: stream.key,
            messageID: stream.message.id,
            nickname: stream.nickname,
            messageTimestamp: stream.message.timestamp,
            startedAt: stream.startedAt,
            fileURL: fileURL,
            expiresAt: Date().addingTimeInterval(TransportConfig.liveVideoFinishedRegistrySeconds),
            endedBySender: endedBySender,
            segments: segments
        )
    }

    private func message(for entry: FinishedStream, fileURL: URL) -> BitchatMessage {
        let isPrivate = entry.key.scope == .directMessage
        return BitchatMessage(
            id: entry.messageID,
            sender: entry.nickname,
            content: "\(MimeType.Category.video.messagePrefix)\(fileURL.lastPathComponent)",
            timestamp: entry.messageTimestamp,
            isRelay: false,
            isPrivate: isPrivate,
            recipientNickname: isPrivate ? context.nickname : nil,
            senderPeerID: entry.key.peerID,
            deliveryStatus: isPrivate ? .delivered(to: context.nickname, at: entry.messageTimestamp) : nil
        )
    }

    private func cancel(_ stream: Stream, emit: Bool) {
        guard streams.removeValue(forKey: stream.key) != nil else { return }
        linkBoost(false)
        stream.decoder?.stop()
        stream.player?.stop()
        _ = stream.writer?.finish()
        removeBubble(of: stream)
        try? fileManager.removeItem(at: stream.fileURL)
        stream.earlierSegments.forEach { try? fileManager.removeItem(at: $0.url) }
        models.removeValue(forKey: stream.message.id)
        if emit {
            // A canceled stream never reopens.
            rememberFinished(stream, fileURL: nil, endedBySender: true, segments: [])
        }
        publishInfo(force: true)
        context.notifyUIChanged()
    }

    private func removeBubble(of stream: Stream) {
        switch stream.key.scope {
        case .directMessage:
            context.removePrivateMessage(withID: stream.message.id)
        case .publicMesh:
            context.removeMessage(withID: stream.message.id, cleanupFile: false)
        }
    }

    private func republish(_ message: BitchatMessage, scope: VoiceBurstScope, peerID: PeerID) {
        switch scope {
        case .directMessage:
            context.upsertPrivateMessage(message, in: peerID)
        case .publicMesh:
            context.upsertPublicMeshMessage(message)
        }
    }

    // MARK: - Timers

    private func ensureTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.tickInterval)
                guard let self, !Task.isCancelled else { return }
                self.tick()
                if self.streams.isEmpty {
                    self.tickTask = nil
                    return
                }
            }
        }
    }

    private func tick() {
        let now = Date()
        for stream in Array(streams.values) {
            let quiet = now.timeIntervalSince(stream.lastPacketAt)
            if quiet >= TransportConfig.liveVideoQuietSeconds, stream.assembler.endReceived {
                // END arrived and only lost tail units are outstanding.
                handleOutputs(stream.assembler.flush(), for: stream)
            } else if quiet >= reconnectWindowSeconds {
                // Long silence without END: close it, but packets may still
                // reopen it.
                handleOutputs(stream.assembler.drain(), for: stream)
                if streams[stream.key] === stream {
                    finalize(stream, endedBySender: false)
                }
            } else if quiet >= TransportConfig.liveVideoQuietSeconds {
                if !stream.reconnecting {
                    stream.reconnecting = true
                    handleOutputs(stream.assembler.drain(), for: stream)
                    publishInfo(force: true)
                }
            } else {
                handleOutputs(stream.assembler.onTick(nowMs: nowMs(now)), for: stream)
            }
        }
        publishInfo(force: false)
    }

    private func publishInfo(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastInfoPublish) >= Self.infoRefreshSeconds else { return }
        lastInfoPublish = now
        for stream in streams.values {
            let stats = stream.assembler.stats()
            let elapsed = max(1, now.timeIntervalSince(stream.startedAt))
            let model = stream.model
            let kbps = Double(stream.receivedBytes) * 8 / 1_000 / elapsed
            if abs(model.receivedKbps - kbps) > 0.5 { model.receivedKbps = kbps }
            if abs(model.loss - stats.recentLoss) > 0.01 { model.loss = stats.recentLoss }
            if model.reconnecting != stream.reconnecting { model.reconnecting = stream.reconnecting }
            let frozen = stream.lastFrameAt.map { now.timeIntervalSince($0) > Self.frozenAfterSeconds } ?? false
            if model.frozen != frozen { model.frozen = frozen }
            // Audio follows the conversation on screen and the app's state.
            updateAudio(stream)
        }
    }

    // MARK: - Helpers

    private func nowMs(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince(epoch) * 1_000)
    }

    private func pruneFinished() {
        let now = Date()
        for (key, entry) in finished where entry.expiresAt <= now {
            finished.removeValue(forKey: key)
            if streams.values.allSatisfy({ $0.message.id != entry.messageID }) {
                models.removeValue(forKey: entry.messageID)
            }
        }
        while finished.count >= Self.finishedStreamsCap,
              let oldest = finished.min(by: { $0.value.expiresAt < $1.value.expiresAt }) {
            finished.removeValue(forKey: oldest.key)
            models.removeValue(forKey: oldest.value.messageID)
        }
    }

    private func move(_ source: URL, to destination: URL) -> URL {
        guard source != destination else { return source }
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: source, to: destination)
            return destination
        } catch {
            SecureLogger.warning("Video: keeping live name for finished stream — move failed: \(error)", category: .session)
            return source
        }
    }

    /// Extracts the stream ID from a finalized file name
    /// (`video_<16 hex>.mp4`, possibly uniquified by the incoming file store).
    /// Live and reconstructed names (`video_live_…`, `video_join_…`) never match.
    static func streamID(fromVideoFileName fileName: String) -> String? {
        guard fileName.hasPrefix("video_") else { return nil }
        let hex = String(fileName.dropFirst("video_".count).prefix(16))
        guard hex.count == 16, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex.lowercased()
    }

    private func liveCaptureURL(for key: StreamKey, segment: Int) -> URL? {
        guard let directory = try? fileStore.incomingDirectory(subdirectory: Self.incomingSubdirectory) else { return nil }
        let scopeTag = key.scope == .directMessage ? "dm" : "mesh"
        let suffix = segment == 0 ? "" : "_\(segment + 1)"
        return directory.appendingPathComponent("\(BLEIncomingFileStore.liveVideoCapturePrefix)\(key.streamID)_\(key.peerID.id)_\(scopeTag)\(suffix).mp4")
    }

    /// The kept reconstruction. Not `video_<16 hex>.mp4` on purpose: the
    /// peer ID after the stream ID keeps `streamID(fromVideoFileName:)` from
    /// mistaking it for a finalized file, which is matched by sender anyway.
    private func finalURL(for key: StreamKey) -> URL {
        let directory = (try? fileStore.incomingDirectory(subdirectory: Self.incomingSubdirectory))
            ?? fileManager.temporaryDirectory
        let scopeTag = key.scope == .directMessage ? "dm" : "mesh"
        return directory.appendingPathComponent("video_rx_\(key.streamID)_\(key.peerID.id)_\(scopeTag).mp4")
    }

    /// Deletes reconstructions left mid-stream by a previous session (chat
    /// rows are in-memory only, so nothing can reference them).
    private func sweepStaleLiveCaptures() {
        guard let directory = try? fileStore.incomingDirectory(subdirectory: Self.incomingSubdirectory),
              let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return }
        for url in contents where url.lastPathComponent.hasPrefix(BLEIncomingFileStore.liveVideoCapturePrefix)
            || url.lastPathComponent.hasPrefix("video_join_") {
            try? fileManager.removeItem(at: url)
        }
    }
}
