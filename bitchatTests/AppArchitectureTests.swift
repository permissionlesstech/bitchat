import BitFoundation
import Foundation
import Testing
@testable import bitchat

@MainActor
private func makeArchitectureViewModel(
    locationManager: LocationChannelManager? = nil
) -> ChatViewModel {
    let keychain = MockKeychain()
    let keychainHelper = MockKeychainHelper()
    let idBridge = NostrIdentityBridge(keychain: keychainHelper)
    let identityManager = MockIdentityManager(keychain)
    let locationManager = locationManager ?? makeArchitectureLocationManager()

    return ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        transport: MockTransport(),
        locationManager: locationManager
    )
}

@MainActor
private func makeArchitectureLocationManager() -> LocationChannelManager {
    let suiteName = "AppArchitectureTests.\(UUID().uuidString)"
    let storage = UserDefaults(suiteName: suiteName) ?? .standard
    storage.removePersistentDomain(forName: suiteName)
    return LocationChannelManager(storage: storage)
}

private func makeArchitectureSnapshot(
    peerID: PeerID,
    nickname: String,
    connected: Bool,
    noisePublicKey: Data
) -> TransportPeerSnapshot {
    TransportPeerSnapshot(
        peerID: peerID,
        nickname: nickname,
        isConnected: connected,
        noisePublicKey: noisePublicKey,
        lastSeen: Date()
    )
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 3_000_000_000,
    pollNanoseconds: UInt64 = 20_000_000,
    _ condition: @escaping @MainActor () -> Bool
) async {
    let timeout = Double(timeoutNanoseconds) / 1_000_000_000
    let deadline = Date().addingTimeInterval(timeout)

    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: pollNanoseconds)
    }
}

@Suite("App Architecture Tests", .serialized)
struct AppArchitectureTests {

    @Test("PeerIdentityStore owns fingerprint, mapping, and verification state")
    @MainActor
    func peerIdentityStoreOwnsIdentityState() {
        let store = PeerIdentityStore()
        let shortPeerID = PeerID(str: "peer-short")
        let stablePeerID = PeerID(str: "peer-stable")
        let canonicalPeerID = PeerID(str: "peer-canonical")

        store.setStablePeerID(stablePeerID, forShortID: shortPeerID)
        store.setFingerprint("fp-1", for: shortPeerID)
        store.setCachedEncryptionStatus(.noiseHandshaking, for: shortPeerID)
        store.setEncryptionStatus(.noiseSecured, for: shortPeerID)
        store.setVerified("fp-1", verified: true)

        let migratedFingerprint = store.migrateFingerprintMapping(
            from: shortPeerID,
            to: canonicalPeerID
        )

        #expect(store.stablePeerID(forShortID: shortPeerID) == stablePeerID)
        #expect(store.shortPeerID(forStablePeerID: stablePeerID) == shortPeerID)
        #expect(migratedFingerprint == "fp-1")
        #expect(store.fingerprint(for: shortPeerID) == nil)
        #expect(store.fingerprint(for: canonicalPeerID) == "fp-1")
        #expect(store.selectedPrivateChatFingerprint == "fp-1")
        #expect(store.encryptionStatus(for: shortPeerID) == .noiseSecured)
        #expect(store.cachedEncryptionStatus(for: shortPeerID) == nil)
        #expect(store.isVerified("fp-1"))

        store.clearAll()

        #expect(store.encryptionStatuses.isEmpty)
        #expect(store.verifiedFingerprints.isEmpty)
        #expect(store.peerFingerprintsByPeerID.isEmpty)
        #expect(store.selectedPrivateChatFingerprint == nil)
        #expect(store.stablePeerID(forShortID: shortPeerID) == nil)
    }

    @Test("LocationPresenceStore normalizes and resets geohash presence state")
    @MainActor
    func locationPresenceStoreNormalizesPresenceState() {
        let store = LocationPresenceStore()

        store.setCurrentGeohash("U4PRUY")
        store.replaceGeoNicknames([
            "ABCDEF": "alice",
            "123456": "bob"
        ])
        store.markTeleported("ABCDEF")
        store.replaceTeleportedGeo(Set(["FEDCBA", "123456"]))

        #expect(store.currentGeohash == "u4pruy")
        #expect(store.geoNicknames["abcdef"] == "alice")
        #expect(store.geoNicknames["123456"] == "bob")
        #expect(store.teleportedGeo == Set(["fedcba", "123456"]))

        store.reset()

        #expect(store.currentGeohash == nil)
        #expect(store.geoNicknames.isEmpty)
        #expect(store.teleportedGeo.isEmpty)
    }

    @Test("PeerHandle equality and hashing use the canonical identity only")
    func peerHandleEqualityUsesCanonicalIdentity() {
        let first = PeerHandle(
            id: "noise:abc123",
            routingPeerID: PeerID(str: "peer-a"),
            displayName: "alice",
            noisePublicKeyHex: "abc123",
            nostrPublicKey: nil
        )
        let second = PeerHandle(
            id: "noise:abc123",
            routingPeerID: PeerID(str: "peer-b"),
            displayName: "alice-renamed",
            noisePublicKeyHex: nil,
            nostrPublicKey: "npub123"
        )

        #expect(first == second)
        #expect(Set([first, second]).count == 1)
    }

    @Test("ConversationStore normalizes timeline ordering and duplicates")
    @MainActor
    func conversationStoreNormalizesMessages() {
        let store = ConversationStore()
        let older = BitchatMessage(
            id: "m1",
            sender: "alice",
            content: "first",
            timestamp: Date(timeIntervalSince1970: 1),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: PeerID(str: "peer-a")
        )
        let newer = BitchatMessage(
            id: "m2",
            sender: "alice",
            content: "second",
            timestamp: Date(timeIntervalSince1970: 2),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: PeerID(str: "peer-a")
        )
        let replacement = BitchatMessage(
            id: "m2",
            sender: "alice",
            content: "second-updated",
            timestamp: Date(timeIntervalSince1970: 2),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: PeerID(str: "peer-a")
        )

        store.replaceMessages([newer, older, replacement], for: ConversationID.mesh)

        let messages = store.messages(for: ConversationID.mesh)
        #expect(messages.map(\.id) == ["m1", "m2"])
        #expect(messages.last?.content == "second-updated")
    }

    @Test("ConversationStore tracks unread direct conversations with canonical IDs")
    @MainActor
    func conversationStoreTracksUnreadDirectConversations() {
        let store = ConversationStore()
        let resolver = IdentityResolver()
        let peerID = PeerID(str: "peer-1")
        let message = BitchatMessage(
            id: "dm-1",
            sender: "alice",
            content: "hello",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: "bob",
            senderPeerID: peerID
        )

        store.synchronizePrivateChats(
            [peerID: [message]],
            unreadPeerIDs: Set([peerID]),
            identityResolver: resolver
        )

        let conversationID = ConversationID.direct(
            resolver.canonicalHandle(for: peerID, displayName: "alice")
        )

        #expect(store.messages(for: conversationID).map(\.id) == ["dm-1"])
        #expect(store.unreadConversations.contains(conversationID))

        store.markRead(conversationID)
        #expect(!store.unreadConversations.contains(conversationID))
    }

    @Test("ConversationStore tracks the selected app conversation context")
    @MainActor
    func conversationStoreTracksSelectedConversationContext() {
        let store = ConversationStore()
        let resolver = IdentityResolver()
        let noiseKey = Data((0..<32).map(UInt8.init))
        let shortPeerID = PeerID(str: "0011223344556677")
        let geohashChannel = ChannelID.location(GeohashChannel(level: .city, geohash: "9q8yy"))
        let peer = BitchatPeer(
            peerID: shortPeerID,
            noisePublicKey: noiseKey,
            nickname: "alice",
            isConnected: true,
            isReachable: true
        )

        resolver.register(peers: [peer])
        store.synchronizeSelection(
            activeChannel: geohashChannel,
            selectedPeerID: shortPeerID,
            identityResolver: resolver
        )

        let expectedConversationID = ConversationID.direct(
            resolver.canonicalHandle(for: shortPeerID, displayName: "alice")
        )

        #expect(store.activeChannel == geohashChannel)
        #expect(store.selectedPrivatePeerID == shortPeerID)
        #expect(store.selectedConversationID == expectedConversationID)

        store.synchronizeSelection(
            activeChannel: ChannelID.mesh,
            selectedPeerID: nil,
            identityResolver: resolver
        )

        #expect(store.activeChannel == ChannelID.mesh)
        #expect(store.selectedPrivatePeerID == nil)
        #expect(store.selectedConversationID == ConversationID.mesh)
    }

    @Test("ConversationStore exposes direct conversations by the latest routing peer ID")
    @MainActor
    func conversationStoreExposesDirectConversationsByLatestRoutingPeerID() {
        let store = ConversationStore()
        let resolver = IdentityResolver()
        let noiseKey = Data((0..<32).map(UInt8.init))
        let shortPeerID = PeerID(str: "0011223344556677")
        let fullPeerID = PeerID(hexData: noiseKey)
        let firstMessage = BitchatMessage(
            id: "dm-1",
            sender: "alice",
            content: "short id",
            timestamp: Date(timeIntervalSince1970: 1),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: "builder",
            senderPeerID: shortPeerID
        )
        let secondMessage = BitchatMessage(
            id: "dm-2",
            sender: "alice",
            content: "full id",
            timestamp: Date(timeIntervalSince1970: 2),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: "builder",
            senderPeerID: fullPeerID
        )

        resolver.register(
            peer: BitchatPeer(
                peerID: shortPeerID,
                noisePublicKey: noiseKey,
                nickname: "alice",
                isConnected: true,
                isReachable: true
            )
        )
        store.synchronizePrivateChats(
            [shortPeerID: [firstMessage]],
            unreadPeerIDs: Set([shortPeerID]),
            identityResolver: resolver
        )

        resolver.register(
            peer: BitchatPeer(
                peerID: fullPeerID,
                noisePublicKey: noiseKey,
                nickname: "alice",
                isConnected: true,
                isReachable: true
            )
        )
        store.synchronizePrivateChats(
            [fullPeerID: [secondMessage]],
            unreadPeerIDs: Set([fullPeerID]),
            identityResolver: resolver
        )

        #expect(Set(store.directMessagesByPeerID().keys) == Set([fullPeerID]))
        #expect(store.directMessagesByPeerID()[fullPeerID]?.map(\.id) == ["dm-2"])
        #expect(store.unreadDirectPeerIDs() == Set([fullPeerID]))
    }

    @Test("PrivateInboxModel mirrors direct message state from ConversationStore")
    @MainActor
    func privateInboxModelMirrorsDirectMessageStateFromConversationStore() async {
        let store = ConversationStore()
        let resolver = IdentityResolver()
        let inboxModel = PrivateInboxModel(conversationStore: store)
        let messagePeerID = PeerID(str: "peer-1")
        let unreadOnlyPeerID = PeerID(str: "peer-2")
        let selectedOnlyPeerID = PeerID(str: "peer-3")
        let message = BitchatMessage(
            id: "dm-1",
            sender: "alice",
            content: "hello",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: "builder",
            senderPeerID: messagePeerID
        )

        store.synchronizePrivateChats(
            [messagePeerID: [message]],
            unreadPeerIDs: Set([messagePeerID, unreadOnlyPeerID]),
            identityResolver: resolver
        )
        store.synchronizeSelection(
            activeChannel: ChannelID.mesh,
            selectedPeerID: selectedOnlyPeerID,
            identityResolver: resolver
        )

        await waitUntil {
            inboxModel.selectedPeerID == selectedOnlyPeerID &&
            inboxModel.unreadPeerIDs == Set([messagePeerID, unreadOnlyPeerID]) &&
            Set(inboxModel.messagesByPeerID.keys) == Set([messagePeerID, unreadOnlyPeerID, selectedOnlyPeerID])
        }

        #expect(inboxModel.selectedPeerID == selectedOnlyPeerID)
        #expect(inboxModel.unreadPeerIDs == Set([messagePeerID, unreadOnlyPeerID]))
        #expect(inboxModel.messages(for: messagePeerID).map(\.id) == ["dm-1"])
        #expect(inboxModel.messages(for: unreadOnlyPeerID).isEmpty)
        #expect(inboxModel.messages(for: selectedOnlyPeerID).isEmpty)
    }

    @Test("AppChromeModel mirrors nickname and unread state through focused models")
    @MainActor
    func appChromeModelMirrorsNicknameAndUnreadState() async {
        let viewModel = makeArchitectureViewModel()
        let conversationStore = ConversationStore()
        let resolver = IdentityResolver()
        let privateInboxModel = PrivateInboxModel(conversationStore: conversationStore)
        let chromeModel = AppChromeModel(chatViewModel: viewModel, privateInboxModel: privateInboxModel)

        chromeModel.setNickname("builder")
        await waitUntil {
            viewModel.nickname == "builder" && chromeModel.nickname == "builder"
        }

        #expect(viewModel.nickname == "builder")
        #expect(chromeModel.nickname == "builder")
        #expect(!chromeModel.hasUnreadPrivateMessages)

        let peerID = PeerID(str: "peer-1")
        conversationStore.synchronizePrivateChats(
            [:],
            unreadPeerIDs: Set([peerID]),
            identityResolver: resolver
        )
        await waitUntil {
            chromeModel.hasUnreadPrivateMessages
        }

        #expect(chromeModel.hasUnreadPrivateMessages)
    }

    @Test("AppChromeModel owns fingerprint and screenshot presentation state")
    @MainActor
    func appChromeModelOwnsPresentationState() {
        let viewModel = makeArchitectureViewModel()
        let conversationStore = ConversationStore()
        let privateInboxModel = PrivateInboxModel(conversationStore: conversationStore)
        let chromeModel = AppChromeModel(chatViewModel: viewModel, privateInboxModel: privateInboxModel)
        let peerID = PeerID(str: "peer-2")

        chromeModel.showFingerprint(for: peerID)
        chromeModel.presentAppInfo()
        chromeModel.isLocationChannelsSheetPresented = true
        chromeModel.triggerScreenshotPrivacyWarning()

        #expect(chromeModel.showingFingerprintFor == peerID)
        #expect(chromeModel.isAppInfoPresented)
        #expect(chromeModel.shouldSuppressScreenshotNotification)
        #expect(chromeModel.showScreenshotPrivacyWarning)

        chromeModel.clearFingerprint()
        #expect(chromeModel.showingFingerprintFor == nil)
    }

    @Test("PrivateConversationModel resolves canonical header state for the selected DM")
    @MainActor
    func privateConversationModelResolvesSelectedHeaderState() async {
        let viewModel = makeArchitectureViewModel()
        guard let transport = viewModel.meshService as? MockTransport else {
            Issue.record("Expected ChatViewModel meshService to be a MockTransport in architecture tests")
            return
        }
        let conversationStore = viewModel.conversationStore
        let locationChannelsModel = LocationChannelsModel(manager: makeArchitectureLocationManager())
        let conversationModel = PrivateConversationModel(
            chatViewModel: viewModel,
            conversationStore: conversationStore,
            locationChannelsModel: locationChannelsModel
        )

        let noiseKey = Data((0..<32).map(UInt8.init))
        let shortPeerID = PeerID(str: "0011223344556677")
        let fullPeerID = PeerID(hexData: noiseKey)
        transport.peerNicknames[shortPeerID] = "alice"
        transport.reachablePeers.insert(shortPeerID)
        viewModel.allPeers = [
            BitchatPeer(
                peerID: shortPeerID,
                noisePublicKey: noiseKey,
                nickname: "alice",
                isConnected: false,
                isReachable: true
            )
        ]

        conversationModel.startConversation(with: fullPeerID)
        await waitUntil {
            conversationModel.selectedPeerID == fullPeerID
        }

        #expect(conversationModel.selectedPeerID == fullPeerID)
        #expect(conversationModel.selectedHeaderState?.headerPeerID == shortPeerID)
        #expect(conversationModel.selectedHeaderState?.displayName == "alice")
        #expect(conversationModel.selectedHeaderState?.availability == .meshReachable)
        #expect(conversationModel.selectedHeaderState?.encryptionStatus == .noHandshake)

        conversationModel.endConversation()
        await waitUntil {
            conversationModel.selectedPeerID == nil
        }
        #expect(conversationModel.selectedPeerID == nil)
        #expect(conversationModel.selectedHeaderState == nil)
    }

    @Test("ConversationUIModel mirrors composer state and forwards sends")
    @MainActor
    func conversationUIModelMirrorsComposerStateAndForwardsSends() async {
        let locationManager = makeArchitectureLocationManager()
        let viewModel = makeArchitectureViewModel(locationManager: locationManager)
        guard let transport = viewModel.meshService as? MockTransport else {
            Issue.record("Expected ChatViewModel meshService to be a MockTransport in architecture tests")
            return
        }

        let conversationStore = viewModel.conversationStore
        locationManager.select(.mesh)
        let locationChannelsModel = LocationChannelsModel(manager: locationManager)
        let privateConversationModel = PrivateConversationModel(
            chatViewModel: viewModel,
            conversationStore: conversationStore,
            locationChannelsModel: locationChannelsModel
        )
        let uiModel = ConversationUIModel(
            chatViewModel: viewModel,
            privateConversationModel: privateConversationModel,
            conversationStore: conversationStore
        )
        let geohashChannel = ChannelID.location(GeohashChannel(level: .city, geohash: "9q8yy"))
        defer {
            locationManager.select(.mesh)
        }
        viewModel.nickname = "builder"
        viewModel.autocompleteSuggestions = ["alice"]
        viewModel.showAutocomplete = true
        locationChannelsModel.select(geohashChannel)

        await waitUntil {
            viewModel.activeChannel == geohashChannel &&
            uiModel.currentNickname == "builder" &&
            uiModel.showAutocomplete &&
            uiModel.autocompleteSuggestions == ["alice"] &&
            !uiModel.canSendMediaInCurrentContext
        }

        #expect(viewModel.activeChannel == geohashChannel)
        #expect(uiModel.currentNickname == "builder")
        #expect(uiModel.showAutocomplete)
        #expect(uiModel.autocompleteSuggestions == ["alice"])
        #expect(!uiModel.canSendMediaInCurrentContext)

        locationChannelsModel.select(ChannelID.mesh)
        await waitUntil {
            viewModel.activeChannel == ChannelID.mesh &&
            uiModel.canSendMediaInCurrentContext
        }

        #expect(viewModel.activeChannel == ChannelID.mesh)
        #expect(uiModel.canSendMediaInCurrentContext)

        uiModel.sendMessage("hello mesh")

        await waitUntil {
            transport.sentMessages.last?.content == "hello mesh"
        }

        #expect(transport.sentMessages.last?.content == "hello mesh")
    }

    @Test("VerificationModel bridges selected conversation and fingerprint actions")
    @MainActor
    func verificationModelBridgesSelectedConversationAndFingerprintActions() async {
        let viewModel = makeArchitectureViewModel()
        guard let transport = viewModel.meshService as? MockTransport else {
            Issue.record("Expected ChatViewModel meshService to be a MockTransport in architecture tests")
            return
        }

        let peerID = PeerID(str: "0011223344556677")
        let fingerprint = "verified-fingerprint"
        let conversationStore = viewModel.conversationStore
        let locationChannelsModel = LocationChannelsModel(manager: makeArchitectureLocationManager())
        let privateConversationModel = PrivateConversationModel(
            chatViewModel: viewModel,
            conversationStore: conversationStore,
            locationChannelsModel: locationChannelsModel
        )
        let verificationModel = VerificationModel(
            chatViewModel: viewModel,
            privateConversationModel: privateConversationModel
        )

        transport.peerFingerprints[peerID] = fingerprint
        transport.peerNicknames[peerID] = "alice"
        viewModel.allPeers = [
            BitchatPeer(
                peerID: peerID,
                noisePublicKey: Data((0..<32).map(UInt8.init)),
                nickname: "alice",
                isConnected: true,
                isReachable: true
            )
        ]

        privateConversationModel.startConversation(with: peerID)
        await waitUntil {
            verificationModel.selectedPeerID == peerID
        }

        let presentation = verificationModel.fingerprintPresentation(for: peerID)
        #expect(verificationModel.selectedPeerID == peerID)
        #expect(presentation.peerNickname == "alice")
        #expect(presentation.theirFingerprint == fingerprint)
        #expect(!presentation.myFingerprint.isEmpty)
        #expect(!verificationModel.isVerified(peerID: peerID))

        verificationModel.verifyFingerprint(for: peerID)
        await waitUntil {
            verificationModel.isVerified(peerID: peerID)
        }
        #expect(verificationModel.isVerified(peerID: peerID))

        verificationModel.unverifyFingerprint(for: peerID)
        await waitUntil {
            !verificationModel.isVerified(peerID: peerID)
        }
        #expect(!verificationModel.isVerified(peerID: peerID))
    }

    @Test("PeerListModel publishes mesh and geohash directory state")
    @MainActor
    func peerListModelPublishesDirectoryState() async {
        let viewModel = makeArchitectureViewModel()
        guard let transport = viewModel.meshService as? MockTransport else {
            Issue.record("Expected ChatViewModel meshService to be a MockTransport in architecture tests")
            return
        }

        let myPeerID = PeerID(str: "me-peer")
        let otherPeerID = PeerID(str: "0011223344556677")
        let geohash = "9q8yy"
        let remoteGeoID = String(repeating: "b", count: 64)
        let locationManager = makeArchitectureLocationManager()
        let locationChannelsModel = LocationChannelsModel(manager: locationManager)
        let otherNoiseKey = Data((0..<32).map(UInt8.init))
        let verifiedFingerprint = otherNoiseKey.sha256Fingerprint()

        transport.myPeerID = myPeerID
        transport.peerFingerprints[otherPeerID] = verifiedFingerprint
        transport.peerNicknames[otherPeerID] = "alice"
        transport.reachablePeers.insert(otherPeerID)
        viewModel.nickname = "builder"
        viewModel.verifiedFingerprints.insert(verifiedFingerprint)
        viewModel.unreadPrivateMessages = Set([otherPeerID])
        transport.updatePeerSnapshots([
            makeArchitectureSnapshot(
                peerID: myPeerID,
                nickname: "builder",
                connected: true,
                noisePublicKey: Data(repeating: 0, count: 32)
            ),
            makeArchitectureSnapshot(
                peerID: otherPeerID,
                nickname: "alice",
                connected: false,
                noisePublicKey: otherNoiseKey
            )
        ])

        locationManager.select(.location(GeohashChannel(level: .city, geohash: geohash)))
        await waitUntil {
            if case .location(let channel) = locationManager.selectedChannel {
                return channel.geohash == geohash && !viewModel.allPeers.isEmpty
            }
            return false
        }

        viewModel.participantTracker.setActiveGeohash(geohash)
        viewModel.teleportedGeo = Set([remoteGeoID])
        viewModel.participantTracker.recordParticipant(pubkeyHex: remoteGeoID, geohash: geohash)
        if let myGeoID = try? viewModel.idBridge.deriveIdentity(forGeohash: geohash).publicKeyHex.lowercased() {
            viewModel.participantTracker.recordParticipant(pubkeyHex: myGeoID, geohash: geohash)
        }

        let peerListModel = PeerListModel(
            chatViewModel: viewModel,
            conversationStore: viewModel.conversationStore,
            locationChannelsModel: locationChannelsModel
        )

        await waitUntil {
            peerListModel.reachableMeshPeerCount == 1 &&
            peerListModel.connectedMeshPeerCount == 0 &&
            peerListModel.meshRows.contains(where: { $0.peerID == otherPeerID && $0.hasUnread }) &&
            peerListModel.geohashPeople.contains(where: { $0.id == remoteGeoID && $0.isTeleported })
        }

        let meshRow = peerListModel.meshRows.first(where: { $0.peerID == otherPeerID })
        #expect(peerListModel.reachableMeshPeerCount == 1)
        #expect(peerListModel.connectedMeshPeerCount == 0)
        #expect(meshRow?.displayName == "alice")
        #expect(meshRow?.showsVerifiedBadgeWhenOffline == true)
        #expect(meshRow?.hasUnread == true)
        #expect(peerListModel.visibleGeohashPeerCount >= 1)
        #expect(peerListModel.participantCount(for: geohash) >= 1)
        #expect(peerListModel.geohashPeople.contains(where: { $0.id == remoteGeoID && $0.isTeleported }))

        viewModel.participantTracker.clear()
        viewModel.teleportedGeo = []
        locationManager.markTeleported(for: geohash, false)
        locationManager.select(ChannelID.mesh)
        await waitUntil {
            if case ChannelID.mesh = locationManager.selectedChannel {
                return true
            }
            return false
        }
    }
}
