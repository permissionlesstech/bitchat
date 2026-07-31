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

    /// Issue #1538: with two live links to the same phone, a panic
    /// rotation used to heal only the link the verified announce arrived
    /// on. The second link kept its binding to
    /// the retired identity, which therefore stayed in the peer list as a
    /// ghost — and, worse, kept being refreshed by the *new* identity's
    /// traffic (a bound link attributes non-announce frames to its bound
    /// peer, so the dead ID looked alive for as long as the link lived).
    @Test
    func duplicateLinkPanicRotationLeavesNoGhostAndHealsBothLinks() {
        let mesh = SimulatedMesh()
        let a = mesh.addNode(nickname: "alice")
        let b = mesh.addNode(nickname: "bob")
        mesh.connectDuplicateLinks(0, 1)
        mesh.announceAll()

        let centralLink = BLEIngressLinkID.central(mesh.linkUUID(from: 1, at: 0))
        let duplicateLink = BLEIngressLinkID.central(mesh.duplicateLinkUUID(from: 1, at: 0))
        let oldBobID = b.service.myPeerID
        // Both links bind to bob: raw direct announces bind unbound links,
        // and that happens before duplicate suppression.
        #expect(a.service._test_linkBinding(centralLink) == oldBobID)
        #expect(a.service._test_linkBinding(duplicateLink) == oldBobID)

        b.service.suspendForPanicReset()
        b.service.resetIdentityForPanic(currentNickname: "anon", restartServices: false)
        b.service.completePanicReset(restartServices: false)
        mesh.pump()
        let newBobID = b.service.myPeerID
        #expect(newBobID != oldBobID)

        // One verified direct announce must retire the old identity
        // outright — no ghost survives on the link it did not arrive on.
        mesh.forceAnnounce(from: 1)
        mesh.settleUntil { !a.service._test_knownPeerIDs().contains(oldBobID) }
        #expect(!a.service._test_knownPeerIDs().contains(oldBobID))
        #expect(a.service._test_linkBinding(centralLink) != oldBobID)
        #expect(a.service._test_linkBinding(duplicateLink) != oldBobID)

        // Both links converge onto the new identity as its announces land
        // (the released link binds through the ordinary unbound-link path,
        // so no containment rule has to be relaxed).
        for _ in 0..<4 {
            b.service._test_resetAnnounceThrottle()
            mesh.forceAnnounce(from: 1)
            mesh.advanceTime(by: 1)
        }
        #expect(a.service._test_linkBinding(centralLink) == newBobID)
        #expect(a.service._test_linkBinding(duplicateLink) == newBobID)
        #expect(a.service.getConnectedPeers() == [newBobID])
    }

    /// The #1401 containment rule, pinned against the attack the #1538 fix
    /// had to avoid re-opening: a captured verified direct announce replayed
    /// onto a link the attacker controls must NOT bind that link to the
    /// victim while the victim holds a live link of its own — and must not
    /// evict the victim either (the rotation release only runs after a
    /// rebind the containment actually permitted).
    @Test
    func replayedVerifiedAnnounceCannotStealALinkOrEvictTheVictim() {
        let mesh = SimulatedMesh()
        let alice = mesh.addNode(nickname: "alice")
        let bob = mesh.addNode(nickname: "bob")
        let mallory = mesh.addNode(nickname: "mallory")
        mesh.connect(0, 1)
        mesh.connect(0, 2)
        mesh.announceAll()

        let bobLink = BLEIngressLinkID.central(mesh.linkUUID(from: 1, at: 0))
        let malloryLink = BLEIngressLinkID.central(mesh.linkUUID(from: 2, at: 0))
        #expect(alice.service._test_linkBinding(bobLink) == bob.service.myPeerID)
        #expect(alice.service._test_linkBinding(malloryLink) == mallory.service.myPeerID)

        // Mallory captures a signed direct announce alice has NOT seen, so
        // duplicate suppression cannot mask the containment check: bob
        // announces while out of alice's range, and mallory replays it on
        // her own link. Directness is forgeable; the signature is real.
        mesh.silence(0, 1)
        bob.service._test_resetAnnounceThrottle()
        mesh.forceAnnounce(from: 1)
        let replay = mesh.emittedPackets(from: 1).last {
            $0.type == MessageType.announce.rawValue && $0.ttl == TransportConfig.messageTTLDefault
        }
        guard let replay else {
            Issue.record("bob emitted no direct announce to capture")
            return
        }
        alice.service._test_ingestFrame(replay, link: malloryLink)
        mesh.pump()
        mesh.advanceTime(by: 1)

        // The link is not stolen, and bob keeps both his binding and his
        // place in the peer list.
        #expect(alice.service._test_linkBinding(malloryLink) == mallory.service.myPeerID)
        #expect(alice.service._test_linkBinding(bobLink) == bob.service.myPeerID)
        #expect(alice.service._test_knownPeerIDs().contains(bob.service.myPeerID))
        #expect(alice.service.getConnectedPeers().contains(bob.service.myPeerID))

        // Positive control — proves the refusal above was the containment
        // rule and not duplicate suppression: once bob holds no live link,
        // the very same replayed announce on the very same link does take
        // effect. (Long-standing accepted residual: a stolen link carries
        // only Noise ciphertext, and the rebind retires the link's proof.)
        alice.service.emitLinkEvent(.centralLinkEnded(centralUUID: mesh.linkUUID(from: 1, at: 0)))
        alice.service._test_fenceEngine()
        bob.service._test_resetAnnounceThrottle()
        mesh.forceAnnounce(from: 1)
        let secondReplay = mesh.emittedPackets(from: 1).last {
            $0.type == MessageType.announce.rawValue && $0.ttl == TransportConfig.messageTTLDefault
        }
        #expect(secondReplay?.timestamp != replay.timestamp)
        if let secondReplay {
            alice.service._test_ingestFrame(secondReplay, link: malloryLink)
            mesh.pump()
            mesh.advanceTime(by: 1)
        }
        #expect(alice.service._test_linkBinding(malloryLink) == bob.service.myPeerID)
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
