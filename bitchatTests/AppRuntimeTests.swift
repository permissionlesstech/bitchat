import Foundation
import Testing
@testable import bitchat

@MainActor
@Suite(.serialized)
struct AppRuntimeTests {

    private func makeRuntime() -> AppRuntime {
        TestHelpers.resetSharedApplicationState()
        return AppRuntime()
    }

    @Test
    func runtime_exposesFeatureStoresFromChatViewModel() {
        let runtime = makeRuntime()

        #expect(runtime.publicTimelineStore === runtime.chatViewModel.timelineStore)
        #expect(runtime.privateConversationsStore === runtime.chatViewModel.privateChatManager)
        #expect(runtime.peerStore === runtime.chatViewModel.unifiedPeerService)
        #expect(runtime.geohashParticipantStore === runtime.chatViewModel.participantTracker)
        #expect(runtime.geohashPeopleStore.displayNameForPubkey("abcdef12") == "anon#ef12")
        #expect(runtime.composerStore === runtime.chatViewModel.composerStore)
        #expect(runtime.chatViewModel.geohashPeopleStore === runtime.geohashPeopleStore)
        #expect(runtime.sessionStore.nickname == runtime.chatViewModel.nickname)
        #expect(runtime.peerPresentationStore.verifiedFingerprints == runtime.chatViewModel.verifiedFingerprints)
        #expect(runtime.chatViewModel.verificationStore === runtime.verificationStore)
        #expect(runtime.chatViewModel.meshService.delegate === runtime.transportEventBridge)
        #expect(runtime.chatViewModel.meshService.peerEventsDelegate === runtime.transportEventBridge)
        #expect(runtime.chatViewModel.publicMessagePipeline.delegate === runtime.transportController)
    }

    @Test
    func start_attachesNotificationDelegateToLiveViewModel() {
        let runtime = makeRuntime()

        runtime.start()
        runtime.attach()

        #expect(NotificationDelegate.shared.chatViewModel === runtime.chatViewModel)
    }

    @Test
    func transportController_routesBluetoothCallbacksToRuntimeStores() async {
        let runtime = makeRuntime()

        runtime.transportController.handle(.bluetoothStateUpdated(.poweredOff))

        let didRoute = await TestHelpers.waitUntil(
            {
                runtime.sessionStore.bluetoothState == .poweredOff &&
                runtime.sessionStore.showBluetoothAlert &&
                runtime.chatViewModel.bluetoothState == .poweredOff
            },
            timeout: TestConstants.shortTimeout
        )

        #expect(didRoute)
    }

    @Test
    func transportEventBridge_routesPublicMessagesThroughRuntimeController() async {
        let runtime = makeRuntime()
        let peerID = PeerID(str: "0011223344556677")

        runtime.chatViewModel.meshService.delegate?.didReceivePublicMessage(
            from: peerID,
            nickname: "Alice",
            content: "Runtime public",
            timestamp: Date(),
            messageID: "runtime-public"
        )

        let didRoute = await TestHelpers.waitUntil(
            {
                runtime.publicTimelineStore
                    .messages(for: .mesh)
                    .contains(where: { $0.id == "runtime-public" && $0.content == "Runtime public" })
            },
            timeout: TestConstants.defaultTimeout
        )

        #expect(didRoute)
    }

    @Test
    func transportEventBridge_routesPeerListCallbacksToSessionStore() async {
        let runtime = makeRuntime()
        let peerID = PeerID(str: "8899aabbccddeeff")

        runtime.chatViewModel.meshService.delegate?.didUpdatePeerList([peerID])

        let didRoute = await TestHelpers.waitUntil(
            { runtime.sessionStore.isConnected },
            timeout: TestConstants.defaultTimeout
        )

        #expect(didRoute)
    }

    @Test
    func transportController_routesPeerSnapshotsThroughRuntimePeerStore() async {
        let runtime = makeRuntime()
        let peerID = PeerID(str: "0102030405060708")
        let snapshot = TransportPeerSnapshot(
            peerID: peerID,
            nickname: "Alice",
            isConnected: true,
            noisePublicKey: Data(repeating: 0xAB, count: 32),
            lastSeen: Date()
        )

        runtime.transportController.handle(.peerSnapshotsUpdated([snapshot]))

        let didRoute = await TestHelpers.waitUntil(
            {
                runtime.peerStore.connectedPeerIDs.contains(peerID) &&
                runtime.peerStore.getPeer(by: peerID)?.nickname == "Alice"
            },
            timeout: TestConstants.defaultTimeout
        )

        #expect(didRoute)
    }
}
