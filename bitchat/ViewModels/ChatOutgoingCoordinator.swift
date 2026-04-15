import BitFoundation
import BitLogger
import Foundation

@MainActor
final class ChatOutgoingCoordinator {
    private unowned let viewModel: ChatViewModel

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    func sendMessage(_ content: String) {
        guard let trimmed = content.trimmedOrNilIfEmpty else { return }

        if content.hasPrefix("/") {
            Task { @MainActor [weak viewModel] in
                viewModel?.handleCommand(content)
            }
            return
        }

        if viewModel.selectedPrivateChatPeer != nil {
            viewModel.updatePrivateChatPeerIfNeeded()

            if let selectedPeer = viewModel.selectedPrivateChatPeer {
                viewModel.sendPrivateMessage(content, to: selectedPeer)
            }
            return
        }

        let mentions = viewModel.parseMentions(from: content)
        let preparedMessage = preparePublicMessage(content: content, trimmed: trimmed, mentions: mentions)
        guard let preparedMessage else { return }

        appendLocalEcho(preparedMessage.message)
        routePublicMessage(
            originalContent: content,
            mentions: mentions,
            geoContext: preparedMessage.geoContext,
            messageID: preparedMessage.message.id,
            timestamp: preparedMessage.message.timestamp
        )
    }
}

private extension ChatOutgoingCoordinator {
    func preparePublicMessage(
        content: String,
        trimmed: String,
        mentions: [String]
    ) -> (message: BitchatMessage, geoContext: ChatViewModel.GeoOutgoingContext?)? {
        var geoContext: ChatViewModel.GeoOutgoingContext?
        var displaySender = viewModel.nickname
        var localSenderPeerID = viewModel.meshService.myPeerID
        var messageID: String?
        var messageTimestamp = Date()

        switch viewModel.activeChannel {
        case .mesh:
            break

        case .location(let channel):
            do {
                let identity = try viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash)
                let suffix = String(identity.publicKeyHex.suffix(4))
                displaySender = viewModel.nickname + "#" + suffix
                localSenderPeerID = PeerID(nostr: identity.publicKeyHex)

                let teleported = LocationChannelManager.shared.teleported
                let event = try NostrProtocol.createEphemeralGeohashEvent(
                    content: trimmed,
                    geohash: channel.geohash,
                    senderIdentity: identity,
                    nickname: viewModel.nickname,
                    teleported: teleported
                )

                messageID = event.id
                messageTimestamp = Date(timeIntervalSince1970: TimeInterval(event.created_at))
                geoContext = (
                    channel: channel,
                    event: event,
                    identity: identity,
                    teleported: teleported
                )
            } catch {
                SecureLogger.error("❌ Failed to prepare geohash message: \(error)", category: .session)
                viewModel.addSystemMessage(
                    String(localized: "system.location.send_failed", comment: "System message when a location channel send fails")
                )
                return nil
            }
        }

        let message = BitchatMessage(
            id: messageID,
            sender: displaySender,
            content: trimmed,
            timestamp: messageTimestamp,
            isRelay: false,
            senderPeerID: localSenderPeerID,
            mentions: mentions.isEmpty ? nil : mentions
        )

        return (message, geoContext)
    }

    func appendLocalEcho(_ message: BitchatMessage) {
        viewModel.timelineStore.append(message, to: viewModel.activeChannel)
        viewModel.refreshVisibleMessages(from: viewModel.activeChannel)

        let contentKey = viewModel.deduplicationService.normalizedContentKey(message.content)
        viewModel.deduplicationService.recordContentKey(contentKey, timestamp: message.timestamp)
        viewModel.trimMessagesIfNeeded()
    }

    func routePublicMessage(
        originalContent: String,
        mentions: [String],
        geoContext: ChatViewModel.GeoOutgoingContext?,
        messageID: String,
        timestamp: Date
    ) {
        switch viewModel.activeChannel {
        case .mesh:
            viewModel.lastPublicActivityAt["mesh"] = Date()
            viewModel.meshService.sendMessage(
                originalContent,
                mentions: mentions,
                messageID: messageID,
                timestamp: timestamp
            )

        case .location(let channel):
            viewModel.lastPublicActivityAt["geo:\(channel.geohash)"] = Date()

            guard let geoContext, geoContext.channel.geohash == channel.geohash else {
                SecureLogger.error("Geo: missing send context for \(channel.geohash)", category: .session)
                viewModel.addSystemMessage(
                    String(localized: "system.location.send_failed", comment: "System message when a location channel send fails")
                )
                return
            }

            Task { @MainActor [weak viewModel] in
                viewModel?.sendGeohash(context: geoContext)
            }
        }
    }
}
