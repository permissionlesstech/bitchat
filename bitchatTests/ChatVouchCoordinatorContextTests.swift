//
// ChatVouchCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatVouchCoordinator` against a mock `ChatVouchContext` —
// proving the exchange policy (verified + capable peers only, batch cap,
// 24h rate limit) and the accept policy (verified senders only, real
// Ed25519 signature verification, expiry) without a `ChatViewModel`.
// Storage-level gates (self-vouch, already-verified vouchee, per-vouchee
// cap) are covered by `SecureIdentityStateManagerVouchTests`.
//

import CryptoKit
import Foundation
import BitFoundation
import Testing

@testable import bitchat

// MARK: - Mock Context

@MainActor
private final class MockChatVouchContext: ChatVouchContext {
    // Identity & trust state
    var fingerprintsByPeerID: [PeerID: String] = [:]
    var verifiedFingerprints: Set<String> = []
    var signingKeysByFingerprint: [String: Data] = [:]
    var recentVerified: [String] = []
    private(set) var recentVerifiedRequests: [(limit: Int, excluding: String)] = []
    private(set) var recordedVouches: [(vouchee: String, voucher: String, timestamp: Date)] = []
    var recordVouchResult = true
    var lastBatchSentAt: [String: Date] = [:]
    private(set) var markedBatchSent: [(fingerprint: String, date: Date)] = []

    func getFingerprint(for peerID: PeerID) -> String? { fingerprintsByPeerID[peerID] }
    func isVerifiedFingerprint(_ fingerprint: String) -> Bool { verifiedFingerprints.contains(fingerprint) }
    func signingKey(forFingerprint fingerprint: String) -> Data? { signingKeysByFingerprint[fingerprint] }

    func recentlyVerifiedFingerprints(limit: Int, excluding fingerprint: String) -> [String] {
        recentVerifiedRequests.append((limit, fingerprint))
        return Array(recentVerified.filter { $0 != fingerprint }.prefix(limit))
    }

    @discardableResult
    func recordVouch(voucheeFingerprint: String, voucherFingerprint: String, timestamp: Date) -> Bool {
        recordedVouches.append((voucheeFingerprint, voucherFingerprint, timestamp))
        return recordVouchResult
    }

    func lastVouchBatchSent(to fingerprint: String) -> Date? { lastBatchSentAt[fingerprint] }

    func markVouchBatchSent(to fingerprint: String, at date: Date) {
        markedBatchSent.append((fingerprint, date))
        lastBatchSentAt[fingerprint] = date
    }

    // Transport
    var capabilitiesByPeerID: [PeerID: PeerCapabilities] = [:]
    var mySigningKey = Curve25519.Signing.PrivateKey()
    private(set) var installedObservers: [(PeerID, String) -> Void] = []
    private(set) var sentVouchPayloads: [(payload: Data, peerID: PeerID)] = []

    var connectedPeerIDList: [PeerID] = []

    func peerCapabilities(for peerID: PeerID) -> PeerCapabilities { capabilitiesByPeerID[peerID] ?? [] }

    func connectedPeerIDs() -> [PeerID] { connectedPeerIDList }

    func addPeerAuthenticatedObserver(_ handler: @escaping (PeerID, String) -> Void) {
        installedObservers.append(handler)
    }

    func noiseSignData(_ data: Data) -> Data? { try? mySigningKey.signature(for: data) }

    func sendVouchAttestations(_ payload: Data, to peerID: PeerID) {
        sentVouchPayloads.append((payload, peerID))
    }

    // UI refresh
    private(set) var trustChangedCount = 0

    func notifyPeerTrustChanged() { trustChangedCount += 1 }
}

// MARK: - Tests

struct ChatVouchCoordinatorContextTests {
    private let peerID = PeerID(str: "1122334455667788")
    private let peerFingerprint = String(repeating: "0f", count: 32)

    @MainActor
    private func makeVerifiedCapablePeer() -> (MockChatVouchContext, ChatVouchCoordinator) {
        let context = MockChatVouchContext()
        let coordinator = ChatVouchCoordinator(context: context)
        context.fingerprintsByPeerID[peerID] = peerFingerprint
        context.verifiedFingerprints.insert(peerFingerprint)
        context.capabilitiesByPeerID[peerID] = [.vouch]
        return (context, coordinator)
    }

    // MARK: Exchange policy

    @Test @MainActor
    func peerAuthenticated_sendsBatchForVerifiedCapablePeer() throws {
        let (context, coordinator) = makeVerifiedCapablePeer()
        let vouchees = [String(repeating: "01", count: 32), String(repeating: "02", count: 32)]
        context.recentVerified = vouchees
        for vouchee in vouchees {
            context.signingKeysByFingerprint[vouchee] = Data(repeating: 0x33, count: 32)
        }

        coordinator.peerAuthenticated(peerID, fingerprint: peerFingerprint)

        // Candidates are requested most-recent-first, excluding the target.
        #expect(context.recentVerifiedRequests.count == 1)
        #expect(context.recentVerifiedRequests.first?.limit == VouchAttestation.maxBatchCount)
        #expect(context.recentVerifiedRequests.first?.excluding == peerFingerprint)

        let sent = try #require(context.sentVouchPayloads.first)
        #expect(sent.peerID == peerID)
        let attestations = VouchAttestation.decodeList(from: sent.payload)
        #expect(attestations.map(\.voucheeFingerprintHex) == vouchees)
        // Every attestation carries a valid signature under our signing key.
        let myPublicKey = context.mySigningKey.publicKey.rawRepresentation
        #expect(attestations.allSatisfy { $0.verifySignature(voucherSigningKey: myPublicKey) })

        // The rate limit is stamped only after an actual send.
        #expect(context.markedBatchSent.map(\.fingerprint) == [peerFingerprint])
    }

    @Test @MainActor
    func peerAuthenticated_requiresVerificationAndCapability() {
        let (context, coordinator) = makeVerifiedCapablePeer()
        context.recentVerified = [String(repeating: "01", count: 32)]
        context.signingKeysByFingerprint[context.recentVerified[0]] = Data(repeating: 0x33, count: 32)

        // Not verified by me: nothing.
        context.verifiedFingerprints.remove(peerFingerprint)
        coordinator.peerAuthenticated(peerID, fingerprint: peerFingerprint)
        #expect(context.sentVouchPayloads.isEmpty)

        // Verified but advertises a non-empty capability set lacking .vouch:
        // nothing. (An *empty*/unknown set is race-tolerant and still sends —
        // see `attemptVouch_sendsWhenCapabilitiesUnknown`.)
        context.verifiedFingerprints.insert(peerFingerprint)
        context.capabilitiesByPeerID[peerID] = [.prekeys]
        coordinator.peerAuthenticated(peerID, fingerprint: peerFingerprint)
        #expect(context.sentVouchPayloads.isEmpty)
        #expect(context.markedBatchSent.isEmpty)
    }

    // MARK: Capability race tolerance & new triggers

    @Test @MainActor
    func attemptVouch_sendsWhenCapabilitiesUnknown() {
        // Capability set still empty at attempt time (the peer's .vouch bit
        // arrives on a later announce): the batch must still go out.
        let (context, coordinator) = makeVerifiedCapablePeer()
        context.capabilitiesByPeerID[peerID] = []
        context.recentVerified = [String(repeating: "01", count: 32)]
        context.signingKeysByFingerprint[context.recentVerified[0]] = Data(repeating: 0x33, count: 32)

        coordinator.peerAuthenticated(peerID, fingerprint: peerFingerprint)
        #expect(context.sentVouchPayloads.count == 1)
        #expect(context.markedBatchSent.map(\.fingerprint) == [peerFingerprint])
    }

    @Test @MainActor
    func vouchToConnectedVerifiedPeers_sendsToConnectedVerifiedCapablePeer() {
        let (context, coordinator) = makeVerifiedCapablePeer()
        context.connectedPeerIDList = [peerID]
        context.recentVerified = [String(repeating: "01", count: 32)]
        context.signingKeysByFingerprint[context.recentVerified[0]] = Data(repeating: 0x33, count: 32)

        // Session is already up (no peerAuthenticated re-fire); the verify pass
        // is what makes the batch go out.
        coordinator.vouchToConnectedVerifiedPeers()
        let sent = context.sentVouchPayloads
        #expect(sent.count == 1)
        #expect(sent.first?.peerID == peerID)
        #expect(context.markedBatchSent.map(\.fingerprint) == [peerFingerprint])
    }

    @Test @MainActor
    func vouchToConnectedVerifiedPeers_skipsUnverifiedConnectedPeers() {
        let (context, coordinator) = makeVerifiedCapablePeer()
        context.connectedPeerIDList = [peerID]
        context.verifiedFingerprints.remove(peerFingerprint)
        context.recentVerified = [String(repeating: "01", count: 32)]
        context.signingKeysByFingerprint[context.recentVerified[0]] = Data(repeating: 0x33, count: 32)

        coordinator.vouchToConnectedVerifiedPeers()
        #expect(context.sentVouchPayloads.isEmpty)
    }

    @Test @MainActor
    func peersUpdated_sendsOnceCapabilityBearingAnnounceArrives() {
        let (context, coordinator) = makeVerifiedCapablePeer()
        context.recentVerified = [String(repeating: "01", count: 32)]
        context.signingKeysByFingerprint[context.recentVerified[0]] = Data(repeating: 0x33, count: 32)

        // First announce before the .vouch bit is known: empty set is
        // race-tolerant, so it already sends and stamps the throttle.
        context.capabilitiesByPeerID[peerID] = []
        coordinator.peersUpdated([peerID])
        #expect(context.sentVouchPayloads.count == 1)

        // A later announce carrying .vouch must not double-send (throttled).
        context.capabilitiesByPeerID[peerID] = [.vouch]
        coordinator.peersUpdated([peerID])
        #expect(context.sentVouchPayloads.count == 1)
    }

    @Test @MainActor
    func peerAuthenticated_rateLimitsPerPeerPer24Hours() {
        let (context, coordinator) = makeVerifiedCapablePeer()
        context.recentVerified = [String(repeating: "01", count: 32)]
        context.signingKeysByFingerprint[context.recentVerified[0]] = Data(repeating: 0x33, count: 32)

        let now = Date()
        context.lastBatchSentAt[peerFingerprint] = now.addingTimeInterval(-60 * 60)
        coordinator.peerAuthenticated(peerID, fingerprint: peerFingerprint, now: now)
        #expect(context.sentVouchPayloads.isEmpty)

        // Once the interval has elapsed the batch goes out again.
        context.lastBatchSentAt[peerFingerprint] = now.addingTimeInterval(-ChatVouchCoordinator.batchInterval - 1)
        coordinator.peerAuthenticated(peerID, fingerprint: peerFingerprint, now: now)
        #expect(context.sentVouchPayloads.count == 1)
    }

    @Test @MainActor
    func peerAuthenticated_skipsCandidatesWithoutSigningKeysAndEmptyBatches() {
        let (context, coordinator) = makeVerifiedCapablePeer()
        let withKey = String(repeating: "01", count: 32)
        let withoutKey = String(repeating: "02", count: 32)
        context.recentVerified = [withoutKey, withKey]
        context.signingKeysByFingerprint[withKey] = Data(repeating: 0x33, count: 32)

        coordinator.peerAuthenticated(peerID, fingerprint: peerFingerprint)
        let attestations = VouchAttestation.decodeList(from: context.sentVouchPayloads[0].payload)
        #expect(attestations.map(\.voucheeFingerprintHex) == [withKey])

        // No signable candidates at all: nothing is sent or rate-stamped.
        let freshPeer = PeerID(str: "aabbccddeeff0011")
        let freshFingerprint = String(repeating: "0e", count: 32)
        context.fingerprintsByPeerID[freshPeer] = freshFingerprint
        context.verifiedFingerprints.insert(freshFingerprint)
        context.capabilitiesByPeerID[freshPeer] = [.vouch]
        context.recentVerified = [withoutKey]
        coordinator.peerAuthenticated(freshPeer, fingerprint: freshFingerprint)
        #expect(context.sentVouchPayloads.count == 1)
        #expect(!context.markedBatchSent.contains { $0.fingerprint == freshFingerprint })
    }

    // MARK: Accept policy

    @MainActor
    private func makeInboundBatch(
        signedBy key: Curve25519.Signing.PrivateKey,
        vouchee: String = String(repeating: "07", count: 32),
        timestampMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)
    ) throws -> Data {
        let voucheeData = try #require(Data(hexString: vouchee))
        let attestation = try #require(VouchAttestation.build(
            voucheeFingerprint: voucheeData,
            voucheeSigningKey: Data(repeating: 0x44, count: 32),
            timestampMs: timestampMs,
            sign: { try? key.signature(for: $0) }
        ))
        return try #require(VouchAttestation.encodeList([attestation]))
    }

    @Test @MainActor
    func handleVouchPayload_acceptsValidVouchFromVerifiedSender() throws {
        let (context, coordinator) = makeVerifiedCapablePeer()
        let senderKey = Curve25519.Signing.PrivateKey()
        context.signingKeysByFingerprint[peerFingerprint] = senderKey.publicKey.rawRepresentation

        let vouchee = String(repeating: "07", count: 32)
        let payload = try makeInboundBatch(signedBy: senderKey, vouchee: vouchee)
        coordinator.handleVouchPayload(from: peerID, payload: payload)

        #expect(context.recordedVouches.count == 1)
        #expect(context.recordedVouches.first?.vouchee == vouchee)
        #expect(context.recordedVouches.first?.voucher == peerFingerprint)
        #expect(context.trustChangedCount == 1)
    }

    @Test @MainActor
    func handleVouchPayload_rejectsUnverifiedOrUnknownSender() throws {
        let (context, coordinator) = makeVerifiedCapablePeer()
        let senderKey = Curve25519.Signing.PrivateKey()
        context.signingKeysByFingerprint[peerFingerprint] = senderKey.publicKey.rawRepresentation
        let payload = try makeInboundBatch(signedBy: senderKey)

        // Sender's fingerprint is not in my verified set.
        context.verifiedFingerprints.remove(peerFingerprint)
        coordinator.handleVouchPayload(from: peerID, payload: payload)
        #expect(context.recordedVouches.isEmpty)

        // Unknown peer entirely.
        coordinator.handleVouchPayload(from: PeerID(str: "ffeeddccbbaa9988"), payload: payload)
        #expect(context.recordedVouches.isEmpty)
        #expect(context.trustChangedCount == 0)
    }

    @Test @MainActor
    func handleVouchPayload_rejectsForgedSignaturesAndExpiredAttestations() throws {
        let (context, coordinator) = makeVerifiedCapablePeer()
        let senderKey = Curve25519.Signing.PrivateKey()
        context.signingKeysByFingerprint[peerFingerprint] = senderKey.publicKey.rawRepresentation

        // Signed by an imposter key: signature check against the sender's
        // announce-bound key fails.
        let imposter = Curve25519.Signing.PrivateKey()
        let forged = try makeInboundBatch(signedBy: imposter)
        coordinator.handleVouchPayload(from: peerID, payload: forged)
        #expect(context.recordedVouches.isEmpty)

        // Correctly signed but expired.
        let staleMs = UInt64(Date().addingTimeInterval(-31 * 24 * 60 * 60).timeIntervalSince1970 * 1000)
        let expired = try makeInboundBatch(signedBy: senderKey, timestampMs: staleMs)
        coordinator.handleVouchPayload(from: peerID, payload: expired)
        #expect(context.recordedVouches.isEmpty)
        #expect(context.trustChangedCount == 0)

        // No signing key known for the sender: batch dropped.
        context.signingKeysByFingerprint.removeValue(forKey: peerFingerprint)
        let valid = try makeInboundBatch(signedBy: senderKey)
        coordinator.handleVouchPayload(from: peerID, payload: valid)
        #expect(context.recordedVouches.isEmpty)
    }

    @Test @MainActor
    func handleVouchPayload_skipsUIRefreshWhenNothingStored() throws {
        let (context, coordinator) = makeVerifiedCapablePeer()
        let senderKey = Curve25519.Signing.PrivateKey()
        context.signingKeysByFingerprint[peerFingerprint] = senderKey.publicKey.rawRepresentation
        context.recordVouchResult = false // e.g. self-vouch dropped by the store

        let payload = try makeInboundBatch(signedBy: senderKey)
        coordinator.handleVouchPayload(from: peerID, payload: payload)
        #expect(context.recordedVouches.count == 1)
        #expect(context.trustChangedCount == 0)
    }

    @Test @MainActor
    func setupNoiseCallbacks_installsAdditiveObserver() {
        let (context, coordinator) = makeVerifiedCapablePeer()
        coordinator.setupNoiseCallbacks()
        #expect(context.installedObservers.count == 1)
    }
}
