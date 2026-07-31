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
    /// Appends directly to the public mesh timeline, bypassing the batched
    /// public pipeline: a live bubble must be removable when its burst is
    /// canceled or empty, which a pipeline-buffered entry is not (it would
    /// re-commit at the next flush).
    func appendPublicMeshMessage(_ message: BitchatMessage)
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

    func appendPublicMeshMessage(_ message: BitchatMessage) {
        _ = appendPublicMessage(message, to: ConversationID(channelID: .mesh))
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
enum VoiceBurstScope: Hashable {
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
    /// Burst IDs are sender-chosen, so they only identify a burst *within*
    /// an authenticated (peer, scope) pair: keying assemblies by the full
    /// triple stops an attacker who observed a public burst ID from racing
    /// a START to capture the real talker's frames.
    private struct AssemblyKey: Hashable {
        let peerID: PeerID
        let scope: VoiceBurstScope
        let burstID: Data
    }

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

        var key: AssemblyKey { AssemblyKey(peerID: peerID, scope: scope, burstID: burstID) }

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
    private let fileStore: BLEIncomingFileStore
    /// Captures live in the store's directories, so file operations go
    /// through the store's (injectable) file manager.
    private var fileManager: FileManager { fileStore.fileManager }
    private var assemblies: [AssemblyKey: Assembly] = [:]
    private var finishedBursts: [AssemblyKey: FinishedBurst] = [:]
    /// Players still draining after their assembly — the sole strong owner —
    /// was discarded on burst END. Without this hold the player deallocates
    /// mid-tail (or mid session-acquire, killing the whole burst's audio)
    /// and its registered session token would only be reclaimed by the
    /// deinit backstop. Entries remove themselves via `onStopped`.
    private var drainingPlayers: [ObjectIdentifier: PTTBurstPlayer] = [:]

    /// `sweepsOnInit` exists for tests whose coordinator shares the real
    /// application-support directory: they pass `false` so parallel test
    /// runs never sweep each other's in-flight capture files.
    init(context: any ChatLiveVoiceContext, fileStore: BLEIncomingFileStore = BLEIncomingFileStore(), sweepsOnInit: Bool = true) {
        self.context = context
        self.fileStore = fileStore
        // Orphaned partial captures from a previous session (live-only bursts
        // whose finalized note never arrived) are dead weight the quota can
        // never reclaim (eviction skips voice_live_* by design) — sweep them
        // on startup.
        if sweepsOnInit {
            sweepStaleLiveCaptures()
        }
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
        // Live voice off means classic-notes-only in both directions: no live
        // bubble, no partial file, no early notification — the finalized
        // voice note still arrives through the normal pipeline.
        guard PTTSettings.liveVoiceEnabled else {
            SecureLogger.debug("PTT: dropping inbound voice frame — live voice is toggled off", category: .session)
            return
        }
        guard let packet = VoiceBurstPacket.decode(payload) else {
            SecureLogger.warning("PTT: undecodable voice frame from \(peerID.id.prefix(8))… (\(payload.count) bytes: \(payload.prefix(16).hexEncodedString())…)", category: .session)
            return
        }
        guard !context.isPeerBlocked(peerID) else {
            SecureLogger.debug("PTT: dropping voice frame from blocked peer \(peerID.id.prefix(8))…", category: .session)
            return
        }

        // The sender is authenticated (Noise session or packet signature),
        // and the key binds the burst ID to that (peer, scope): a colliding
        // START from another peer opens its own assembly instead of
        // capturing this one's frames.
        let key = AssemblyKey(peerID: peerID, scope: scope, burstID: packet.burstID)
        if let assembly = assemblies[key] {
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
            assemblies[key] = assembly
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

        // Bind the note to the burst's authenticated sender and scope: an
        // attacker's burst reusing the same ID lives under its own key and
        // never matches the real sender's note (registry is capped at
        // `finishedBurstsCap`, so the linear scan is cheap).
        func matches(_ key: AssemblyKey) -> Bool {
            key.burstID == burstID
                && (message.senderPeerID == nil || key.peerID == message.senderPeerID)
                && message.isPrivate == (key.scope == .directMessage)
        }

        // The note usually lands after END, but a lost END or a fast transfer
        // can beat it — close out the live assembly first.
        if let assembly = assemblies.first(where: { matches($0.key) })?.value {
            finalize(assembly)
        }

        pruneFinishedBursts()
        guard let entry = finishedBursts.first(where: { matches($0.key) }) else { return false }
        let finished = entry.value

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
        try? fileManager.removeItem(at: finished.fileURL)
        finishedBursts.removeValue(forKey: entry.key)

        context.notifyUIChanged()
        SecureLogger.debug("PTT: absorbed finalized note for burst \(burstID.hexEncodedString())", category: .session)
        return true
    }

    // MARK: - Assembly lifecycle

    private func makeAssembly(burstID: Data, peerID: PeerID, scope: VoiceBurstScope, nickname: String, timestamp: Date) -> Assembly? {
        guard let fileURL = makeIncomingURL(burstID: burstID, peerID: peerID, scope: scope) else {
            SecureLogger.error("PTT: cannot resolve incoming media directory for burst \(burstID.hexEncodedString())", category: .session)
            return nil
        }
        // BCH-01-002: live captures share the incoming-media quota with
        // finalized transfers; reserve the burst's worst case up front.
        // Eviction skips voice_live_* names, so partials still streaming in
        // are safe no matter which caller triggers enforcement.
        fileStore.enforceQuota(reservingBytes: TransportConfig.pttMaxBurstBytes)
        fileManager.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            SecureLogger.error("PTT: cannot open capture file for burst \(burstID.hexEncodedString())", category: .session)
            try? fileManager.removeItem(at: fileURL)
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

        // DM bubbles ride the full inbound pipeline (store append, unread,
        // notification). Public bubbles append directly to the store: the
        // batched public pipeline can't purge a buffered entry if the burst
        // is canceled before the flush.
        switch scope {
        case .directMessage:
            context.handlePrivateMessage(message)
        case .publicMesh:
            context.appendPublicMeshMessage(message)
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
        assemblies.removeValue(forKey: assembly.key)
        updatePublicTalkerIndicator()

        guard assembly.deliveredFrames > 0 else {
            // Nothing audible ever arrived — drop the empty bubble.
            removeBubble(of: assembly)
            try? fileManager.removeItem(at: assembly.fileURL)
            context.notifyUIChanged()
            return
        }

        if let player = assembly.player, !player.stopped {
            // Park the draining player: this method just dropped the
            // assembly, and nothing else holds the player strongly. It may
            // still be playing out its tail — or still acquiring the audio
            // session off-main — so it must stay alive until it stops.
            let id = ObjectIdentifier(player)
            drainingPlayers[id] = player
            player.onStopped = { [weak self] in
                self?.drainingPlayers.removeValue(forKey: id)
            }
            player.finishAfterDrain()
        }
        // The bubble's waveform may have been computed from a partial file.
        WaveformCache.shared.purge(url: assembly.fileURL)
        // The capture is the bubble's replayable audio from here on (unless a
        // finalized note arrives to swap in): move it off its voice_live_
        // name so only genuinely in-flight files match the startup sweep and
        // the quota's live-capture guard — a kept fallback is never swept,
        // and it ages out of the quota like any finalized media.
        let fileURL = promoteToFallback(assembly.fileURL)
        // Republish so the row re-renders without its LIVE treatment — and
        // points at the promoted file — even if no note ever arrives.
        republishBubble(of: assembly, fileURL: fileURL)

        pruneFinishedBursts()
        finishedBursts[assembly.key] = FinishedBurst(
            messageID: assembly.messageID,
            peerID: assembly.peerID,
            scope: assembly.scope,
            fileURL: fileURL,
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

    private func republishBubble(of assembly: Assembly, fileURL: URL) {
        // Same row (same ID), content re-pointed at `fileURL`; the delivery
        // status is carried over because the inbound pipeline may have
        // updated it on the shared original.
        let message = BitchatMessage(
            id: assembly.messageID,
            sender: assembly.nickname,
            content: "\(MimeType.Category.audio.messagePrefix)\(fileURL.lastPathComponent)",
            timestamp: assembly.messageTimestamp,
            isRelay: false,
            isPrivate: assembly.scope == .directMessage,
            recipientNickname: assembly.scope == .directMessage ? context.nickname : nil,
            senderPeerID: assembly.peerID,
            deliveryStatus: assembly.message.deliveryStatus
        )
        switch assembly.scope {
        case .directMessage:
            context.upsertPrivateMessage(message, in: assembly.peerID)
        case .publicMesh:
            context.upsertPublicMeshMessage(message)
        }
    }

    /// Moves a finished capture off its `voice_live_` prefix (onto plain
    /// `voice_`), so the in-flight patterns — the startup sweep and the
    /// quota's eviction guard — only ever match captures still streaming in.
    /// On failure the live name is kept: worst case the file is reclaimed at
    /// the next startup, exactly the pre-promotion behavior.
    private func promoteToFallback(_ liveURL: URL) -> URL {
        let liveName = liveURL.lastPathComponent
        guard liveName.hasPrefix(BLEIncomingFileStore.liveCapturePrefix) else { return liveURL }
        let fallbackName = "voice_" + liveName.dropFirst(BLEIncomingFileStore.liveCapturePrefix.count)
        let destination = liveURL.deletingLastPathComponent().appendingPathComponent(fallbackName)
        do {
            // A leftover from an earlier burst that reused the same
            // (peer, scope, burstID) triple would block the move.
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: liveURL, to: destination)
            return destination
        } catch {
            SecureLogger.warning("PTT: keeping live-capture name for finished burst — promotion failed: \(error)", category: .session)
            return liveURL
        }
    }

    private func cancelAssembly(_ assembly: Assembly) {
        assembly.idleTimeout?.cancel()
        assembly.gapRedrain?.cancel()
        assembly.player?.stop()
        try? assembly.fileHandle?.close()
        assembly.fileHandle = nil
        assemblies.removeValue(forKey: assembly.key)
        updatePublicTalkerIndicator()
        removeBubble(of: assembly)
        WaveformCache.shared.purge(url: assembly.fileURL)
        try? fileManager.removeItem(at: assembly.fileURL)
        context.notifyUIChanged()
    }

    // MARK: - Timers

    private func rescheduleIdleTimeout(for assembly: Assembly) {
        assembly.idleTimeout?.cancel()
        let key = assembly.key
        assembly.idleTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(TransportConfig.pttBurstEndTimeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, let assembly = self.assemblies[key] else { return }
            // Talker went silent/out of range without an END.
            self.finalize(assembly)
        }
    }

    private func scheduleGapRedrain(for assembly: Assembly) {
        assembly.gapRedrain?.cancel()
        let key = assembly.key
        assembly.gapRedrain = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.gapSkipSeconds + 0.05) * 1_000_000_000))
            guard !Task.isCancelled, let self, let assembly = self.assemblies[key] else { return }
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

    private static let incomingSubdirectory = "\(MimeType.Category.audio.mediaDir)/incoming"

    /// The peer ID and scope in the name mirror the assembly key: colliding
    /// burst IDs from different senders — or from the same sender across DM
    /// and public — land on distinct files instead of truncating each other.
    /// `burstID(fromVoiceFileName:)` still rejects every `voice_live_*` name,
    /// so live captures can never absorb a note.
    private func makeIncomingURL(burstID: Data, peerID: PeerID, scope: VoiceBurstScope) -> URL? {
        guard let directory = try? fileStore.incomingDirectory(subdirectory: Self.incomingSubdirectory) else { return nil }
        let scopeTag = scope == .directMessage ? "dm" : "mesh"
        return directory.appendingPathComponent("\(BLEIncomingFileStore.liveCapturePrefix)\(burstID.hexEncodedString())_\(peerID.id)_\(scopeTag).aac")
    }

    /// Deletes partial live captures left behind by a previous session.
    /// In-session cleanup needs no sweep: absorb, cancel, and empty-finalize
    /// delete their capture file, and finalize promotes keepers off the
    /// `voice_live_` name. So anything the sweep matches was orphaned by a
    /// crash mid-burst — safe to delete, because chat rows are in-memory
    /// only (ConversationStore never persists; the gossip archive replays
    /// `MessageType.message` packets only), so no row from a previous
    /// process can reference the file.
    private func sweepStaleLiveCaptures() {
        guard let directory = try? fileStore.incomingDirectory(subdirectory: Self.incomingSubdirectory),
              let contents = try? fileManager.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else { return }
        for url in contents where url.lastPathComponent.hasPrefix(BLEIncomingFileStore.liveCapturePrefix) && url.pathExtension == "aac" {
            try? fileManager.removeItem(at: url)
        }
    }
}
