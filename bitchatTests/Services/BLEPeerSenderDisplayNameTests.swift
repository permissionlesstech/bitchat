import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("BLE peer sender display name tests")
struct BLEPeerSenderDisplayNameTests {
    @Test("local peer resolves to local nickname")
    func localPeerUsesLocalNickname() {
        let local = PeerID(str: "1122334455667788")

        #expect(BLEPeerSenderDisplayName.resolveKnownPeer(
            peerID: local,
            localPeerID: local,
            localNickname: "me",
            peers: [:],
            allowConnectedUnverified: false
        ) == "me")
    }

    @Test("verified nickname collisions add peer suffix")
    func verifiedCollisionAddsSuffix() {
        let local = PeerID(str: "1122334455667788")
        let peer = PeerID(str: "8877665544332211")
        let peers = [
            peer: makeInfo(peerID: peer, nickname: "sam", isConnected: false, isVerifiedNickname: true)
        ]

        #expect(BLEPeerSenderDisplayName.resolveKnownPeer(
            peerID: peer,
            localPeerID: local,
            localNickname: "sam",
            peers: peers,
            allowConnectedUnverified: false
        ) == "sam#8877")
    }

    @Test("connected unverified fallback is opt in")
    func connectedUnverifiedFallbackIsOptIn() {
        let local = PeerID(str: "1122334455667788")
        let peer = PeerID(str: "8877665544332211")
        let peers = [
            peer: makeInfo(peerID: peer, nickname: "", isConnected: true, isVerifiedNickname: false)
        ]

        #expect(BLEPeerSenderDisplayName.resolveKnownPeer(
            peerID: peer,
            localPeerID: local,
            localNickname: "me",
            peers: peers,
            allowConnectedUnverified: false
        ) == nil)
        #expect(BLEPeerSenderDisplayName.resolveKnownPeer(
            peerID: peer,
            localPeerID: local,
            localNickname: "me",
            peers: peers,
            allowConnectedUnverified: true
        ) == "anon8877")
    }

    private func makeInfo(
        peerID: PeerID,
        nickname: String,
        isConnected: Bool,
        isVerifiedNickname: Bool
    ) -> BLEPeerInfo {
        BLEPeerInfo(
            peerID: peerID,
            nickname: nickname,
            isConnected: isConnected,
            noisePublicKey: nil,
            signingPublicKey: nil,
            isVerifiedNickname: isVerifiedNickname,
            lastSeen: Date(timeIntervalSince1970: 0)
        )
    }
}
