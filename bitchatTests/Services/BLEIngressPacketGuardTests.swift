import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("BLE ingress packet guard tests")
struct BLEIngressPacketGuardTests {
    @Test("valid packets return the received and validation peer context")
    func validPacketsReturnContext() throws {
        let local = PeerID(str: "0011223344556677")
        let bound = PeerID(str: "1122334455667788")
        let sender = PeerID(str: "8899aabbccddeeff")
        let packet = makePacket(sender: sender, timestamp: 1_000)

        let context = try #require(success(BLEIngressPacketGuard.evaluate(
            packet: packet,
            claimedSenderID: sender,
            boundPeerID: bound,
            localPeerID: local,
            directAnnounceTTL: 7,
            nowMs: 1_000,
            isValidSyncResponse: { _ in false }
        )))

        #expect(context.receivedFromPeerID == bound)
        #expect(context.validationPeerID == sender)
    }

    @Test("self loopback and request-sync spoofing are rejected before timestamp checks")
    func linkBindingRejectionsWinBeforeTimestampChecks() {
        let local = PeerID(str: "0011223344556677")
        let bound = PeerID(str: "1122334455667788")
        let claimed = PeerID(str: "8899aabbccddeeff")
        let selfPacket = makePacket(sender: local, timestamp: 0)
        let spoofedRequestSync = makePacket(type: .requestSync, sender: claimed, timestamp: 0, ttl: 0)

        let selfResult = BLEIngressPacketGuard.evaluate(
            packet: selfPacket,
            claimedSenderID: local,
            boundPeerID: bound,
            localPeerID: local,
            directAnnounceTTL: 7,
            nowMs: 1_000_000,
            isValidSyncResponse: { _ in false }
        )
        let spoofResult = BLEIngressPacketGuard.evaluate(
            packet: spoofedRequestSync,
            claimedSenderID: claimed,
            boundPeerID: bound,
            localPeerID: local,
            directAnnounceTTL: 7,
            nowMs: 1_000_000,
            isValidSyncResponse: { _ in false }
        )

        #expect(selfResult == .failure(.selfLoopback(packetType: MessageType.message.rawValue)))
        #expect(spoofResult == .failure(.directSenderMismatch(boundPeerID: bound, claimedSenderID: claimed)))
    }

    @Test("direct announce with a mismatched binding flows through to normal validation")
    func directAnnounceMismatchStillValidatesTimestamp() throws {
        // Rotation heal path: the announce passes the binding check attributed
        // to the claimed sender, but stays subject to timestamp validation.
        let local = PeerID(str: "0011223344556677")
        let bound = PeerID(str: "1122334455667788")
        let claimed = PeerID(str: "8899aabbccddeeff")
        let freshAnnounce = makePacket(type: .announce, sender: claimed, timestamp: 1_000_000, ttl: 7)
        let staleAnnounce = makePacket(type: .announce, sender: claimed, timestamp: 0, ttl: 7)

        let freshContext = try #require(success(BLEIngressPacketGuard.evaluate(
            packet: freshAnnounce,
            claimedSenderID: claimed,
            boundPeerID: bound,
            localPeerID: local,
            directAnnounceTTL: 7,
            nowMs: 1_000_000,
            isValidSyncResponse: { _ in false }
        )))
        let staleResult = BLEIngressPacketGuard.evaluate(
            packet: staleAnnounce,
            claimedSenderID: claimed,
            boundPeerID: bound,
            localPeerID: local,
            directAnnounceTTL: 7,
            nowMs: 1_000_000,
            isValidSyncResponse: { _ in false }
        )

        #expect(freshContext.receivedFromPeerID == claimed)
        #expect(freshContext.validationPeerID == claimed)
        #expect(staleResult == .failure(.timestampSkew(
            peerID: claimed,
            skewMs: 1_000_000,
            maxSkewMs: 120_000
        )))
    }

    @Test("timestamp skew outside the window is rejected")
    func timestampSkewIsRejected() {
        let local = PeerID(str: "0011223344556677")
        let sender = PeerID(str: "1122334455667788")
        let packet = makePacket(sender: sender, timestamp: 1_000)

        let result = BLEIngressPacketGuard.evaluate(
            packet: packet,
            claimedSenderID: sender,
            boundPeerID: nil,
            localPeerID: local,
            directAnnounceTTL: 7,
            nowMs: 200_000,
            maxTimestampSkewMs: 120_000,
            isValidSyncResponse: { _ in false }
        )

        #expect(result == .failure(.timestampSkew(
            peerID: sender,
            skewMs: 199_000,
            maxSkewMs: 120_000
        )))
    }

    @Test("valid RSR packets use bound peer validation and bypass the past timestamp bound")
    func validRSRUsesBoundPeerAndBypassesTimestamp() throws {
        let local = PeerID(str: "0011223344556677")
        let bound = PeerID(str: "1122334455667788")
        let sender = PeerID(str: "8899aabbccddeeff")
        var packet = makePacket(sender: sender, timestamp: 1)
        packet.isRSR = true

        let context = try #require(success(BLEIngressPacketGuard.evaluate(
            packet: packet,
            claimedSenderID: sender,
            boundPeerID: bound,
            localPeerID: local,
            directAnnounceTTL: 7,
            nowMs: 1_000_000,
            isValidSyncResponse: { $0 == bound }
        )))

        #expect(context.receivedFromPeerID == bound)
        #expect(context.validationPeerID == bound)
    }

    @Test("valid RSR packets dated beyond the skew window are rejected")
    func futureDatedRSRIsRejected() throws {
        // Sync replies may replay old packets but never future-dated ones:
        // UInt64.max used to reach the UI (and trap) or pin the gossip store.
        let local = PeerID(str: "0011223344556677")
        let bound = PeerID(str: "1122334455667788")
        let sender = PeerID(str: "8899aabbccddeeff")
        let nowMs: UInt64 = 1_000_000
        let skewMs: UInt64 = 120_000

        func evaluateRSR(timestamp: UInt64) -> Result<BLEIngressPacketContext, BLEIngressPacketGuard.Rejection> {
            var packet = makePacket(sender: sender, timestamp: timestamp)
            packet.isRSR = true
            return BLEIngressPacketGuard.evaluate(
                packet: packet,
                claimedSenderID: sender,
                boundPeerID: bound,
                localPeerID: local,
                directAnnounceTTL: 7,
                nowMs: nowMs,
                maxTimestampSkewMs: skewMs,
                isValidSyncResponse: { $0 == bound }
            )
        }

        #expect(evaluateRSR(timestamp: .max) == .failure(.timestampSkew(
            peerID: bound,
            skewMs: .max - nowMs,
            maxSkewMs: skewMs
        )))
        #expect(evaluateRSR(timestamp: nowMs + skewMs + 1) == .failure(.timestampSkew(
            peerID: bound,
            skewMs: skewMs + 1,
            maxSkewMs: skewMs
        )))
        // The edge of the window is still tolerated clock skew.
        let edgeContext = try #require(success(evaluateRSR(timestamp: nowMs + skewMs)))
        #expect(edgeContext.validationPeerID == bound)

        // Reassembled inner packets are checked through validatePayload alone.
        var innerPacket = makePacket(sender: sender, timestamp: .max)
        innerPacket.isRSR = true
        let innerResult = BLEIngressPacketGuard.validatePayload(
            innerPacket,
            from: sender,
            nowMs: nowMs,
            maxTimestampSkewMs: skewMs,
            isValidSyncResponse: { _ in true }
        )
        guard case .failure(.timestampSkew) = innerResult else {
            Issue.record("Expected a future-dated reassembled RSR packet to be rejected, got \(innerResult)")
            return
        }
    }

    @Test("invalid RSR packets are rejected")
    func invalidRSRIsRejected() {
        let local = PeerID(str: "0011223344556677")
        let bound = PeerID(str: "1122334455667788")
        let sender = PeerID(str: "8899aabbccddeeff")
        var packet = makePacket(sender: sender, timestamp: 1)
        packet.isRSR = true

        let result = BLEIngressPacketGuard.evaluate(
            packet: packet,
            claimedSenderID: sender,
            boundPeerID: bound,
            localPeerID: local,
            directAnnounceTTL: 7,
            nowMs: 1_000_000,
            isValidSyncResponse: { _ in false }
        )

        #expect(result == .failure(.invalidRSR(peerID: bound)))
    }

    private func makePacket(
        type: MessageType = .message,
        sender: PeerID,
        timestamp: UInt64,
        ttl: UInt8 = 3
    ) -> BitchatPacket {
        BitchatPacket(
            type: type.rawValue,
            senderID: Data(hexString: sender.id) ?? Data(),
            recipientID: nil,
            timestamp: timestamp,
            payload: Data([0x01, 0x02, 0x03]),
            signature: nil,
            ttl: ttl
        )
    }

    private func success(_ result: Result<BLEIngressPacketContext, BLEIngressPacketGuard.Rejection>) -> BLEIngressPacketContext? {
        guard case .success(let context) = result else { return nil }
        return context
    }
}
