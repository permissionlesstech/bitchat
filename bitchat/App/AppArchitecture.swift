import BitFoundation
import Combine
import Foundation

enum SharedContentKind: String, Sendable, Equatable {
    case text
    case url
}

enum RuntimeScenePhase: String, Sendable, Equatable {
    case active
    case inactive
    case background
}

enum TorLifecycleEvent: String, Sendable, Equatable {
    case willStart
    case willRestart
    case didBecomeReady
    case preferenceChanged
}

enum AppEvent: Sendable, Equatable {
    case launched
    case startupCompleted
    case scenePhaseChanged(RuntimeScenePhase)
    case openedURL(String)
    case sharedContentAccepted(SharedContentKind)
    case notificationOpened(peerID: PeerID?)
    case deepLinkOpened(String)
    case torLifecycleChanged(TorLifecycleEvent)
    case nostrRelayConnectionChanged(Bool)
    case terminationRequested
}

actor AppEventStream {
    private var continuations: [UUID: AsyncStream<AppEvent>.Continuation] = [:]

    func stream() -> AsyncStream<AppEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [id] _ in
                Task {
                    await self.removeContinuation(id)
                }
            }
        }
    }

    func emit(_ event: AppEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    func finish() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

struct PeerHandle: Sendable, Identifiable {
    let id: String
    let routingPeerID: PeerID
    let displayName: String?
    let noisePublicKeyHex: String?
    let nostrPublicKey: String?
}

extension PeerHandle: Equatable {
    static func == (lhs: PeerHandle, rhs: PeerHandle) -> Bool {
        lhs.id == rhs.id
    }
}

extension PeerHandle: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum ConversationID: Hashable, Sendable {
    case mesh
    case geohash(String)
    case direct(PeerHandle)

    init(channelID: ChannelID) {
        switch channelID {
        case .mesh:
            self = .mesh
        case .location(let channel):
            self = .geohash(channel.geohash.lowercased())
        }
    }
}

@MainActor
final class IdentityResolver {
    private var handlesByRoutingPeerID: [PeerID: PeerHandle] = [:]
    private var handlesByNoiseKey: [String: PeerHandle] = [:]
    private var handlesByNostrKey: [String: PeerHandle] = [:]

    func register(peers: [BitchatPeer]) {
        for peer in peers {
            _ = register(peer: peer)
        }
    }

    @discardableResult
    func register(peer: BitchatPeer) -> PeerHandle {
        let handle = buildHandle(
            routingPeerID: peer.peerID,
            displayName: peer.displayName,
            noisePublicKeyHex: peer.noisePublicKey.isEmpty ? nil : peer.noisePublicKey.hexEncodedString().lowercased(),
            nostrPublicKey: normalizedNostrKey(peer.nostrPublicKey)
        )
        cache(handle)
        return handle
    }

    func canonicalHandle(for peerID: PeerID, displayName: String? = nil) -> PeerHandle {
        if let handle = handlesByRoutingPeerID[peerID] {
            return handle
        }

        if peerID.isNoiseKeyHex, let handle = handlesByNoiseKey[peerID.bare] {
            return handle
        }

        if (peerID.isGeoDM || peerID.isGeoChat), let handle = handlesByNostrKey[peerID.bare] {
            return handle
        }

        let handle = buildHandle(
            routingPeerID: peerID,
            displayName: displayName,
            noisePublicKeyHex: peerID.isNoiseKeyHex ? peerID.bare : nil,
            nostrPublicKey: (peerID.isGeoDM || peerID.isGeoChat) ? peerID.bare : nil
        )
        cache(handle)
        return handle
    }

    private func buildHandle(
        routingPeerID: PeerID,
        displayName: String?,
        noisePublicKeyHex: String?,
        nostrPublicKey: String?
    ) -> PeerHandle {
        let canonicalID: String
        if let noisePublicKeyHex {
            canonicalID = "noise:\(noisePublicKeyHex)"
        } else if let nostrPublicKey {
            canonicalID = "nostr:\(nostrPublicKey)"
        } else {
            canonicalID = "mesh:\(routingPeerID.id)"
        }

        let normalizedDisplayName: String?
        if let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalizedDisplayName = displayName
        } else {
            normalizedDisplayName = nil
        }

        return PeerHandle(
            id: canonicalID,
            routingPeerID: routingPeerID,
            displayName: normalizedDisplayName,
            noisePublicKeyHex: noisePublicKeyHex,
            nostrPublicKey: nostrPublicKey
        )
    }

    private func normalizedNostrKey(_ nostrPublicKey: String?) -> String? {
        guard let nostrPublicKey else { return nil }
        let trimmed = nostrPublicKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private func cache(_ handle: PeerHandle) {
        handlesByRoutingPeerID[handle.routingPeerID] = handle
        if let noisePublicKeyHex = handle.noisePublicKeyHex {
            handlesByNoiseKey[noisePublicKeyHex] = handle
        }
        if let nostrPublicKey = handle.nostrPublicKey {
            handlesByNostrKey[nostrPublicKey] = handle
        }
    }
}

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var activeChannel: ChannelID = .mesh
    @Published private(set) var selectedPrivatePeerID: PeerID?
    @Published private(set) var selectedConversationID: ConversationID = .mesh
    @Published private(set) var unreadConversations: Set<ConversationID> = []
    @Published private(set) var messagesByConversation: [ConversationID: [BitchatMessage]] = [:]

    private var directHandlesByConversation: [ConversationID: PeerHandle] = [:]

    func setActiveChannel(_ channelID: ChannelID) {
        activeChannel = channelID
        if selectedPrivatePeerID == nil {
            selectedConversationID = ConversationID(channelID: channelID)
        }
    }

    func setSelectedPeerID(
        _ peerID: PeerID?,
        activeChannel: ChannelID,
        identityResolver: IdentityResolver
    ) {
        self.activeChannel = activeChannel
        selectedPrivatePeerID = peerID

        if let peerID {
            selectedConversationID = directConversationID(
                for: peerID,
                identityResolver: identityResolver
            )
        } else {
            selectedConversationID = ConversationID(channelID: activeChannel)
        }
    }

    func replaceMessages(_ messages: [BitchatMessage], for conversationID: ConversationID) {
        messagesByConversation[conversationID] = normalized(messages)
    }

    func replaceMessages(_ messages: [BitchatMessage], for channelID: ChannelID) {
        replaceMessages(messages, for: ConversationID(channelID: channelID))
    }

    func synchronizePublicConversation(_ messages: [BitchatMessage], activeChannel: ChannelID) {
        setActiveChannel(activeChannel)
        replaceMessages(messages, for: activeChannel)
    }

    func messages(for conversationID: ConversationID) -> [BitchatMessage] {
        messagesByConversation[conversationID] ?? []
    }

    func directMessages(
        for peerID: PeerID,
        identityResolver: IdentityResolver
    ) -> [BitchatMessage] {
        messages(for: directConversationID(for: peerID, identityResolver: identityResolver))
    }

    func directMessagesByPeerID() -> [PeerID: [BitchatMessage]] {
        var messagesByPeerID: [PeerID: [BitchatMessage]] = [:]

        for (conversationID, handle) in directHandlesByConversation {
            messagesByPeerID[handle.routingPeerID] = messages(for: conversationID)
        }

        return messagesByPeerID
    }

    func unreadDirectPeerIDs() -> Set<PeerID> {
        unreadConversations.reduce(into: Set<PeerID>()) { result, conversationID in
            guard case .direct(let handle) = conversationID else { return }
            result.insert(directHandlesByConversation[conversationID]?.routingPeerID ?? handle.routingPeerID)
        }
    }

    func synchronizeSelection(
        activeChannel: ChannelID,
        selectedPeerID: PeerID?,
        identityResolver: IdentityResolver
    ) {
        setSelectedPeerID(
            selectedPeerID,
            activeChannel: activeChannel,
            identityResolver: identityResolver
        )
    }

    func synchronizePrivateChats(
        _ privateChats: [PeerID: [BitchatMessage]],
        unreadPeerIDs: Set<PeerID>,
        identityResolver: IdentityResolver
    ) {
        var liveConversations = Set<ConversationID>()

        for (peerID, messages) in privateChats {
            let handle = identityResolver.canonicalHandle(for: peerID, displayName: messages.last?.sender)
            let conversationID = ConversationID.direct(handle)
            liveConversations.insert(conversationID)
            directHandlesByConversation[conversationID] = handle
            messagesByConversation[conversationID] = normalized(messages)
        }

        let staleDirectConversations = messagesByConversation.keys.filter { conversationID in
            guard case .direct = conversationID else { return false }
            return !liveConversations.contains(conversationID)
        }

        for conversationID in staleDirectConversations {
            messagesByConversation.removeValue(forKey: conversationID)
            unreadConversations.remove(conversationID)
            directHandlesByConversation.removeValue(forKey: conversationID)
        }

        let publicUnread = unreadConversations.filter { conversationID in
            switch conversationID {
            case .mesh, .geohash:
                return true
            case .direct:
                return false
            }
        }

        unreadConversations = unreadPeerIDs.reduce(into: publicUnread) { result, peerID in
            let handle = identityResolver.canonicalHandle(for: peerID)
            result.insert(.direct(handle))
        }
    }

    func markRead(_ conversationID: ConversationID) {
        unreadConversations.remove(conversationID)
    }

    func markRead(
        peerID: PeerID,
        identityResolver: IdentityResolver
    ) {
        markRead(directConversationID(for: peerID, identityResolver: identityResolver))
    }

    private func normalized(_ messages: [BitchatMessage]) -> [BitchatMessage] {
        var uniqueMessages: [String: BitchatMessage] = [:]

        for message in messages {
            uniqueMessages[message.id] = message
        }

        return uniqueMessages.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.id < rhs.id
        }
    }

    private func directConversationID(
        for peerID: PeerID,
        identityResolver: IdentityResolver
    ) -> ConversationID {
        let handle = identityResolver.canonicalHandle(for: peerID)
        let conversationID = ConversationID.direct(handle)
        directHandlesByConversation[conversationID] = handle
        return conversationID
    }
}
