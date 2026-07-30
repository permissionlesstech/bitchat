import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// Deterministic multi-node mesh tests over the real engine (no
/// CoreBluetooth, no wall-clock waits): announces bind simulated links,
/// signatures verify, Noise sessions establish, and rotation rebinds run
/// the same engine slots a radio would drive. See SimulatedMesh for the
/// fidelity boundary.
@Suite(.serialized)
struct SimulatedMeshTests {
    @Test
    func announceExchangeBindsLinksAndConnectsPeers() {
        let mesh = SimulatedMesh()
        let a = mesh.addNode(nickname: "alice")
        let b = mesh.addNode(nickname: "bob")
        mesh.connect(0, 1)

        mesh.announceAll()

        // Raw direct announces bind each directed edge to the sender.
        #expect(b.service._test_centralBinding(mesh.linkUUID(from: 0, at: 1)) == a.service.myPeerID)
        #expect(a.service._test_centralBinding(mesh.linkUUID(from: 1, at: 0)) == b.service.myPeerID)
        // Verified announces register connected peers on both sides.
        #expect(a.service.getConnectedPeers().contains(b.service.myPeerID))
        #expect(b.service.getConnectedPeers().contains(a.service.myPeerID))
    }

    @Test
    func noiseSessionEstablishesEndToEnd() {
        let mesh = SimulatedMesh()
        let a = mesh.addNode(nickname: "alice")
        let b = mesh.addNode(nickname: "bob")
        mesh.connect(0, 1)

        mesh.announceAll()
        // Handshake initiation and any deferred retries ride engine
        // timers; settle until both directions hold (normally 1 round).
        mesh.settleUntil {
            a.service.canDeliverSecurely(to: b.service.myPeerID)
                && b.service.canDeliverSecurely(to: a.service.myPeerID)
        }

        #expect(a.service.canDeliverSecurely(to: b.service.myPeerID))
        #expect(b.service.canDeliverSecurely(to: a.service.myPeerID))
    }

    @Test
    func publicMessageRelaysAcrossLineTopologyWithinTTLBudget() async {
        let mesh = SimulatedMesh()
        let a = mesh.addNode(nickname: "alice")
        _ = mesh.addNode(nickname: "bob")
        let c = mesh.addNode(nickname: "carol")
        mesh.connect(0, 1)
        mesh.connect(1, 2)

        mesh.announceAll()
        mesh.advanceTime(by: 2)
        let baseline = mesh.deliveredFrameCount

        let capture = TransportEventCapture()
        c.service.eventDelegate = capture
        a.service.sendMessage("hello line", mentions: [])
        mesh.pump()
        // Relay jitter defers B's forward; release it (twice: the relay's
        // own broadcast may schedule follow-on work).
        mesh.advanceTime(by: 2)
        mesh.advanceTime(by: 2)

        let arrived = await capture.drainedPublicMessageCount(content: "hello line") == 1
        #expect(arrived)
        // Storm bound: a single public message across one relay hop must
        // not multiply into more than a handful of frames.
        #expect(mesh.deliveredFrameCount - baseline <= 12)
    }

    @Test
    func duplicateFloodIsDeliveredOnce() async {
        let mesh = SimulatedMesh()
        let a = mesh.addNode(nickname: "alice")
        let b = mesh.addNode(nickname: "bob")
        mesh.connect(0, 1)
        mesh.announceAll()

        let capture = TransportEventCapture()
        b.service.eventDelegate = capture

        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data(hexString: a.service.myPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data("flooded".utf8),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )
        let signed = a.service.signPacketForBroadcast(packet)
        let link = BLEIngressLinkID.central(mesh.linkUUID(from: 0, at: 1))
        for _ in 0..<8 {
            b.service._test_ingestFrame(signed, link: link)
        }
        mesh.pump()
        mesh.advanceTime(by: 2)

        let deliveredOnce = await capture.drainedPublicMessageCount(content: "flooded") == 1
        #expect(deliveredOnce)
    }

    @Test
    func linkDropEventRetiresBindingAndReconnectHeals() {
        let mesh = SimulatedMesh()
        let a = mesh.addNode(nickname: "alice")
        let b = mesh.addNode(nickname: "bob")
        mesh.connect(0, 1)
        mesh.announceAll()

        let bobLinkOnAlice = mesh.linkUUID(from: 1, at: 0)
        #expect(a.service._test_centralBinding(bobLinkOnAlice) == b.service.myPeerID)
        #expect(a.service.getConnectedPeers().contains(b.service.myPeerID))

        // The link layer reports the drop through the same port
        // CoreBluetooth's didUnsubscribe uses: identity retirement and
        // last-link peer bookkeeping are engine work.
        a.service.emitLinkEvent(.centralLinkEnded(centralUUID: bobLinkOnAlice))
        a.service._test_fenceEngine()

        #expect(a.service._test_centralBinding(bobLinkOnAlice) == nil)
        #expect(!a.service.getConnectedPeers().contains(b.service.myPeerID))

        // A fresh announce over the (re-established) link binds and
        // reconnects — the same heal path a real reconnection drives.
        // (The announce throttle runs on wall clock; model elapsed time.)
        b.service._test_resetAnnounceThrottle()
        mesh.forceAnnounce(from: 1)
        mesh.settleUntil {
            a.service.getConnectedPeers().contains(b.service.myPeerID)
        }
        #expect(a.service._test_centralBinding(bobLinkOnAlice) == b.service.myPeerID)
        #expect(a.service.getConnectedPeers().contains(b.service.myPeerID))
    }

    @Test
    func panicRotationRebindsSurvivorExactlyOnceAndStays() {
        let mesh = SimulatedMesh()
        let a = mesh.addNode(nickname: "alice")
        let b = mesh.addNode(nickname: "bob")
        mesh.connect(0, 1)
        mesh.announceAll()
        mesh.advanceTime(by: 2)

        let oldBobID = b.service.myPeerID
        let bobLinkOnAlice = mesh.linkUUID(from: 1, at: 0)
        #expect(a.service._test_centralBinding(bobLinkOnAlice) == oldBobID)

        // Bob panics: the production sequence — suspend, rotate the whole
        // identity, commit — over the same simulated link.
        b.service.suspendForPanicReset()
        b.service.resetIdentityForPanic(currentNickname: "anon", restartServices: false)
        b.service.completePanicReset(restartServices: false)
        mesh.pump()
        let newBobID = b.service.myPeerID
        #expect(newBobID != oldBobID)

        // His first verified direct announce heals the stale binding in
        // one engine slot on the survivor.
        mesh.forceAnnounce(from: 1)
        mesh.advanceTime(by: 2)
        #expect(a.service._test_centralBinding(bobLinkOnAlice) == newBobID)

        // Containment: further announces (and the rebind cooldown) leave
        // the healed binding alone — no flip-flop back to the dead ID.
        // (Reset the wall-clock announce throttles so these actually send.)
        b.service._test_resetAnnounceThrottle()
        mesh.forceAnnounce(from: 1)
        a.service._test_resetAnnounceThrottle()
        mesh.forceAnnounce(from: 0)
        mesh.advanceTime(by: 2)
        #expect(a.service._test_centralBinding(bobLinkOnAlice) == newBobID)
        #expect(a.service.getConnectedPeers().contains(newBobID))
    }
}

/// Captures `.publicMessageReceived` transport events. Delivery crosses the main
/// actor (`notifyUI`), so counting first drains that hop — a bounded number
/// of main-actor round-trips, never a wall-clock wait (the mesh is already
/// quiescent when this is called; only the queued MainActor task remains).
private final class TransportEventCapture: TransportEventDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var publicMessages: [String] = []

    func didReceiveTransportEvent(_ event: TransportEvent) {
        guard case let .publicMessageReceived(_, _, content, _, _) = event else { return }
        lock.lock()
        publicMessages.append(content)
        lock.unlock()
    }

    private func count(content: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return publicMessages.filter { $0 == content }.count
    }

    func drainedPublicMessageCount(content: String, drains: Int = 50) async -> Int {
        for _ in 0..<drains {
            if count(content: content) > 0 { break }
            await MainActor.run {}
        }
        return count(content: content)
    }
}
