import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEAnnounceHandlingPolicyTests {
    @Test
    func preflightAcceptsMatchingFreshAnnounce() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x11, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(noisePublicKey: noiseKey, peerID: peerID, timestamp: timestamp(now))

        let decision = BLEAnnouncePreflightPolicy.evaluate(
            packet: packet,
            from: peerID,
            localPeerID: PeerID(str: "0102030405060708"),
            now: now
        )

        guard case .accept(let accepted) = decision else {
            Issue.record("Expected announce preflight acceptance")
            return
        }
        #expect(accepted.announcement.nickname == "Alice")
        #expect(accepted.derivedPeerID == peerID)
    }

    @Test
    func preflightRejectsMalformedPayload() {
        let now = Date(timeIntervalSince1970: 1_000)
        let peerID = PeerID(str: "1122334455667788")
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: peerID.id) ?? Data(),
            recipientID: nil,
            timestamp: timestamp(now),
            payload: Data([0x01, 0x20]),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )

        let decision = BLEAnnouncePreflightPolicy.evaluate(
            packet: packet,
            from: peerID,
            localPeerID: PeerID(str: "0102030405060708"),
            now: now
        )

        guard case .reject(.malformed) = decision else {
            Issue.record("Expected malformed announce rejection")
            return
        }
    }

    @Test
    func preflightRejectsSenderMismatchWithDerivedPeerID() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x22, count: 32)
        let derivedPeerID = PeerID(publicKey: noiseKey)
        let claimedPeerID = PeerID(str: "1122334455667788")
        let packet = try makeAnnouncePacket(noisePublicKey: noiseKey, peerID: claimedPeerID, timestamp: timestamp(now))

        let decision = BLEAnnouncePreflightPolicy.evaluate(
            packet: packet,
            from: claimedPeerID,
            localPeerID: PeerID(str: "0102030405060708"),
            now: now
        )

        guard case .reject(.senderMismatch(let rejectedDerivedPeerID)) = decision else {
            Issue.record("Expected sender mismatch rejection")
            return
        }
        #expect(rejectedDerivedPeerID == derivedPeerID)
    }

    @Test
    func preflightRejectsSelfAnnounceAfterSenderMatches() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x33, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(noisePublicKey: noiseKey, peerID: peerID, timestamp: timestamp(now))

        let decision = BLEAnnouncePreflightPolicy.evaluate(
            packet: packet,
            from: peerID,
            localPeerID: peerID,
            now: now
        )

        guard case .reject(.selfAnnounce) = decision else {
            Issue.record("Expected self announce rejection")
            return
        }
    }

    @Test
    func preflightRejectsStaleAnnounceWithAge() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x44, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let oldTimestamp = UInt64((now.timeIntervalSince1970 - 901) * 1000)
        let packet = try makeAnnouncePacket(noisePublicKey: noiseKey, peerID: peerID, timestamp: oldTimestamp)

        let decision = BLEAnnouncePreflightPolicy.evaluate(
            packet: packet,
            from: peerID,
            localPeerID: PeerID(str: "0102030405060708"),
            now: now
        )

        guard case .reject(.stale(let ageSeconds)) = decision else {
            Issue.record("Expected stale announce rejection")
            return
        }
        #expect(abs(ageSeconds - 901) < 0.001)
    }

    @Test
    func trustPolicyRequiresSignature() {
        let decision = BLEAnnounceTrustPolicy.evaluate(
            hasSignature: false,
            signatureValid: false,
            existingNoisePublicKey: nil,
            announcedNoisePublicKey: Data(repeating: 0x11, count: 32)
        )

        #expect(decision == .reject(.missingSignature))
        #expect(!decision.isVerified)
    }

    @Test
    func trustPolicyRejectsInvalidSignature() {
        let decision = BLEAnnounceTrustPolicy.evaluate(
            hasSignature: true,
            signatureValid: false,
            existingNoisePublicKey: nil,
            announcedNoisePublicKey: Data(repeating: 0x11, count: 32)
        )

        #expect(decision == .reject(.invalidSignature))
    }

    @Test
    func trustPolicyRejectsExistingKeyMismatch() {
        let decision = BLEAnnounceTrustPolicy.evaluate(
            hasSignature: true,
            signatureValid: true,
            existingNoisePublicKey: Data(repeating: 0xAA, count: 32),
            announcedNoisePublicKey: Data(repeating: 0xBB, count: 32)
        )

        #expect(decision == .reject(.keyMismatch))
    }

    @Test
    func trustPolicyAcceptsValidSignatureWithMatchingExistingKey() {
        let noiseKey = Data(repeating: 0xCC, count: 32)

        let decision = BLEAnnounceTrustPolicy.evaluate(
            hasSignature: true,
            signatureValid: true,
            existingNoisePublicKey: noiseKey,
            announcedNoisePublicKey: noiseKey
        )

        #expect(decision == .verified)
        #expect(decision.isVerified)
    }

    @Test
    func responsePolicyConnectsOnlyForDirectNewOrReconnectedPeers() {
        let directNew = BLEAnnounceResponsePolicy.plan(
            isDirectAnnounce: true,
            isNewPeer: true,
            isReconnectedPeer: false,
            shouldSendAnnounceBack: false
        )
        #expect(directNew.shouldNotifyPeerConnected)
        #expect(directNew.shouldScheduleInitialSync)
        #expect(directNew.shouldScheduleAfterglow)

        let relayedNew = BLEAnnounceResponsePolicy.plan(
            isDirectAnnounce: false,
            isNewPeer: true,
            isReconnectedPeer: false,
            shouldSendAnnounceBack: true
        )
        #expect(!relayedNew.shouldNotifyPeerConnected)
        #expect(!relayedNew.shouldScheduleInitialSync)
        #expect(relayedNew.shouldSendAnnounceBack)
        #expect(relayedNew.shouldScheduleAfterglow)

        let directExisting = BLEAnnounceResponsePolicy.plan(
            isDirectAnnounce: true,
            isNewPeer: false,
            isReconnectedPeer: false,
            shouldSendAnnounceBack: false
        )
        #expect(!directExisting.shouldNotifyPeerConnected)
        #expect(!directExisting.shouldScheduleInitialSync)
        #expect(!directExisting.shouldScheduleAfterglow)
    }

    private func makeAnnouncePacket(
        noisePublicKey: Data,
        peerID: PeerID,
        timestamp: UInt64
    ) throws -> BitchatPacket {
        let announcement = AnnouncementPacket(
            nickname: "Alice",
            noisePublicKey: noisePublicKey,
            signingPublicKey: Data(repeating: 0x99, count: 32),
            directNeighbors: nil
        )
        let payload = try #require(announcement.encode())

        return BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: peerID.id) ?? Data(),
            recipientID: nil,
            timestamp: timestamp,
            payload: payload,
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )
    }

    private func timestamp(_ date: Date) -> UInt64 {
        UInt64(date.timeIntervalSince1970 * 1000)
    }
}
