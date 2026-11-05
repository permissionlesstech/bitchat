import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// Repro for an older sync reply rolling back a peer's newer announcement.
@Suite(.serialized)
struct AnnounceOrderReproTests {
    private static func nickname(of peer: PeerID, at node: SimulatedMesh.Node) -> String? {
        node.service.currentPeerSnapshots().first { $0.peerID == peer }?.nickname
    }

    private static func lastAnnounce(from index: Int, in mesh: SimulatedMesh, nickname: String) -> BitchatPacket? {
        mesh.emittedPackets(from: index).last {
            $0.type == MessageType.announce.rawValue
                && AnnouncementPacket.decode(from: $0.payload)?.nickname == nickname
        }
    }

    @Test func olderAnnounceDoesNotOverwriteNewerOne() throws {
        let mesh = SimulatedMesh()
        let bob = mesh.addNode(nickname: "bob")
        let xavier = mesh.addNode(nickname: "xavier")
        // No links yet: bob's announces are captured, not delivered.
        bob.service._test_resetAnnounceThrottle()
        mesh.forceAnnounce(from: 0)
        Thread.sleep(forTimeInterval: 0.01) // distinct millisecond timestamps
        bob.service._test_resetAnnounceThrottle()
        bob.service.setNickname("bobby")
        mesh.pump()
        let older = try #require(Self.lastAnnounce(from: 0, in: mesh, nickname: "bob"))
        let newer = try #require(Self.lastAnnounce(from: 0, in: mesh, nickname: "bobby"))
        #expect(older.timestamp < newer.timestamp)

        let link = BLEIngressLinkID.central(mesh.linkUUID(from: 0, at: 1))
        xavier.service._test_ingestFrame(newer, link: link)
        xavier.service._test_fenceEngine()
        xavier.service._test_ingestFrame(older, link: link)
        xavier.service._test_fenceEngine()

        #expect(Self.nickname(of: bob.service.myPeerID, at: xavier) == "bobby")
    }
}
