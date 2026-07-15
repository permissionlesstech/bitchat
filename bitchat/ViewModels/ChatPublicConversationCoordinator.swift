import BitFoundation
import BitLogger
import CoreBluetooth
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The narrow surface `ChatPublicConversationCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`. This keeps the coordinator independently
/// testable (see `ChatPublicConversationCoordinatorContextTests`) and makes
/// its true dependencies explicit. The surface is intentionally large — it
/// documents the coordinator's real coupling to the public timeline, the
/// conversation stores, geohash participants, and the inbound public message
/// pipeline.
@MainActor
protocol ChatPublicConversationContext: AnyObject {
    // MARK: Channel state
    var activeChannel: ChannelID { get }
    var currentGeohash: String? { get }
    var nickname: String { get }
    var myPeerID: PeerID { get }
    /// Publishes the public-timeline batching state (UI animation suppression).
    /// (Single mutation path for the owner's `isBatchingPublic`; this
    /// coordinator never reads it.)
    func setPublicBatching(_ isBatching: Bool)
    /// Signals that message state changed so observers refresh (e.g. `objectWillChange.send()`).
    func notifyUIChanged()

    // MARK: Public conversation store (single-writer intents)
    /// Appends a public message in timestamp order. Returns `false` when a
    /// message with the same ID is already in that conversation.
    @discardableResult
    func appendPublicMessage(_ message: BitchatMessage, to conversationID: ConversationID) -> Bool
    func publicConversationContainsMessage(withID messageID: String, in conversationID: ConversationID) -> Bool
    /// Removes a message by ID from whichever public conversation contains it.
    @discardableResult
    func removePublicMessage(withID messageID: String) -> BitchatMessage?
    /// Removes every matching message from a geohash conversation (block purge).
    func removePublicMessages(fromGeohash geohash: String, where predicate: (BitchatMessage) -> Bool)
    /// Empties a public conversation's timeline (`/clear`).
    func clearPublicConversation(_ conversationID: ConversationID)
    /// Queues a system message for the next geohash channel visit.
    func queueGeohashSystemMessage(_ content: String)

    // MARK: Private chats (block cleanup & message removal)
    /// Removes the peer's chat entirely, including unread state
    /// (single-writer store intent; no-op for unknown peers).
    func removePrivateChat(_ peerID: PeerID)
    /// Removes a message by ID from every private chat containing it,
    /// dropping chats that become empty. Returns the removed message.
    @discardableResult
    func removePrivateMessage(withID messageID: String) -> BitchatMessage?
    func cleanupLocalFile(forMessage message: BitchatMessage)

    // MARK: Geohash participants & presence
    var geoNicknames: [String: String] { get }
    var isTeleported: Bool { get }
    var nostrKeyMapping: [PeerID: String] { get }
    /// Drops every key mapping that resolves to the given (lowercased) Nostr pubkey.
    func removeNostrKeyMappings(matchingPubkeyHexLowercased hex: String)
    func visibleGeoPeople() -> [GeoPerson]
    func geoParticipantCount(for geohash: String) -> Int
    func removeGeoParticipant(pubkeyHex: String)

    // MARK: Nostr identity & blocking (shared with the other contexts)
    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity
    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool
    func setNostrBlocked(_ pubkeyHexLowercased: String, isBlocked: Bool)

    // MARK: Mesh transport
    func meshPeerNicknames() -> [PeerID: String]
    func sendMeshMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date)

    // MARK: Inbound public message processing
    func processActionMessage(_ message: BitchatMessage) -> BitchatMessage
    func isMessageBlocked(_ message: BitchatMessage) -> Bool
    /// `powBits` is the validated NIP-13 difficulty of the source Nostr event
    /// (0 for mesh messages); sufficient PoW relaxes the per-sender bucket.
    func allowPublicMessage(senderKey: String, contentKey: String, powBits: Int) -> Bool
    /// Buffers a visible-channel message for the batched (~80 ms) pipeline
    /// flush, which commits it to `conversationID` in the store.
    func enqueuePublicMessage(_ message: BitchatMessage, to conversationID: ConversationID)
    func cachedStablePeerID(for shortPeerID: PeerID) -> PeerID?

    // MARK: Content dedup & formatting
    func normalizedContentKey(_ content: String) -> String
    func contentTimestamp(forKey key: String) -> Date?
    func recordContentKey(_ key: String, timestamp: Date)
    /// Pre-renders the message so the formatting cache is warm before display.
    func prewarmMessageFormatting(_ message: BitchatMessage)

    // MARK: Notifications
    /// Posts the you-were-mentioned local notification.
    func notifyMention(from sender: String, message: String)
}

extension ChatViewModel: ChatPublicConversationContext {
    // `unreadPrivateMessages`, `nostrKeyMapping`,
    // `nickname`, `activeChannel`, `currentGeohash`, `geoNicknames`,
    // `myPeerID`, `isTeleported`, `notifyUIChanged()`,
    // `geoParticipantCount(for:)`, `isNostrBlocked(pubkeyHexLowercased:)`,
    // `deriveNostrIdentity(forGeohash:)`, the public conversation store
    // intents (`appendPublicMessage(_:to:)`,
    // `publicConversationContainsMessage(withID:in:)`,
    // `removePublicMessage(withID:)`,
    // `removePublicMessages(fromGeohash:where:)`,
    // `clearPublicConversation(_:)`, and `queueGeohashSystemMessage(_:)`)
    // are shared requirements with `ChatDeliveryContext` /
    // `ChatPrivateConversationContext` / `ChatNostrContext` or satisfied by
    // existing `ChatViewModel` members. The members below flatten nested
    // service accesses into intent-named calls.

    func visibleGeoPeople() -> [GeoPerson] {
        participantTracker.getVisiblePeople()
    }

    func removeGeoParticipant(pubkeyHex: String) {
        participantTracker.removeParticipant(pubkeyHex: pubkeyHex)
    }

    func setNostrBlocked(_ pubkeyHexLowercased: String, isBlocked: Bool) {
        identityManager.setNostrBlocked(pubkeyHexLowercased, isBlocked: isBlocked)
    }

    func meshPeerNicknames() -> [PeerID: String] {
        meshService.getPeerNicknames()
    }

    func sendMeshMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date) {
        meshService.sendMessage(content, mentions: mentions, messageID: messageID, timestamp: timestamp)
    }

    func allowPublicMessage(senderKey: String, contentKey: String, powBits: Int) -> Bool {
        publicRateLimiter.allow(senderKey: senderKey, contentKey: contentKey, powBits: powBits)
    }

    func enqueuePublicMessage(_ message: BitchatMessage, to conversationID: ConversationID) {
        publicMessagePipeline.enqueue(message, to: conversationID)
    }

    func normalizedContentKey(_ content: String) -> String {
        deduplicationService.normalizedContentKey(content)
    }

    func contentTimestamp(forKey key: String) -> Date? {
        deduplicationService.contentTimestamp(forKey: key)
    }

    func recordContentKey(_ key: String, timestamp: Date) {
        deduplicationService.recordContentKey(key, timestamp: timestamp)
    }

    func prewarmMessageFormatting(_ message: BitchatMessage) {
        _ = formatMessageAsText(message, colorScheme: currentColorScheme)
    }

    func notifyMention(from sender: String, message: String) {
        NotificationService.shared.sendMentionNotification(from: sender, message: message)
    }
}

@MainActor
final class ChatPublicConversationCoordinator: PublicMessagePipelineDelegate {
    private unowned let context: any ChatPublicConversationContext

    init(context: any ChatPublicConversationContext) {
        self.context = context
    }

    func visibleGeohashPeople() -> [GeoPerson] {
        context.visibleGeoPeople()
    }

    func getVisibleGeoParticipants() -> [CommandGeoParticipant] {
        visibleGeohashPeople().map { CommandGeoParticipant(id: $0.id, displayName: $0.displayName) }
    }

    func geohashParticipantCount(for geohash: String) -> Int {
        context.geoParticipantCount(for: geohash)
    }

    func displayNameForPubkey(_ pubkeyHex: String) -> String {
        displayNameForNostrPubkey(pubkeyHex)
    }

    func isBlocked(_ pubkeyHexLowercased: String) -> Bool {
        context.isNostrBlocked(pubkeyHexLowercased: pubkeyHexLowercased)
    }

    func isGeohashUserBlocked(pubkeyHexLowercased: String) -> Bool {
        context.isNostrBlocked(pubkeyHexLowercased: pubkeyHexLowercased)
    }

    func blockGeohashUser(pubkeyHexLowercased: String, displayName: String) {
        let hex = pubkeyHexLowercased.lowercased()
        context.setNostrBlocked(hex, isBlocked: true)
        context.removeGeoParticipant(pubkeyHex: hex)

        if let gh = context.currentGeohash {
            let predicate: (BitchatMessage) -> Bool = { [unowned context] message in
                guard let senderPeerID = message.senderPeerID,
                      senderPeerID.isGeoDM || senderPeerID.isGeoChat else {
                    return false
                }
                if let full = context.nostrKeyMapping[senderPeerID]?.lowercased() {
                    return full == hex
                }
                return false
            }
            context.removePublicMessages(fromGeohash: gh, where: predicate)
        }

        // The store intent no-ops when no such chat exists.
        context.removePrivateChat(PeerID(nostr_: hex))

        context.removeNostrKeyMappings(matchingPubkeyHexLowercased: hex)

        addSystemMessage(
            String(
                format: String(
                    localized: "system.geohash.blocked",
                    comment: "System message shown when a user is blocked in geohash chats"
                ),
                locale: .current,
                displayName
            )
        )
    }

    func unblockGeohashUser(pubkeyHexLowercased: String, displayName: String) {
        context.setNostrBlocked(pubkeyHexLowercased, isBlocked: false)
        addSystemMessage(
            String(
                format: String(
                    localized: "system.geohash.unblocked",
                    comment: "System message shown when a user is unblocked in geohash chats"
                ),
                locale: .current,
                displayName
            )
        )
    }

    func displayNameForNostrPubkey(_ pubkeyHex: String) -> String {
        let suffix = String(pubkeyHex.suffix(4))
        if let geohash = context.currentGeohash,
           let myGeoIdentity = try? context.deriveNostrIdentity(forGeohash: geohash),
           myGeoIdentity.publicKeyHex.lowercased() == pubkeyHex.lowercased() {
            return context.nickname + "#" + suffix
        }
        if let nick = context.geoNicknames[pubkeyHex.lowercased()], !nick.isEmpty {
            return nick + "#" + suffix
        }
        return "anon#\(suffix)"
    }

    func currentPublicSender() -> (name: String, peerID: PeerID) {
        var displaySender = context.nickname
        var senderPeerID = context.myPeerID
        if case .location(let channel) = context.activeChannel,
           let identity = try? context.deriveNostrIdentity(forGeohash: channel.geohash) {
            let suffix = String(identity.publicKeyHex.suffix(4))
            displaySender = context.nickname + "#" + suffix
            senderPeerID = PeerID(nostr: identity.publicKeyHex)
        }
        return (displaySender, senderPeerID)
    }

    func removeMessage(withID messageID: String, cleanupFile: Bool = false) {
        var removedMessage = context.removePublicMessage(withID: messageID)

        if let removedPrivateMessage = context.removePrivateMessage(withID: messageID) {
            removedMessage = removedMessage ?? removedPrivateMessage
        }

        if cleanupFile, let removedMessage {
            context.cleanupLocalFile(forMessage: removedMessage)
        }

        context.notifyUIChanged()
    }

    func clearCurrentPublicTimeline() {
        context.clearPublicConversation(ConversationID(channelID: context.activeChannel))

        // Clearing the mesh timeline also dismisses its archived echoes for
        // good: the watermark stops the next launch from re-seeding them
        // (the archive itself keeps carrying the messages for peers), and
        // the dedup keys go so a cleared message arriving live shows again.
        if case .mesh = context.activeChannel {
            MeshEchoSettings.clearedThrough = Date()
            archivedEchoKeys.removeAll()
        }

        // The SPM test process shares the real Application Support tree, so this
        // detached deletion can land mid-test under parallel scheduling and flake
        // a file-dependent test. Tests never need the on-disk media cleared.
        guard !TestEnvironment.isRunningTests else { return }

        Task.detached(priority: .utility) {
            // Skipped under tests: the test process shares the user's real
            // ~/Library/Application Support/files tree, and this detached
            // wipe fires at a nondeterministic time — racing tests that
            // write media there (see the same guard in panicClearAllData).
            guard !TestEnvironment.isRunningTests else { return }
            do {
                let base = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let filesDir = base.appendingPathComponent("files", isDirectory: true)
                let outgoingDirs = [
                    filesDir.appendingPathComponent("voicenotes/outgoing", isDirectory: true),
                    filesDir.appendingPathComponent("images/outgoing", isDirectory: true),
                    filesDir.appendingPathComponent("files/outgoing", isDirectory: true)
                ]

                for dir in outgoingDirs {
                    if FileManager.default.fileExists(atPath: dir.path) {
                        try? FileManager.default.removeItem(at: dir)
                        try? FileManager.default.createDirectory(
                            at: dir,
                            withIntermediateDirectories: true,
                            attributes: nil
                        )
                    }
                }
            } catch {
                SecureLogger.error("Failed to clear media files: \(error)", category: .session)
            }
        }
    }

    func addSystemMessage(_ content: String, timestamp: Date = Date()) {
        let systemMessage = BitchatMessage(
            sender: "system",
            content: content,
            timestamp: timestamp,
            isRelay: false
        )
        context.appendPublicMessage(systemMessage, to: ConversationID(channelID: context.activeChannel))
    }

    func addMeshOnlySystemMessage(_ content: String) {
        let systemMessage = BitchatMessage(
            sender: "system",
            content: content,
            timestamp: Date(),
            isRelay: false
        )
        context.appendPublicMessage(systemMessage, to: .mesh)
    }

    func addPublicSystemMessage(_ content: String) {
        let systemMessage = BitchatMessage(
            sender: "system",
            content: content,
            timestamp: Date(),
            isRelay: false
        )
        context.appendPublicMessage(systemMessage, to: ConversationID(channelID: context.activeChannel))
        let contentKey = context.normalizedContentKey(systemMessage.content)
        context.recordContentKey(contentKey, timestamp: systemMessage.timestamp)
    }

    func addGeohashOnlySystemMessage(_ content: String) {
        if case .location = context.activeChannel {
            addPublicSystemMessage(content)
        } else {
            context.queueGeohashSystemMessage(content)
        }
    }

    func sendPublicRaw(_ content: String) {
        if case .location(let channel) = context.activeChannel {
            Task { @MainActor [weak context] in
                guard let context else { return }
                do {
                    let identity = try context.deriveNostrIdentity(forGeohash: channel.geohash)
                    let event = try await NostrProtocol.createMinedEphemeralGeohashEvent(
                        content: content,
                        geohash: channel.geohash,
                        senderIdentity: identity,
                        nickname: context.nickname,
                        teleported: context.isTeleported
                    )
                    let targetRelays = GeoRelayDirectory.shared.closestRelays(toGeohash: channel.geohash, count: 5)
                    if targetRelays.isEmpty {
                        NostrRelayManager.shared.sendEvent(event)
                    } else {
                        NostrRelayManager.shared.sendEvent(event, to: targetRelays)
                    }
                } catch {
                    SecureLogger.error("❌ Failed to send geohash raw message: \(error)", category: .session)
                }
            }
            return
        }

        context.sendMeshMessage(
            content,
            mentions: [],
            messageID: UUID().uuidString,
            timestamp: Date()
        )
    }

    /// - Parameter powBits: validated NIP-13 difficulty of the source Nostr
    ///   event (0 for mesh messages). Sufficient PoW relaxes the per-sender
    ///   rate limit; low/no-PoW events keep the strict limits so old clients
    ///   still get through at normal rates.
    /// Identity keys of the archived echoes seeded into the mesh timeline at
    /// launch. Re-synced copies of others' messages now arrive with the same
    /// derived stable ID (`MeshMessageIdentity`), so the store's insert-by-ID
    /// catches those — but the archive-restored rows themselves carry
    /// `echo-`-prefixed IDs, and self echoes get fresh UUIDs, so this content
    /// identity remains the way to recognize a live copy of an
    /// already-rendered echo.
    private var archivedEchoKeys = Set<String>()

    func registerArchivedEcho(senderPeerID: PeerID?, timestamp: Date, content: String) {
        archivedEchoKeys.insert(Self.archivedEchoKey(senderPeerID: senderPeerID, timestamp: timestamp, content: content))
    }

    static func archivedEchoKey(senderPeerID: PeerID?, timestamp: Date, content: String) -> String {
        let ms = UInt64((timestamp.timeIntervalSince1970 * 1000).rounded())
        return "\(senderPeerID?.id ?? "")|\(ms)|\(content)"
    }

    func handlePublicMessage(_ message: BitchatMessage, powBits: Int = 0) {
        let finalMessage = context.processActionMessage(message)
        if context.isMessageBlocked(finalMessage) { return }

        let isGeo = finalMessage.senderPeerID?.isGeoChat == true
        let isSystem = finalMessage.sender == "system"
        let shouldRateLimit = !isSystem || finalMessage.senderPeerID != nil
        if shouldRateLimit {
            let senderKey = normalizedSenderKey(for: finalMessage)
            let contentKey = context.normalizedContentKey(finalMessage.content)
            if !context.allowPublicMessage(senderKey: senderKey, contentKey: contentKey, powBits: powBits) {
                return
            }
        }

        if !isSystem && finalMessage.content.count > 16000 { return }
        // Empty content never rendered before (the old visible-array enqueue
        // filtered it); with the store as the sole timeline it is dropped
        // outright instead of lingering invisibly in a backing buffer.
        guard !finalMessage.content.trimmed.isEmpty else { return }

        // Resolve the destination conversation. System messages surface on
        // the active channel (matching their old visible-only routing); geo
        // messages require a current geohash, mesh messages always land in
        // the mesh conversation.
        let destination: ConversationID?
        if isSystem {
            destination = ConversationID(channelID: context.activeChannel)
        } else if isGeo {
            destination = context.currentGeohash.map { .geohash($0.lowercased()) }
        } else {
            destination = .mesh
        }
        guard let destination else { return }

        // A live copy of a message already rendered as an archived echo
        // (e.g. re-served by a peer's gossip sync) would duplicate the row.
        if destination == .mesh, !isSystem {
            let key = Self.archivedEchoKey(
                senderPeerID: finalMessage.senderPeerID,
                timestamp: finalMessage.timestamp,
                content: finalMessage.content
            )
            if archivedEchoKeys.contains(key) { return }
        }

        let channelMatches: Bool = {
            switch context.activeChannel {
            case .mesh: return !isGeo || isSystem
            case .location: return isGeo || isSystem
            }
        }()

        if channelMatches {
            // Visible-channel arrivals are batched: the pipeline's ~80 ms
            // flush commits them to the store (which dedups by ID), keeping
            // the deliberate UI flush cadence.
            guard !context.publicConversationContainsMessage(withID: finalMessage.id, in: destination) else { return }
            context.enqueuePublicMessage(finalMessage, to: destination)
        } else {
            // Background-channel arrivals have no rendering observers to
            // batch for; they land in the store immediately.
            context.appendPublicMessage(finalMessage, to: destination)
        }
    }

    func checkForMentions(_ message: BitchatMessage) {
        var myTokens: Set<String> = [context.nickname]
        let meshPeers = context.meshPeerNicknames()
        let collisions = meshPeers.values.filter { $0.hasPrefix(context.nickname + "#") }
        if !collisions.isEmpty {
            let suffix = "#" + String(context.myPeerID.id.prefix(4))
            myTokens = [context.nickname + suffix]
        }
        let isMentioned = message.mentions?.contains(where: myTokens.contains) ?? false

        if isMentioned && message.sender != context.nickname {
            SecureLogger.info("🔔 Mention from \(message.sender)", category: .session)
            context.notifyMention(from: message.sender, message: message.content)
        }
    }

    func sendHapticFeedback(for message: BitchatMessage) {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }

        var tokens: [String] = [context.nickname]
        switch context.activeChannel {
        case .location(let channel):
            if let identity = try? context.deriveNostrIdentity(forGeohash: channel.geohash) {
                tokens.append(context.nickname + "#" + String(identity.publicKeyHex.suffix(4)))
            }
        case .mesh:
            break
        }

        let hugsMe = tokens.contains { message.content.contains("hugs \($0)") } || message.content.contains("hugs you")
        let slapsMe = tokens.contains { message.content.contains("slaps \($0) around") } || message.content.contains("slaps you around")
        let isHugForMe = message.content.contains("🫂") && hugsMe
        let isSlapForMe = message.content.contains("🐟") && slapsMe

        if isHugForMe && message.sender != context.nickname {
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.prepare()

            for i in 0..<8 {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Double(i) * TransportConfig.uiBatchDispatchStaggerSeconds
                ) {
                    impactFeedback.impactOccurred()
                }
            }
        } else if isSlapForMe && message.sender != context.nickname {
            let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)
            impactFeedback.prepare()
            impactFeedback.impactOccurred()
        }
        #endif
    }

    func pipeline(_: PublicMessagePipeline, normalizeContent content: String) -> String {
        context.normalizedContentKey(content)
    }

    func pipeline(_: PublicMessagePipeline, contentTimestampForKey key: String) -> Date? {
        context.contentTimestamp(forKey: key)
    }

    func pipeline(_: PublicMessagePipeline, recordContentKey key: String, timestamp: Date) {
        context.recordContentKey(key, timestamp: timestamp)
    }

    func pipeline(_: PublicMessagePipeline, commit message: BitchatMessage, to conversationID: ConversationID) -> Bool {
        context.appendPublicMessage(message, to: conversationID)
    }

    func pipelinePrewarmMessage(_: PublicMessagePipeline, message: BitchatMessage) {
        context.prewarmMessageFormatting(message)
    }

    func pipelineSetBatchingState(_: PublicMessagePipeline, isBatching: Bool) {
        context.setPublicBatching(isBatching)
    }
}

private extension ChatPublicConversationCoordinator {
    func normalizedSenderKey(for message: BitchatMessage) -> String {
        if let senderPeerID = message.senderPeerID {
            if senderPeerID.isGeoChat || senderPeerID.isGeoDM {
                let full = (context.nostrKeyMapping[senderPeerID] ?? senderPeerID.bare).lowercased()
                return "nostr:" + full
            } else if senderPeerID.id.count == 16,
                      let full = context.cachedStablePeerID(for: senderPeerID)?.id.lowercased() {
                return "noise:" + full
            } else {
                return "mesh:" + senderPeerID.id.lowercased()
            }
        }
        return "name:" + message.sender.lowercased()
    }
}
