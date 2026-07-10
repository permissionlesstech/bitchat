//
// ChatVerificationCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatVerificationCoordinator` against a mock
// `ChatVerificationContext` — proving the coordinator works without a
// `ChatViewModel`, following the `ChatDeliveryCoordinatorContextTests` /
// `ChatPrivateConversationCoordinatorContextTests` exemplars.
//
// Scope note: `handleVerifyResponsePayload` requires a real Ed25519
// signature; it remains covered by the full view-model/integration tests.
// Challenge handling, QR kickoff, fingerprint verification, verified-set
// loading, and the mutual-verification notification (posted through the
// injected context) are covered here (`VerificationService.shared` is only
// used for pure payload build/parse).
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatVerificationContext` proving that
/// `ChatVerificationCoordinator` is testable without a `ChatViewModel`.
@MainActor
private final class MockChatVerificationContext: ChatVerificationContext {
    // Fingerprints & verification state
    var fingerprintsByPeerID: [PeerID: String] = [:]
    var verifiedFingerprints: Set<String> = []
    var persistedFingerprints: Set<String> = []
    private(set) var identityVerifiedCalls: [(fingerprint: String, verified: Bool)] = []
    private(set) var storedVerifiedCalls: [(fingerprint: String, verified: Bool)] = []
    private(set) var saveIdentityStateCount = 0

    func getFingerprint(for peerID: PeerID) -> String? { fingerprintsByPeerID[peerID] }
    func persistedVerifiedFingerprints() -> Set<String> { persistedFingerprints }

    func setIdentityVerified(fingerprint: String, verified: Bool) {
        identityVerifiedCalls.append((fingerprint, verified))
    }

    func setStoredVerified(_ fingerprint: String, verified: Bool) {
        storedVerifiedCalls.append((fingerprint, verified))
    }

    func isVerifiedFingerprint(_ fingerprint: String) -> Bool {
        verifiedFingerprints.contains(fingerprint)
    }

    func saveIdentityState() { saveIdentityStateCount += 1 }

    private(set) var vouchToConnectedVerifiedPeersCount = 0
    func vouchToConnectedVerifiedPeers() { vouchToConnectedVerifiedPeersCount += 1 }

    // Encryption status
    private(set) var encryptionStatuses: [PeerID: EncryptionStatus?] = [:]
    private(set) var updatedEncryptionStatusPeers: [PeerID] = []
    private(set) var invalidatedEncryptionCachePeers: [PeerID?] = []
    private(set) var notifyUIChangedCount = 0

    func setEncryptionStatus(_ status: EncryptionStatus?, for peerID: PeerID) {
        encryptionStatuses[peerID] = status
    }

    func updateEncryptionStatus(for peerID: PeerID) {
        updatedEncryptionStatusPeers.append(peerID)
    }

    func invalidateEncryptionCache(for peerID: PeerID?) {
        invalidatedEncryptionCachePeers.append(peerID)
    }

    func notifyUIChanged() { notifyUIChangedCount += 1 }

    // Peers
    var unifiedPeers: [BitchatPeer] = []
    var unifiedFavorites: [BitchatPeer] = []
    private(set) var stablePeerIDCache: [PeerID: PeerID] = [:]

    func unifiedPeer(for peerID: PeerID) -> BitchatPeer? {
        unifiedPeers.first { $0.peerID == peerID }
    }

    func unifiedFingerprint(for peerID: PeerID) -> String? { fingerprintsByPeerID[peerID] }
    func resolveNickname(for peerID: PeerID) -> String { "anon\(peerID.id.prefix(4))" }
    func cachedStablePeerID(for shortPeerID: PeerID) -> PeerID? { stablePeerIDCache[shortPeerID] }

    func cacheStablePeerID(_ stablePeerID: PeerID, for shortPeerID: PeerID) {
        stablePeerIDCache[shortPeerID] = stablePeerID
    }

    // Noise sessions & verification transport
    var myNoiseStaticKey = Data(repeating: 0x42, count: 32)
    var establishedNoiseSessions: Set<PeerID> = []
    var noiseSessionKeysByPeerID: [PeerID: Data] = [:]
    private(set) var installedCallbacks: (onPeerAuthenticated: (PeerID, String) -> Void, onHandshakeRequired: (PeerID) -> Void)?
    private(set) var triggeredHandshakes: [PeerID] = []
    private(set) var sentChallenges: [(peerID: PeerID, noiseKeyHex: String, nonceA: Data)] = []
    private(set) var sentResponses: [(peerID: PeerID, noiseKeyHex: String, nonceA: Data)] = []

    func installNoiseSessionCallbacks(
        onPeerAuthenticated: @escaping (PeerID, String) -> Void,
        onHandshakeRequired: @escaping (PeerID) -> Void
    ) {
        installedCallbacks = (onPeerAuthenticated, onHandshakeRequired)
    }

    func noiseSessionPublicKeyData(for peerID: PeerID) -> Data? { noiseSessionKeysByPeerID[peerID] }
    func noiseStaticPublicKeyData() -> Data { myNoiseStaticKey }
    func hasEstablishedNoiseSession(with peerID: PeerID) -> Bool {
        establishedNoiseSessions.contains(peerID)
    }
    func triggerHandshake(with peerID: PeerID) { triggeredHandshakes.append(peerID) }

    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        sentChallenges.append((peerID, noiseKeyHex, nonceA))
    }

    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        sentResponses.append((peerID, noiseKeyHex, nonceA))
    }

    // Notifications
    private(set) var postedLocalNotifications: [(title: String, body: String, identifier: String)] = []

    func postLocalNotification(title: String, body: String, identifier: String) {
        postedLocalNotifications.append((title, body, identifier))
    }
}

// MARK: - Helpers

/// Builds the raw verify-challenge TLV as it arrives at the coordinator
/// (i.e. with the `NoisePayload` type byte already stripped).
private func makeVerifyChallengeTLV(noiseKeyHex: String, nonceA: Data) -> Data {
    var tlv = Data()
    tlv.append(0x01)
    tlv.append(UInt8(noiseKeyHex.count))
    tlv.append(Data(noiseKeyHex.utf8))
    tlv.append(0x02)
    tlv.append(UInt8(nonceA.count))
    tlv.append(nonceA)
    return tlv
}

private func makeVerificationQR(noiseKeyHex: String) -> VerificationService.VerificationQR {
    VerificationService.VerificationQR(
        v: 1,
        noiseKeyHex: noiseKeyHex,
        signKeyHex: "00" + String(repeating: "ab", count: 31),
        npub: nil,
        nickname: "alice",
        ts: 0,
        nonceB64: "",
        sigHex: ""
    )
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatVerificationCoordinator` against
/// `MockChatVerificationContext` with no `ChatViewModel`.
struct ChatVerificationCoordinatorContextTests {

    @Test @MainActor
    func verifyAndUnverifyFingerprint_updateBothStoresAndStatus() async {
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")

        // Unknown fingerprint: nothing happens.
        coordinator.verifyFingerprint(for: peerID)
        #expect(context.identityVerifiedCalls.isEmpty)

        context.fingerprintsByPeerID[peerID] = "fp"
        coordinator.verifyFingerprint(for: peerID)
        coordinator.unverifyFingerprint(for: peerID)

        #expect(context.identityVerifiedCalls.map(\.fingerprint) == ["fp", "fp"])
        #expect(context.identityVerifiedCalls.map(\.verified) == [true, false])
        #expect(context.storedVerifiedCalls.map(\.verified) == [true, false])
        #expect(context.saveIdentityStateCount == 2)
        #expect(context.updatedEncryptionStatusPeers == [peerID, peerID])
    }

    @Test @MainActor
    func beginQRVerification_sendsChallengeOrTriggersHandshake() async {
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context)
        let noiseKey = Data(repeating: 0xCD, count: 32)
        let peerID = PeerID(str: "1122334455667788")
        let qr = makeVerificationQR(noiseKeyHex: noiseKey.hexEncodedString())

        // No matching peer -> not started.
        #expect(!coordinator.beginQRVerification(with: qr))

        // Matching peer without an established session -> handshake first.
        context.unifiedPeers = [BitchatPeer(peerID: peerID, noisePublicKey: noiseKey, nickname: "alice")]
        #expect(coordinator.beginQRVerification(with: qr))
        #expect(context.triggeredHandshakes == [peerID])
        #expect(context.sentChallenges.isEmpty)

        // Already pending -> short-circuits without re-triggering.
        #expect(coordinator.beginQRVerification(with: qr))
        #expect(context.triggeredHandshakes == [peerID])

        // Fresh coordinator with an established session -> immediate challenge.
        let context2 = MockChatVerificationContext()
        context2.unifiedPeers = [BitchatPeer(peerID: peerID, noisePublicKey: noiseKey, nickname: "alice")]
        context2.establishedNoiseSessions = [peerID]
        let coordinator2 = ChatVerificationCoordinator(context: context2)
        #expect(coordinator2.beginQRVerification(with: qr))
        #expect(context2.sentChallenges.count == 1)
        #expect(context2.sentChallenges.first?.noiseKeyHex == qr.noiseKeyHex)
        #expect(context2.triggeredHandshakes.isEmpty)
    }

    @Test @MainActor
    func handleVerifyChallengePayload_respondsOncePerNonceForOurKeyOnly() async {
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        let myHex = context.myNoiseStaticKey.hexEncodedString()
        let nonce = Data(repeating: 0x07, count: 16)
        let payload = makeVerifyChallengeTLV(noiseKeyHex: myHex, nonceA: nonce)

        coordinator.handleVerifyChallengePayload(from: peerID, payload: payload)
        #expect(context.sentResponses.count == 1)
        #expect(context.sentResponses.first?.noiseKeyHex.lowercased() == myHex)
        #expect(context.sentResponses.first?.nonceA == nonce)

        // Same nonce again: deduplicated, no second response.
        coordinator.handleVerifyChallengePayload(from: peerID, payload: payload)
        #expect(context.sentResponses.count == 1)

        // A challenge for someone else's key is ignored.
        let otherHex = Data(repeating: 0x99, count: 32).hexEncodedString()
        let otherPayload = makeVerifyChallengeTLV(
            noiseKeyHex: otherHex,
            nonceA: Data(repeating: 0x08, count: 16)
        )
        coordinator.handleVerifyChallengePayload(from: peerID, payload: otherPayload)
        #expect(context.sentResponses.count == 1)
    }

    @Test @MainActor
    func loadVerifiedFingerprints_syncsPersistedSetAndRefreshesUI() async {
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context)
        context.persistedFingerprints = ["fp1", "fp2"]

        coordinator.loadVerifiedFingerprints()

        #expect(context.verifiedFingerprints == ["fp1", "fp2"])
        #expect(context.invalidatedEncryptionCachePeers == [nil])
        #expect(context.notifyUIChangedCount == 1)
    }

    @Test @MainActor
    func installedNoiseCallbacks_publishStatusAndStableIDs() async {
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        let noiseKey = Data(repeating: 0x33, count: 32)
        context.noiseSessionKeysByPeerID[peerID] = noiseKey
        context.verifiedFingerprints = ["fp-verified"]

        coordinator.setupNoiseCallbacks()
        let callbacks = context.installedCallbacks

        // Authenticated with a verified fingerprint -> verified status and a
        // cached stable peer ID derived from the session key.
        callbacks?.onPeerAuthenticated(peerID, "fp-verified")
        await waitForMainQueue()
        #expect(context.encryptionStatuses[peerID] == .noiseVerified)
        #expect(context.stablePeerIDCache[peerID] == PeerID(hexData: noiseKey))
        #expect(context.invalidatedEncryptionCachePeers.contains(peerID))

        // Handshake required -> handshaking status.
        callbacks?.onHandshakeRequired(peerID)
        await waitForMainQueue()
        #expect(context.encryptionStatuses[peerID] == .noiseHandshaking)
    }

    @Test @MainActor
    func handleVerifyChallengePayload_postsMutualVerificationToastOncePerMinute() async {
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        let myHex = context.myNoiseStaticKey.hexEncodedString()
        context.fingerprintsByPeerID[peerID] = "fp-mutual"
        context.verifiedFingerprints = ["fp-mutual"]

        coordinator.handleVerifyChallengePayload(
            from: peerID,
            payload: makeVerifyChallengeTLV(noiseKeyHex: myHex, nonceA: Data(repeating: 0x07, count: 16))
        )

        // Already-verified peer challenging us: mutual-verification toast.
        #expect(context.postedLocalNotifications.count == 1)
        #expect(context.postedLocalNotifications.first?.title == "Mutual verification")
        #expect(context.postedLocalNotifications.first?.body.hasSuffix("verified each other") == true)
        #expect(context.postedLocalNotifications.first?.identifier.hasPrefix("verify-mutual-") == true)

        // A fresh nonce inside the per-fingerprint toast cooldown stays silent.
        coordinator.handleVerifyChallengePayload(
            from: peerID,
            payload: makeVerifyChallengeTLV(noiseKeyHex: myHex, nonceA: Data(repeating: 0x08, count: 16))
        )
        #expect(context.postedLocalNotifications.count == 1)
        #expect(context.sentResponses.count == 2)
    }
}

/// The installed callbacks hop through `DispatchQueue.main.async`; tests must
/// let that queue drain before asserting.
@MainActor
private func waitForMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
