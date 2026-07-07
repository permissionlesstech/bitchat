import BitFoundation
import BitLogger
import Foundation

/// The narrow surface `ChatLiveVoiceCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`, keeping it independently testable.
@MainActor
protocol ChatLiveVoiceContext: AnyObject {
    var nickname: String { get }
    var selectedPrivateChatPeer: PeerID? { get }
    /// Whether the public mesh timeline is what's on screen (autoplay gate
    /// for public bursts).
    var isViewingPublicMeshTimeline: Bool { get }
    func isPeerBlocked(_ peerID: PeerID) -> Bool
    func resolveNickname(for peerID: PeerID) -> String
    /// Routes an inbound private message through the full pipeline
    /// (store append, unread state, notification, read receipt).
    func handlePrivateMessage(_ message: BitchatMessage)
    /// Routes an inbound public message through the full pipeline.
    func handlePublicMessage(_ message: BitchatMessage)
    /// Replace-or-append by message ID via the single-writer store intent.
    func upsertPrivateMessage(_ message: BitchatMessage, in peerID: PeerID)
    /// Replace-or-append by message ID in the public mesh timeline.
    func upsertPublicMeshMessage(_ message: BitchatMessage)
    @discardableResult
    func removePrivateMessage(withID messageID: String) -> BitchatMessage?
    /// Removes a message from whichever conversation holds it.
    func removeMessage(withID messageID: String, cleanupFile: Bool)
    /// Publishes who is currently talking live in the public mesh channel
    /// (floor-courtesy indicator on the composer mic), nil when nobody is.
    func setActivePublicVoiceTalker(_ nickname: String?)
    func notifyUIChanged()
}

extension ChatViewModel: ChatLiveVoiceContext {
    var isViewingPublicMeshTimeline: Bool {
        selectedPrivateChatPeer == nil && activeChannel == .mesh
    }

    func upsertPublicMeshMessage(_ message: BitchatMessage) {
        conversations.upsertByID(message, in: ConversationID(channelID: .mesh))
    }

    func setActivePublicVoiceTalker(_ nickname: String?) {
        if activePublicVoiceTalker != nickname {
            activePublicVoiceTalker = nickname
        }
    }
}

/// Where a live voice burst lives: a Noise DM or the public mesh timeline.
enum VoiceBurstScope: Equatable {
    case directMessage
    case publicMesh
}

/// Assembles inbound live push-to-talk bursts (`NoisePayloadType.voiceFrame`):
/// orders packets behind a jitter window, persists frames progressively as an
/// ADTS `.aac` so even a partial burst is a replayable voice-note bubble,
/// optionally plays the stream live, and absorbs the sender's finalized
/// `.m4a` voice note (matched by the burst ID in its file name) into the same
/// bubble so nobody sees a duplicate.
@MainActor
final class ChatLiveVoiceCoordinator {
    private final class Assembly {
        let burstID: Data
        let peerID: PeerID
        let scope: VoiceBurstScope
        let nickname: String
        let message: BitchatMessage
        var messageID: String { message.id }
        var messageTimestamp: Date { message.timestamp }
        let fileURL: URL
        var fileHandle: FileHandle?
        /// Data packets buffered ahead of `nextSeq` (seq -> frames).
        var buffered: [UInt16: [Data]] = [:]
        /// Next data-packet seq to deliver (seq 0 is START).
        var nextSeq: UInt16 = 1
        var deliveredFrames = 0
        var receivedBytes = 0
        let firstPacketAt: Date
        var endInfo: (totalDataPackets: UInt16, durationMs: UInt32)?
        /// When a seq gap was first observed; after
        /// `ChatLiveVoiceCoordinator.gapSkipSeconds` the gap is skipped.
        var gapSince: Date?
        var player: PTTBurstPlayer?
        var idleTimeout: Task<Void, Never>?
        var gapRedrain: Task<Void, Never>?

        init(burstID: Data, peerID: PeerID, scope: VoiceBurstScope, nickname: String, message: BitchatMessage, fileURL: URL, fileHandle: FileHandle) {
            self.burstID = burstID
            self.peerID = peerID
            self.scope = scope
            self.nickname = nickname
            self.message = message
            self.fileURL = fileURL
            self.fileHandle = fileHandle
            self.firstPacketAt = Date()
        }
    }

    private struct FinishedBurst {
        let messageID: String
        let peerID: PeerID
        let scope: VoiceBurstScope
        let fileURL: URL
        let messageTimestamp: Date
        let expiresAt: Date
    }

    /// How long a missing packet stalls delivery before being skipped.
    private static let gapSkipSeconds: TimeInterval = 0.5
    private static let finishedBurstsCap = 32

    private unowned let context: any ChatLiveVoiceContext
    private var assemblies: [Data: Assembly] = [:]
    private var finishedBursts: [Data: FinishedBurst] = [:]

    init(context: any ChatLiveVoiceContext) {
        self.context = context
    }

    // MARK: - Inbound frames

    /// Inbound DM burst packet (`NoisePayloadType.voiceFrame`).
    func handleVoiceFramePayload(from peerID: PeerID, payload: Data, timestamp: Date) {
        handle(payload, from: peerID, scope: .directMessage, nickname: context.resolveNickname(for: peerID), timestamp: timestamp)
    }

    /// Inbound public burst packet (`MessageType.voiceFrame`), already
    /// signature-verified by the transport, which resolved the nickname.
    func handlePublicVoiceFramePayload(from peerID: PeerID, nickname: String, payload: Data, timestamp: Date) {
        handle(payload, from: peerID, scope: .publicMesh, nickname: nickname, timestamp: timestamp)
    }

    private func handle(_ payload: Data, from peerID: PeerID, scope: VoiceBurstScope, nickname: String, timestamp: Date) {
        guard let packet = VoiceBurstPacket.decode(payload) else { return }
        guard !context.isPeerBlocked(peerID) else { return }

        if let assembly = assemblies[packet.burstID] {
            // The sender is authenticated (Noise session or packet
            // signature); a different peer or scope reusing the same burst
            // ID is a collision or a replay — drop it.
            guard assembly.peerID == peerID, assembly.scope == scope else { return }
            apply(packet, to: assembly)
            return
        }

        switch packet.kind {
        case .start, .frames:
            // A data packet with no prior START (lost or mid-burst join)
            // still opens the assembly with the default codec.
            guard assemblies.count < TransportConfig.pttMaxConcurrentAssemblies else {
                SecureLogger.debug("PTT: dropping burst from \(peerID.id.prefix(8))… — assembly cap reached", category: .session)
                return
            }
            guard let assembly = makeAssembly(burstID: packet.burstID, peerID: peerID, scope: scope, nickname: nickname, timestamp: timestamp) else { return }
            assemblies[packet.burstID] = assembly
            updatePublicTalkerIndicator()
            apply(packet, to: assembly)
        case .end, .canceled:
            // Control packet for a burst we never saw — nothing to do.
            break
        }
    }

    /// Whether this message is the bubble of a burst still streaming in.
    func isLiveVoiceMessage(_ message: BitchatMessage) -> Bool {
        assemblies.values.contains { $0.messageID == message.id }
    }

    /// Called for every inbound private message: when it is the finalized
    /// voice note of a burst we assembled (matched by burst ID in the file
    /// name), swap it into the existing live bubble and report `true` so the
    /// caller skips normal handling — no duplicate row, no second
    /// notification.
    func absorbFinalizedVoiceNote(_ message: BitchatMessage) -> Bool {
        let prefix = MimeType.Category.audio.messagePrefix
        guard message.content.hasPrefix(prefix),
              let burstID = Self.burstID(fromVoiceFileName: String(message.content.dropFirst(prefix.count)))
        else { return false }

        // The note usually lands after END, but a lost END or a fast transfer
        // can beat it — close out the live assembly first.
        if let assembly = assemblies[burstID] {
            finalize(assembly)
        }

        pruneFinishedBursts()
        guard let finished = finishedBursts[burstID] else { return false }
        // Bind the note to the burst's authenticated sender and scope.
        guard message.senderPeerID == nil || message.senderPeerID == finished.peerID else { return false }
        guard message.isPrivate == (finished.scope == .directMessage) else { return false }

        let replacement = BitchatMessage(
            id: finished.messageID,
            sender: message.sender,
            content: message.content,
            timestamp: finished.messageTimestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: finished.scope == .directMessage,
            recipientNickname: finished.scope == .directMessage ? context.nickname : nil,
            senderPeerID: finished.peerID,
            mentions: nil,
            deliveryStatus: message.deliveryStatus
        )
        switch finished.scope {
        case .directMessage:
            context.upsertPrivateMessage(replacement, in: finished.peerID)
        case .publicMesh:
            context.upsertPublicMeshMessage(replacement)
        }

        // The complete .m4a replaces the partial live capture.
        WaveformCache.shared.purge(url: finished.fileURL)
        try? FileManager.default.removeItem(at: finished.fileURL)
        finishedBursts.removeValue(forKey: burstID)

        context.notifyUIChanged()
        SecureLogger.debug("PTT: absorbed finalized note for burst \(burstID.hexEncodedString())", category: .session)
        return true
    }

    // MARK: - Assembly lifecycle

    private func makeAssembly(burstID: Data, peerID: PeerID, scope: VoiceBurstScope, nickname: String, timestamp: Date) -> Assembly? {
        guard let fileURL = Self.makeIncomingURL(burstID: burstID) else { return nil }
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        let isPrivate = scope == .directMessage
        let message = BitchatMessage(
            sender: nickname,
            content: "\(MimeType.Category.audio.messagePrefix)\(fileURL.lastPathComponent)",
            timestamp: timestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: isPrivate,
            recipientNickname: isPrivate ? context.nickname : nil,
            senderPeerID: peerID
        )

        let assembly = Assembly(
            burstID: burstID,
            peerID: peerID,
            scope: scope,
            nickname: nickname,
            message: message,
            fileURL: fileURL,
            fileHandle: handle
        )

        // Full inbound pipeline: store append, unread, notification.
        switch scope {
        case .directMessage:
            context.handlePrivateMessage(message)
        case .publicMesh:
            context.handlePublicMessage(message)
        }

        // Live playback only when the user is looking at this conversation
        // with the app frontmost and live voice enabled.
        let isViewing = switch scope {
        case .directMessage: context.selectedPrivateChatPeer == peerID
        case .publicMesh: context.isViewingPublicMeshTimeline
        }
        if PTTSettings.liveVoiceEnabled, PTTSettings.isAppActive, isViewing {
            assembly.player = PTTBurstPlayer()
        }

        SecureLogger.debug("PTT: burst \(burstID.hexEncodedString()) started from \(peerID.id.prefix(8))…", category: .session)
        return assembly
    }

    /// Keeps the composer's floor-courtesy indicator pointing at whoever is
    /// currently talking live in the public mesh channel.
    private func updatePublicTalkerIndicator() {
        let talker = assemblies.values.first { $0.scope == .publicMesh }?.nickname
        context.setActivePublicVoiceTalker(talker)
    }

    private func apply(_ packet: VoiceBurstPacket, to assembly: Assembly) {
        assembly.receivedBytes += packet.encode().count
        let elapsed = Date().timeIntervalSince(assembly.firstPacketAt)
        // Flood guards: a real burst arrives at ~2 KB/s.
        guard assembly.receivedBytes <= TransportConfig.pttInboundMaxBytesPerSecond * Int(elapsed + 2),
              assembly.receivedBytes <= TransportConfig.pttMaxBurstBytes
        else {
            SecureLogger.warning("PTT: burst from \(assembly.peerID.id.prefix(8))… exceeded rate/size caps — finalizing", category: .security)
            finalize(assembly)
            return
        }

        rescheduleIdleTimeout(for: assembly)

        switch packet.kind {
        case .start(let codec):
            guard codec == .aacLC16kMono else {
                // Codec we can't decode: drop the burst; the finalized note
                // (whose MIME/magic the file handler validates) still arrives.
                cancelAssembly(assembly)
                return
            }
        case .frames(let frames):
            guard packet.seq >= assembly.nextSeq, assembly.buffered[packet.seq] == nil else { return }
            assembly.buffered[packet.seq] = frames
            drainInOrder(assembly)
        case .end(let totalDataPackets, let durationMs):
            assembly.endInfo = (totalDataPackets, durationMs)
            drainInOrder(assembly)
            finalizeIfComplete(assembly)
        case .canceled:
            cancelAssembly(assembly)
        }
    }

    private func drainInOrder(_ assembly: Assembly) {
        while true {
            if let frames = assembly.buffered.removeValue(forKey: assembly.nextSeq) {
                deliver(frames, to: assembly)
                assembly.nextSeq &+= 1
                assembly.gapSince = nil
                continue
            }
            guard !assembly.buffered.isEmpty else {
                assembly.gapSince = nil
                return
            }
            // Packets buffered ahead of a hole.
            if let since = assembly.gapSince {
                guard Date().timeIntervalSince(since) >= Self.gapSkipSeconds,
                      let smallest = assembly.buffered.keys.min()
                else { return }
                // Give up on the missing packet(s); playback underrun already
                // covered the audible gap.
                assembly.nextSeq = smallest
                assembly.gapSince = nil
            } else {
                assembly.gapSince = Date()
                scheduleGapRedrain(for: assembly)
                return
            }
        }
    }

    private func deliver(_ frames: [Data], to assembly: Assembly) {
        for frame in frames {
            do {
                try assembly.fileHandle?.write(contentsOf: ADTSFramer.frame(frame))
            } catch {
                SecureLogger.error("PTT: incoming burst write failed: \(error)", category: .session)
                assembly.fileHandle = nil
            }
        }
        assembly.deliveredFrames += frames.count
        assembly.player?.enqueue(frames)
    }

    private func finalizeIfComplete(_ assembly: Assembly) {
        guard let end = assembly.endInfo else { return }
        // All data packets delivered when nextSeq passed the last one
        // (data seqs are 1...totalDataPackets). Otherwise stragglers may
        // still arrive; the gap-redrain or idle timeout closes the burst.
        if assembly.nextSeq > end.totalDataPackets {
            finalize(assembly)
        }
    }

    private func finalize(_ assembly: Assembly) {
        assembly.idleTimeout?.cancel()
        assembly.gapRedrain?.cancel()
        // Deliver whatever is decodable past any remaining holes.
        while !assembly.buffered.isEmpty, let smallest = assembly.buffered.keys.min() {
            assembly.nextSeq = smallest
            if let frames = assembly.buffered.removeValue(forKey: smallest) {
                deliver(frames, to: assembly)
                assembly.nextSeq &+= 1
            }
        }
        try? assembly.fileHandle?.close()
        assembly.fileHandle = nil
        assemblies.removeValue(forKey: assembly.burstID)
        updatePublicTalkerIndicator()

        guard assembly.deliveredFrames > 0 else {
            // Nothing audible ever arrived — drop the empty bubble.
            removeBubble(of: assembly)
            try? FileManager.default.removeItem(at: assembly.fileURL)
            context.notifyUIChanged()
            return
        }

        assembly.player?.finishAfterDrain()
        // The bubble's waveform may have been computed from a partial file.
        WaveformCache.shared.purge(url: assembly.fileURL)
        // Republish so the row re-renders without its LIVE treatment even if
        // no finalized note ever arrives to swap in.
        republishBubble(of: assembly)

        pruneFinishedBursts()
        finishedBursts[assembly.burstID] = FinishedBurst(
            messageID: assembly.messageID,
            peerID: assembly.peerID,
            scope: assembly.scope,
            fileURL: assembly.fileURL,
            messageTimestamp: assembly.messageTimestamp,
            expiresAt: Date().addingTimeInterval(TransportConfig.pttFinishedBurstRegistrySeconds)
        )
        context.notifyUIChanged()
        SecureLogger.debug("PTT: burst \(assembly.burstID.hexEncodedString()) finalized (\(assembly.deliveredFrames) frames)", category: .session)
    }

    private func removeBubble(of assembly: Assembly) {
        switch assembly.scope {
        case .directMessage:
            context.removePrivateMessage(withID: assembly.messageID)
        case .publicMesh:
            context.removeMessage(withID: assembly.messageID, cleanupFile: false)
        }
    }

    private func republishBubble(of assembly: Assembly) {
        switch assembly.scope {
        case .directMessage:
            context.upsertPrivateMessage(assembly.message, in: assembly.peerID)
        case .publicMesh:
            context.upsertPublicMeshMessage(assembly.message)
        }
    }

    private func cancelAssembly(_ assembly: Assembly) {
        assembly.idleTimeout?.cancel()
        assembly.gapRedrain?.cancel()
        assembly.player?.stop()
        try? assembly.fileHandle?.close()
        assembly.fileHandle = nil
        assemblies.removeValue(forKey: assembly.burstID)
        updatePublicTalkerIndicator()
        removeBubble(of: assembly)
        WaveformCache.shared.purge(url: assembly.fileURL)
        try? FileManager.default.removeItem(at: assembly.fileURL)
        context.notifyUIChanged()
    }

    // MARK: - Timers

    private func rescheduleIdleTimeout(for assembly: Assembly) {
        assembly.idleTimeout?.cancel()
        let burstID = assembly.burstID
        assembly.idleTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(TransportConfig.pttBurstEndTimeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, let assembly = self.assemblies[burstID] else { return }
            // Talker went silent/out of range without an END.
            self.finalize(assembly)
        }
    }

    private func scheduleGapRedrain(for assembly: Assembly) {
        assembly.gapRedrain?.cancel()
        let burstID = assembly.burstID
        assembly.gapRedrain = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.gapSkipSeconds + 0.05) * 1_000_000_000))
            guard !Task.isCancelled, let self, let assembly = self.assemblies[burstID] else { return }
            self.drainInOrder(assembly)
            self.finalizeIfComplete(assembly)
        }
    }

    // MARK: - Helpers

    private func pruneFinishedBursts() {
        let now = Date()
        finishedBursts = finishedBursts.filter { $0.value.expiresAt > now }
        while finishedBursts.count >= Self.finishedBurstsCap {
            guard let oldest = finishedBursts.min(by: { $0.value.expiresAt < $1.value.expiresAt }) else { break }
            finishedBursts.removeValue(forKey: oldest.key)
        }
    }

    /// Extracts the 8-byte burst ID from a finalized note's file name
    /// (`voice_<16 hex>.m4a`, possibly uniquified by the incoming file store).
    static func burstID(fromVoiceFileName fileName: String) -> Data? {
        guard fileName.hasPrefix("voice_") else { return nil }
        let afterPrefix = fileName.dropFirst("voice_".count)
        let hex = String(afterPrefix.prefix(16))
        guard hex.count == 16, hex.allSatisfy(\.isHexDigit) else { return nil }
        return Data(hexString: hex)
    }

    private static func makeIncomingURL(burstID: Data) -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let directory = base
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent("\(MimeType.Category.audio.mediaDir)/incoming", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            return nil
        }
        return directory.appendingPathComponent("voice_live_\(burstID.hexEncodedString()).aac")
    }
}
