import BitFoundation
import Combine
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
private func makeArchitectureMessage(
    id: String,
    timestamp: TimeInterval = 0,
    content: String? = nil,
    isPrivate: Bool = false,
    senderPeerID: PeerID = PeerID(str: "peer-a")
) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: "alice",
        content: content ?? "message \(id)",
        timestamp: Date(timeIntervalSince1970: timestamp),
        isRelay: false,
        originalSender: nil,
        isPrivate: isPrivate,
        recipientNickname: isPrivate ? "builder" : nil,
        senderPeerID: senderPeerID
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
        let first = PeerHandle(id: "noise:abc123", routingPeerID: PeerID(str: "peer-a"))
        let second = PeerHandle(id: "noise:abc123", routingPeerID: PeerID(str: "peer-b"))

        #expect(first == second)
        #expect(Set([first, second]).count == 1)
    }

    @Test("ConversationStore orders timelines and replaces duplicates by message ID")
    @MainActor
    func conversationStoreOrdersAndDedupsMessages() {
        let store = ConversationStore()
        let older = makeArchitectureMessage(id: "m1", timestamp: 1, content: "first")
        let newer = makeArchitectureMessage(id: "m2", timestamp: 2, content: "second")
        let replacement = makeArchitectureMessage(id: "m2", timestamp: 2, content: "second-updated")

        store.append(newer, to: .mesh)
        store.append(older, to: .mesh)
        store.upsertByID(replacement, in: .mesh)

        let messages = store.conversation(for: .mesh).messages
        #expect(messages.map(\.id) == ["m1", "m2"])
        #expect(messages.last?.content == "second-updated")
    }

    @Test("ConversationStore tracks unread direct conversations by routing peer ID")
    @MainActor
    func conversationStoreTracksUnreadDirectConversations() {
        let store = ConversationStore()
        let peerID = PeerID(str: "peer-1")
        let message = makeArchitectureMessage(id: "dm-1", isPrivate: true, senderPeerID: peerID)

        store.append(message, to: .directPeer(peerID))
        store.markUnread(.directPeer(peerID))

        #expect(store.conversation(for: .directPeer(peerID)).messages.map(\.id) == ["dm-1"])
        #expect(store.unreadDirectRoutingPeerIDs() == Set([peerID]))
        #expect(store.conversation(for: .directPeer(peerID)).isUnread)

        store.markRead(.directPeer(peerID))
        #expect(store.unreadDirectRoutingPeerIDs().isEmpty)
        #expect(!store.conversation(for: .directPeer(peerID)).isUnread)
    }

    @Test("ConversationStore derives the selected conversation from channel and private peer")
    @MainActor
    func conversationStoreTracksSelectedConversationContext() {
        let store = ConversationStore()
        let peerID = PeerID(str: "0011223344556677")
        let geohashChannel = ChannelID.location(GeohashChannel(level: .city, geohash: "9q8yy"))

        store.setActiveChannel(geohashChannel)
        store.setSelectedPrivatePeer(peerID)

        #expect(store.activeChannel == geohashChannel)
        #expect(store.selectedPrivatePeerID == peerID)
        // The open private chat wins the derived selection.
        #expect(store.selectedConversationID == ConversationID.directPeer(peerID))

        store.setSelectedPrivatePeer(nil)
        // Selection falls back to the active public channel.
        #expect(store.selectedConversationID == ConversationID(channelID: geohashChannel))

        store.setActiveChannel(.mesh)
        #expect(store.activeChannel == ChannelID.mesh)
        #expect(store.selectedPrivatePeerID == nil)
        #expect(store.selectedConversationID == ConversationID.mesh)
    }

    @Test("ConversationStore re-keys a direct conversation via the migrate intent")
    @MainActor
    func conversationStoreMigratesDirectConversationsBetweenPeerIDs() {
        let store = ConversationStore()
        let noiseKey = Data((0..<32).map(UInt8.init))
        let shortPeerID = PeerID(str: "0011223344556677")
        let fullPeerID = PeerID(hexData: noiseKey)

        store.append(
            makeArchitectureMessage(id: "dm-1", timestamp: 1, isPrivate: true, senderPeerID: shortPeerID),
            to: .directPeer(shortPeerID)
        )
        store.markUnread(.directPeer(shortPeerID))
        store.setSelectedPrivatePeer(shortPeerID)

        store.migrateConversation(from: .directPeer(shortPeerID), to: .directPeer(fullPeerID))

        // Raw keying: the old peer's conversation is gone, the new peer's
        // conversation holds the timeline, unread and selection carried over.
        #expect(store.conversationsByID[.directPeer(shortPeerID)] == nil)
        #expect(Set(store.directMessagesByRoutingPeerID().keys) == Set([fullPeerID]))
        #expect(store.directMessagesByRoutingPeerID()[fullPeerID]?.map(\.id) == ["dm-1"])
        #expect(store.unreadDirectRoutingPeerIDs() == Set([fullPeerID]))
        #expect(store.selectedPrivatePeerID == fullPeerID)
        #expect(store.selectedConversationID == ConversationID.directPeer(fullPeerID))
    }

    @Test("PrivateInboxModel reads direct message state from the ConversationStore")
    @MainActor
    func privateInboxModelReadsDirectMessageStateFromConversationStore() {
        let store = ConversationStore()
        let inboxModel = PrivateInboxModel(conversations: store)
        let messagePeerID = PeerID(str: "peer-1")
        let unreadOnlyPeerID = PeerID(str: "peer-2")
        let selectedOnlyPeerID = PeerID(str: "peer-3")

        store.append(
            makeArchitectureMessage(id: "dm-1", isPrivate: true, senderPeerID: messagePeerID),
            to: .directPeer(messagePeerID)
        )
        store.markUnread(.directPeer(messagePeerID))
        store.markUnread(.directPeer(unreadOnlyPeerID))
        store.setSelectedPrivatePeer(selectedOnlyPeerID)

        // Reads are synchronous against the single-writer store.
        #expect(inboxModel.selectedPeerID == selectedOnlyPeerID)
        #expect(inboxModel.unreadPeerIDs == Set([messagePeerID, unreadOnlyPeerID]))
        #expect(inboxModel.messages(for: messagePeerID).map(\.id) == ["dm-1"])
        #expect(inboxModel.messages(for: unreadOnlyPeerID).isEmpty)
        #expect(inboxModel.messages(for: selectedOnlyPeerID).isEmpty)
    }

    @Test("PrivateInboxModel republishes only for the selected conversation")
    @MainActor
    func privateInboxModelIsolatesBackgroundConversations() {
        let store = ConversationStore()
        let inboxModel = PrivateInboxModel(conversations: store)
        let selectedPeerID = PeerID(str: "peer-selected")
        let backgroundPeerID = PeerID(str: "peer-background")
        store.setSelectedPrivatePeer(selectedPeerID)

        var emissions = 0
        let cancellable = inboxModel.objectWillChange.sink { _ in emissions += 1 }
        defer { cancellable.cancel() }

        let baseline = emissions
        store.append(
            makeArchitectureMessage(id: "dm-bg-1", isPrivate: true, senderPeerID: backgroundPeerID),
            to: .directPeer(backgroundPeerID)
        )
        // An append to a background chat does not republish the model.
        #expect(emissions == baseline)

        store.append(
            makeArchitectureMessage(id: "dm-sel-1", isPrivate: true, senderPeerID: selectedPeerID),
            to: .directPeer(selectedPeerID)
        )
        #expect(emissions == baseline + 1)
        #expect(inboxModel.messages(for: selectedPeerID).map(\.id) == ["dm-sel-1"])
    }

    @Test("PrivateInboxModel republishes read receipts for the selected DM (ephemeral- and stable-keyed)")
    @MainActor
    func privateInboxModelRepublishesReadReceiptsForSelectedConversation() {
        // A DM's messages can live under BOTH .directPeer(ephemeral) and
        // .directPeer(stableKey) (mirroring shares one BitchatMessage
        // instance); the view's read-receipt update must fire no matter
        // which of the two keys the selection holds.
        let ephemeralPeerID = PeerID(str: "abcdef1234567890")
        let stablePeerID = PeerID(str: String(repeating: "ab", count: 32))

        for selectedPeerID in [ephemeralPeerID, stablePeerID] {
            let store = ConversationStore()
            let inboxModel = PrivateInboxModel(conversations: store)
            store.setSelectedPrivatePeer(selectedPeerID)

            // One shared instance mirrored into both direct conversations,
            // exactly like `mirrorToEphemeralIfNeeded`.
            let message = makeArchitectureMessage(
                id: "dm-read-1",
                isPrivate: true,
                senderPeerID: ephemeralPeerID
            )
            store.append(message, to: .directPeer(ephemeralPeerID))
            store.upsertByID(message, in: .directPeer(stablePeerID))

            var emissions = 0
            let cancellable = inboxModel.objectWillChange.sink { _ in emissions += 1 }
            defer { cancellable.cancel() }

            // ID-only intent — the exact call `ChatDeliveryCoordinator`
            // makes when a READ ack arrives.
            let read = DeliveryStatus.read(by: "builder", at: Date(timeIntervalSince1970: 100))
            #expect(store.setDeliveryStatus(read, forMessageID: "dm-read-1"))

            // The fan-out emits .statusChanged for both containing
            // conversations; exactly the selected one republishes the model.
            #expect(emissions == 1)
            #expect(inboxModel.messages(for: selectedPeerID).first?.deliveryStatus == read)
        }
    }

    @Test("PublicChatModel ignores appends to background conversations")
    @MainActor
    func publicChatModelIsolatesBackgroundConversations() {
        let store = ConversationStore()
        store.setActiveChannel(.mesh)
        let model = PublicChatModel(conversations: store)

        var emissions = 0
        let cancellable = model.objectWillChange.sink { _ in emissions += 1 }
        defer { cancellable.cancel() }

        store.append(makeArchitectureMessage(id: "mesh-1"), to: .mesh)
        let afterActiveAppend = emissions
        #expect(afterActiveAppend >= 1)
        #expect(model.messages.map(\.id) == ["mesh-1"])

        // Appends to a background geohash channel and to a private chat do
        // not invalidate the observer of the active conversation.
        store.append(makeArchitectureMessage(id: "geo-1"), to: .geohash("u4pruyd"))
        store.append(
            makeArchitectureMessage(id: "dm-1", isPrivate: true),
            to: .directPeer(PeerID(str: "peer-1"))
        )
        #expect(emissions == afterActiveAppend)
        #expect(model.messages.map(\.id) == ["mesh-1"])

        // Switching the channel retargets the observation.
        store.setActiveChannel(.location(GeohashChannel(level: .neighborhood, geohash: "u4pruyd")))
        #expect(model.messages.map(\.id) == ["geo-1"])
        store.append(makeArchitectureMessage(id: "geo-2", timestamp: 1), to: .geohash("u4pruyd"))
        #expect(model.messages.map(\.id) == ["geo-1", "geo-2"])
    }

    @Test("AppChromeModel mirrors nickname and unread state through focused models")
    @MainActor
    func appChromeModelMirrorsNicknameAndUnreadState() async {
        let viewModel = makeArchitectureViewModel()
        let conversations = ConversationStore()
        let privateInboxModel = PrivateInboxModel(conversations: conversations)
        let chromeModel = AppChromeModel(chatViewModel: viewModel, privateInboxModel: privateInboxModel)

        chromeModel.setNickname("builder")
        await waitUntil {
            viewModel.nickname == "builder" && chromeModel.nickname == "builder"
        }

        #expect(viewModel.nickname == "builder")
        #expect(chromeModel.nickname == "builder")
        #expect(!chromeModel.hasUnreadPrivateMessages)

        let peerID = PeerID(str: "peer-1")
        conversations.markUnread(.directPeer(peerID))
        await waitUntil {
            chromeModel.hasUnreadPrivateMessages
        }

        #expect(chromeModel.hasUnreadPrivateMessages)
    }

    @Test("AppChromeModel owns fingerprint and screenshot presentation state")
    @MainActor
    func appChromeModelOwnsPresentationState() {
        let viewModel = makeArchitectureViewModel()
        let privateInboxModel = PrivateInboxModel(conversations: ConversationStore())
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
        let locationChannelsModel = LocationChannelsModel(manager: makeArchitectureLocationManager())
        let conversationModel = PrivateConversationModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
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

        locationManager.select(.mesh)
        let locationChannelsModel = LocationChannelsModel(manager: locationManager)
        let privateConversationModel = PrivateConversationModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: locationChannelsModel
        )
        let uiModel = ConversationUIModel(
            chatViewModel: viewModel,
            privateConversationModel: privateConversationModel,
            conversations: viewModel.conversations
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
        let locationChannelsModel = LocationChannelsModel(manager: makeArchitectureLocationManager())
        let privateConversationModel = PrivateConversationModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
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

    @Test("VerificationModel refreshes when peer trust changes (vouch accepted)")
    @MainActor
    func verificationModelRefreshesOnPeerTrustChange() async {
        let viewModel = makeArchitectureViewModel()
        var privateConversationModel: PrivateConversationModel? = PrivateConversationModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: LocationChannelsModel(manager: makeArchitectureLocationManager())
        )
        let verificationModel = VerificationModel(
            chatViewModel: viewModel,
            privateConversationModel: privateConversationModel!
        )

        // PrivateConversationModel happens to observe the same notification
        // and re-assign its published selection, which would ripple into
        // VerificationModel; release it so this test pins VerificationModel's
        // own subscription rather than that incidental chain.
        privateConversationModel = nil

        // The bound @Published sources replay their current values on
        // subscription; let those initial main-queue emissions settle so the
        // sink below observes only the trust-change signal.
        try? await Task.sleep(nanoseconds: 100_000_000)

        // ChatVouchCoordinator.notifyPeerTrustChanged() signals accepted
        // vouches via "peerStatusUpdated"; an open fingerprint sheet must
        // re-render its vouched badge from that signal alone.
        var refreshed = false
        let cancellable = verificationModel.objectWillChange.sink { _ in
            refreshed = true
        }
        defer { cancellable.cancel() }

        NotificationCenter.default.post(name: Notification.Name("peerStatusUpdated"), object: nil)
        await waitUntil { refreshed }
        #expect(refreshed)
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
        viewModel.markPrivateChatUnread(otherPeerID)
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
            conversations: viewModel.conversations,
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
