import BitFoundation
import BitLogger
import CoreBluetooth
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

@MainActor
final class ChatPublicConversationCoordinator: PublicMessagePipelineDelegate {
    private unowned let viewModel: ChatViewModel

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    func visibleGeohashPeople() -> [GeoPerson] {
        viewModel.participantTracker.getVisiblePeople()
    }

    func getVisibleGeoParticipants() -> [CommandGeoParticipant] {
        visibleGeohashPeople().map { CommandGeoParticipant(id: $0.id, displayName: $0.displayName) }
    }

    func geohashParticipantCount(for geohash: String) -> Int {
        viewModel.participantTracker.participantCount(for: geohash)
    }

    func displayNameForPubkey(_ pubkeyHex: String) -> String {
        displayNameForNostrPubkey(pubkeyHex)
    }

    func isBlocked(_ pubkeyHexLowercased: String) -> Bool {
        viewModel.identityManager.isNostrBlocked(pubkeyHexLowercased: pubkeyHexLowercased)
    }

    func isGeohashUserBlocked(pubkeyHexLowercased: String) -> Bool {
        viewModel.identityManager.isNostrBlocked(pubkeyHexLowercased: pubkeyHexLowercased)
    }

    func blockGeohashUser(pubkeyHexLowercased: String, displayName: String) {
        let hex = pubkeyHexLowercased.lowercased()
        viewModel.identityManager.setNostrBlocked(hex, isBlocked: true)
        viewModel.participantTracker.removeParticipant(pubkeyHex: hex)

        if let gh = viewModel.currentGeohash {
            let predicate: (BitchatMessage) -> Bool = { [unowned viewModel] message in
                guard let senderPeerID = message.senderPeerID,
                      senderPeerID.isGeoDM || senderPeerID.isGeoChat else {
                    return false
                }
                if let full = viewModel.nostrKeyMapping[senderPeerID]?.lowercased() {
                    return full == hex
                }
                return false
            }
            viewModel.timelineStore.removeMessages(in: gh, where: predicate)
            synchronizePublicConversationStore(forGeohash: gh)
            if case .location = viewModel.activeChannel {
                viewModel.messages.removeAll(where: predicate)
            }
        }

        let conversationPeerID = PeerID(nostr_: hex)
        if viewModel.privateChats[conversationPeerID] != nil {
            var privateChats = viewModel.privateChats
            privateChats.removeValue(forKey: conversationPeerID)
            viewModel.privateChats = privateChats

            var unread = viewModel.unreadPrivateMessages
            unread.remove(conversationPeerID)
            viewModel.unreadPrivateMessages = unread
        }

        for (key, value) in viewModel.nostrKeyMapping where value.lowercased() == hex {
            viewModel.nostrKeyMapping.removeValue(forKey: key)
        }

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
        viewModel.identityManager.setNostrBlocked(pubkeyHexLowercased, isBlocked: false)
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
        if let geohash = viewModel.currentGeohash,
           let myGeoIdentity = try? viewModel.idBridge.deriveIdentity(forGeohash: geohash),
           myGeoIdentity.publicKeyHex.lowercased() == pubkeyHex.lowercased() {
            return viewModel.nickname + "#" + suffix
        }
        if let nick = viewModel.geoNicknames[pubkeyHex.lowercased()], !nick.isEmpty {
            return nick + "#" + suffix
        }
        return "anon#\(suffix)"
    }

    func currentPublicSender() -> (name: String, peerID: PeerID) {
        var displaySender = viewModel.nickname
        var senderPeerID = viewModel.meshService.myPeerID
        if case .location(let channel) = viewModel.activeChannel,
           let identity = try? viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash) {
            let suffix = String(identity.publicKeyHex.suffix(4))
            displaySender = viewModel.nickname + "#" + suffix
            senderPeerID = PeerID(nostr: identity.publicKeyHex)
        }
        return (displaySender, senderPeerID)
    }

    func removeMessage(withID messageID: String, cleanupFile: Bool = false) {
        var removedMessage: BitchatMessage?

        if let index = viewModel.messages.firstIndex(where: { $0.id == messageID }) {
            removedMessage = viewModel.messages.remove(at: index)
        }

        if let storeRemoved = viewModel.timelineStore.removeMessage(withID: messageID) {
            removedMessage = removedMessage ?? storeRemoved
            synchronizeAllPublicConversationStores()
        }

        var chats = viewModel.privateChats
        for (peerID, items) in chats {
            let filtered = items.filter { $0.id != messageID }
            if filtered.count != items.count {
                if filtered.isEmpty {
                    chats.removeValue(forKey: peerID)
                } else {
                    chats[peerID] = filtered
                }
                if removedMessage == nil {
                    removedMessage = items.first(where: { $0.id == messageID })
                }
            }
        }
        viewModel.privateChats = chats

        if cleanupFile, let removedMessage {
            viewModel.cleanupLocalFile(forMessage: removedMessage)
        }

        viewModel.objectWillChange.send()
    }

    func initializeConversationStore() {
        viewModel.conversationStore.setActiveChannel(viewModel.activeChannel)
        synchronizePublicConversationStore(for: viewModel.activeChannel)
        viewModel.synchronizePrivateConversationStore()
        viewModel.synchronizeConversationSelectionStore()
    }

    func synchronizePublicConversationStore(for channel: ChannelID) {
        let publicMessages = viewModel.timelineStore.messages(for: channel)
        viewModel.conversationStore.replaceMessages(publicMessages, for: channel)
        if channel == viewModel.activeChannel {
            viewModel.conversationStore.setActiveChannel(viewModel.activeChannel)
        }
    }

    func synchronizePublicConversationStore(forGeohash geohash: String) {
        let channel = ChannelID.location(GeohashChannel(level: .city, geohash: geohash))
        let publicMessages = viewModel.timelineStore.messages(for: channel)
        viewModel.conversationStore.replaceMessages(publicMessages, for: .geohash(geohash.lowercased()))
    }

    func synchronizeAllPublicConversationStores() {
        synchronizePublicConversationStore(for: .mesh)
        for geohash in viewModel.timelineStore.geohashKeys() {
            synchronizePublicConversationStore(forGeohash: geohash)
        }
    }

    func refreshVisibleMessages(from channel: ChannelID? = nil) {
        let target = channel ?? viewModel.activeChannel
        viewModel.messages = viewModel.timelineStore.messages(for: target)
        viewModel.conversationStore.replaceMessages(viewModel.messages, for: target)
        if target == viewModel.activeChannel {
            viewModel.conversationStore.setActiveChannel(viewModel.activeChannel)
        }
    }

    func clearCurrentPublicTimeline() {
        viewModel.messages.removeAll()
        viewModel.timelineStore.clear(channel: viewModel.activeChannel)

        Task.detached(priority: .utility) {
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
        viewModel.messages.append(systemMessage)
    }

    func addMeshOnlySystemMessage(_ content: String) {
        let systemMessage = BitchatMessage(
            sender: "system",
            content: content,
            timestamp: Date(),
            isRelay: false
        )
        viewModel.timelineStore.append(systemMessage, to: .mesh)
        synchronizePublicConversationStore(for: .mesh)
        refreshVisibleMessages()
        viewModel.trimMessagesIfNeeded()
        viewModel.objectWillChange.send()
    }

    func addPublicSystemMessage(_ content: String) {
        let systemMessage = BitchatMessage(
            sender: "system",
            content: content,
            timestamp: Date(),
            isRelay: false
        )
        viewModel.timelineStore.append(systemMessage, to: viewModel.activeChannel)
        refreshVisibleMessages(from: viewModel.activeChannel)
        let contentKey = viewModel.deduplicationService.normalizedContentKey(systemMessage.content)
        viewModel.deduplicationService.recordContentKey(contentKey, timestamp: systemMessage.timestamp)
        viewModel.trimMessagesIfNeeded()
        viewModel.objectWillChange.send()
    }

    func addGeohashOnlySystemMessage(_ content: String) {
        if case .location = viewModel.activeChannel {
            addPublicSystemMessage(content)
        } else {
            viewModel.timelineStore.queueGeohashSystemMessage(content)
        }
    }

    func sendPublicRaw(_ content: String) {
        if case .location(let channel) = viewModel.activeChannel {
            Task { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                do {
                    let identity = try viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash)
                    let event = try NostrProtocol.createEphemeralGeohashEvent(
                        content: content,
                        geohash: channel.geohash,
                        senderIdentity: identity,
                        nickname: viewModel.nickname,
                        teleported: viewModel.locationManager.teleported
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

        viewModel.meshService.sendMessage(
            content,
            mentions: [],
            messageID: UUID().uuidString,
            timestamp: Date()
        )
    }

    func handlePublicMessage(_ message: BitchatMessage) {
        let finalMessage = viewModel.processActionMessage(message)
        if viewModel.isMessageBlocked(finalMessage) { return }

        let isGeo = finalMessage.senderPeerID?.isGeoChat == true
        let shouldRateLimit = finalMessage.sender != "system" || finalMessage.senderPeerID != nil
        if shouldRateLimit {
            let senderKey = normalizedSenderKey(for: finalMessage)
            let contentKey = viewModel.deduplicationService.normalizedContentKey(finalMessage.content)
            if !viewModel.publicRateLimiter.allow(senderKey: senderKey, contentKey: contentKey) {
                return
            }
        }

        if finalMessage.sender != "system" && finalMessage.content.count > 16000 { return }

        if !isGeo && finalMessage.sender != "system" {
            viewModel.timelineStore.append(finalMessage, to: .mesh)
            synchronizePublicConversationStore(for: .mesh)
        }

        if isGeo && finalMessage.sender != "system",
           let geohash = viewModel.currentGeohash,
           viewModel.timelineStore.appendIfAbsent(finalMessage, toGeohash: geohash) {
            synchronizePublicConversationStore(forGeohash: geohash)
        }

        let isSystem = finalMessage.sender == "system"
        let channelMatches: Bool = {
            switch viewModel.activeChannel {
            case .mesh: return !isGeo || isSystem
            case .location: return isGeo || isSystem
            }
        }()

        guard channelMatches else { return }

        if !finalMessage.content.trimmed.isEmpty,
           !viewModel.messages.contains(where: { $0.id == finalMessage.id }) {
            viewModel.publicMessagePipeline.enqueue(finalMessage)
        }
    }

    func checkForMentions(_ message: BitchatMessage) {
        var myTokens: Set<String> = [viewModel.nickname]
        let meshPeers = viewModel.meshService.getPeerNicknames()
        let collisions = meshPeers.values.filter { $0.hasPrefix(viewModel.nickname + "#") }
        if !collisions.isEmpty {
            let suffix = "#" + String(viewModel.meshService.myPeerID.id.prefix(4))
            myTokens = [viewModel.nickname + suffix]
        }
        let isMentioned = message.mentions?.contains(where: myTokens.contains) ?? false

        if isMentioned && message.sender != viewModel.nickname {
            SecureLogger.info("🔔 Mention from \(message.sender)", category: .session)
            NotificationService.shared.sendMentionNotification(from: message.sender, message: message.content)
        }
    }

    func sendHapticFeedback(for message: BitchatMessage) {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }

        var tokens: [String] = [viewModel.nickname]
        switch viewModel.activeChannel {
        case .location(let channel):
            if let identity = try? viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash) {
                tokens.append(viewModel.nickname + "#" + String(identity.publicKeyHex.suffix(4)))
            }
        case .mesh:
            break
        }

        let hugsMe = tokens.contains { message.content.contains("hugs \($0)") } || message.content.contains("hugs you")
        let slapsMe = tokens.contains { message.content.contains("slaps \($0) around") } || message.content.contains("slaps you around")
        let isHugForMe = message.content.contains("🫂") && hugsMe
        let isSlapForMe = message.content.contains("🐟") && slapsMe

        if isHugForMe && message.sender != viewModel.nickname {
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.prepare()

            for i in 0..<8 {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Double(i) * TransportConfig.uiBatchDispatchStaggerSeconds
                ) {
                    impactFeedback.impactOccurred()
                }
            }
        } else if isSlapForMe && message.sender != viewModel.nickname {
            let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)
            impactFeedback.prepare()
            impactFeedback.impactOccurred()
        }
        #endif
    }

    func pipelineCurrentMessages(_ pipeline: PublicMessagePipeline) -> [BitchatMessage] {
        viewModel.messages
    }

    func pipeline(_ pipeline: PublicMessagePipeline, setMessages messages: [BitchatMessage]) {
        viewModel.messages = messages
    }

    func pipeline(_ pipeline: PublicMessagePipeline, normalizeContent content: String) -> String {
        viewModel.deduplicationService.normalizedContentKey(content)
    }

    func pipeline(_ pipeline: PublicMessagePipeline, contentTimestampForKey key: String) -> Date? {
        viewModel.deduplicationService.contentTimestamp(forKey: key)
    }

    func pipeline(_ pipeline: PublicMessagePipeline, recordContentKey key: String, timestamp: Date) {
        viewModel.deduplicationService.recordContentKey(key, timestamp: timestamp)
    }

    func pipelineTrimMessages(_ pipeline: PublicMessagePipeline) {
        viewModel.trimMessagesIfNeeded()
    }

    func pipelinePrewarmMessage(_ pipeline: PublicMessagePipeline, message: BitchatMessage) {
        _ = viewModel.formatMessageAsText(message, colorScheme: viewModel.currentColorScheme)
    }

    func pipelineSetBatchingState(_ pipeline: PublicMessagePipeline, isBatching: Bool) {
        viewModel.isBatchingPublic = isBatching
    }
}

private extension ChatPublicConversationCoordinator {
    func normalizedSenderKey(for message: BitchatMessage) -> String {
        if let senderPeerID = message.senderPeerID {
            if senderPeerID.isGeoChat || senderPeerID.isGeoDM {
                let full = (viewModel.nostrKeyMapping[senderPeerID] ?? senderPeerID.bare).lowercased()
                return "nostr:" + full
            } else if senderPeerID.id.count == 16,
                      let full = viewModel.cachedStablePeerID(for: senderPeerID)?.id.lowercased() {
                return "noise:" + full
            } else {
                return "mesh:" + senderPeerID.id.lowercased()
            }
        }
        return "name:" + message.sender.lowercased()
    }
}
