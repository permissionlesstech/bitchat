import BitFoundation
import Testing
import Foundation
@testable import bitchat

@MainActor
private func makePeerPresentationViewModel() -> (viewModel: ChatViewModel, transport: MockTransport) {
    TestHelpers.resetSharedApplicationState()
    let keychain = MockKeychain()
    let keychainHelper = MockKeychainHelper()
    let idBridge = NostrIdentityBridge(keychain: keychainHelper)
    let identityManager = MockIdentityManager(keychain)
    let transport = MockTransport()

    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        transport: transport
    )

    return (viewModel, transport)
}

private func makePeerSnapshot(peerID: PeerID, nickname: String, noiseByte: UInt8) -> TransportPeerSnapshot {
    TransportPeerSnapshot(
        peerID: peerID,
        nickname: nickname,
        isConnected: true,
        noisePublicKey: Data(repeating: noiseByte, count: 32),
        lastSeen: Date()
    )
}

@MainActor
@Suite(.serialized)
struct PeerPresentationStoreTests {

    @Test
    func storeReflectsSelectionAndNormalizesFingerprintPresentationPeer() async {
        let (viewModel, transport) = makePeerPresentationViewModel()
        let store = viewModel.peerPresentationStore
        let shortPeerID = PeerID(str: "1234567812345678")
        let fullNoiseKey = PeerID(hexData: Data(repeating: 0x11, count: 32))

        transport.updatePeerSnapshots([
            makePeerSnapshot(peerID: shortPeerID, nickname: "Alice", noiseByte: 0x11)
        ])
        try? await Task.sleep(nanoseconds: 50_000_000)

        viewModel.privateChatManager.startChat(with: shortPeerID)
        store.showFingerprint(for: fullNoiseKey)

        #expect(store.selectedPeer == shortPeerID)
        #expect(store.showingFingerprintFor == shortPeerID)
        #expect(viewModel.showingFingerprintFor == shortPeerID)
    }

    @Test
    func verifyAndUnverifyFingerprintFlowBackToChatViewModel() {
        let (viewModel, transport) = makePeerPresentationViewModel()
        let store = viewModel.peerPresentationStore
        let peerID = PeerID(str: "8765432187654321")
        let fingerprint = String(repeating: "ab", count: 32)

        transport.peerFingerprints[peerID] = fingerprint

        store.verifyFingerprint(for: peerID)
        #expect(store.verifiedFingerprints.contains(fingerprint))
        #expect(viewModel.verifiedFingerprints.contains(fingerprint))

        store.unverifyFingerprint(for: peerID)
        #expect(!store.verifiedFingerprints.contains(fingerprint))
        #expect(!viewModel.verifiedFingerprints.contains(fingerprint))
    }
}
