import Foundation
import Testing
@testable import bitchat

@MainActor
private func makeVerificationStoreHarness() -> (viewModel: ChatViewModel, transport: MockTransport, store: VerificationStore) {
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
    let verificationStore = viewModel.verificationStore

    return (viewModel, transport, verificationStore)
}

@MainActor
@Suite(.serialized)
struct VerificationStoreTests {

    @Test
    func beginQRVerificationQueuesHandshakeAndSendsAfterAuthentication() async {
        let (_, transport, store) = makeVerificationStoreHarness()
        let peerID = PeerID(str: "5657585960616263")
        let noiseKey = Data(repeating: 0x44, count: 32)
        let qr = VerificationService.VerificationQR(
            v: 1,
            noiseKeyHex: noiseKey.hexEncodedString(),
            signKeyHex: String(repeating: "aa", count: 32),
            npub: nil,
            nickname: "Verifier",
            ts: Int64(Date().timeIntervalSince1970),
            nonceB64: Data("nonce".utf8).base64EncodedString(),
            sigHex: ""
        )

        transport.updatePeerSnapshots([
            TransportPeerSnapshot(
                peerID: peerID,
                nickname: "Verifier",
                isConnected: true,
                noisePublicKey: noiseKey,
                lastSeen: Date()
            )
        ])
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.beginQRVerification(with: qr))
        #expect(transport.triggeredHandshakes == [peerID])
        #expect(transport.sentVerifyChallenges.isEmpty)

        store.handlePeerAuthenticated(peerID)

        #expect(transport.sentVerifyChallenges.count == 1)
        #expect(transport.sentVerifyChallenges.first?.0 == peerID)
        #expect(transport.sentVerifyChallenges.first?.1 == qr.noiseKeyHex)
    }

    @Test
    func beginQRVerificationRejectsUnknownNoiseKey() {
        let (_, transport, store) = makeVerificationStoreHarness()
        let qr = VerificationService.VerificationQR(
            v: 1,
            noiseKeyHex: String(repeating: "bb", count: 32),
            signKeyHex: String(repeating: "cc", count: 32),
            npub: nil,
            nickname: "Unknown",
            ts: Int64(Date().timeIntervalSince1970),
            nonceB64: Data("nonce".utf8).base64EncodedString(),
            sigHex: ""
        )

        #expect(!store.beginQRVerification(with: qr))
        #expect(transport.triggeredHandshakes.isEmpty)
        #expect(transport.sentVerifyChallenges.isEmpty)
    }
}
