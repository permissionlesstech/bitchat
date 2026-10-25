import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// Announce budgets over the real engine. Every announce floods the whole
/// mesh, so these pin how many announces a node may originate per event —
/// counts that used to grow with the size of the mesh. Each test prints a
/// `BUDGET[...]` line with what it measured.
///
/// Topologies keep every node within five hops of every flood's origin:
/// dense nodes clamp a relayed TTL, and five hops is the reach that clamp
/// still guarantees, so discovery assertions hold on every run.
@Suite(.serialized)
struct SimulatedMeshAnnounceBudgetTests {
    /// Interior anchors of the 6×6 king grid: every node is within three
    /// king moves of one of them.
    private static let anchors = [14, 15]

    /// A phone joining a dense 36-node mesh. Every node used to answer the
    /// newcomer's announces, and each answer was itself a mesh-wide flood.
    /// Now only the link's endpoints announce: the joiner's link-up, one
    /// announce from each neighbour listing the joiner, and one more from
    /// the joiner listing its neighbours (its link-up predates them).
    @Test
    func joinCostsTwoAnnouncesPlusOnePerNeighbor() {
        let mesh = SimulatedMesh.grid(width: 6, height: 6, kingMoves: true)
        let joiner = mesh.launch(nickname: "joiner")
        let before = originations(mesh)
        let framesBefore = mesh.floodFrameCount(ofType: .announce)

        mesh.join(joiner, linkingTo: Self.anchors)

        let spent = delta(originations(mesh), before)
        report("join 6x6 king", spent, frames: mesh.floodFrameCount(ofType: .announce) - framesBefore)
        #expect(spent[joiner] == 2)
        for anchor in Self.anchors {
            #expect(spent[anchor] == 1)
        }
        #expect(othersSpentNothing(spent, except: Set(Self.anchors + [joiner])))
        // Every node learned the joiner from its announces.
        for node in 0..<joiner {
            #expect(mesh.knows(node, joiner))
        }
        // The joiner learned the rest through initial sync with its two
        // neighbours. A sync request's GCS filter hides each announce it
        // lacks with probability ~1/128, so a node is rarely missed by both
        // replies; the joiner learns it from that node's next periodic
        // announce.
        let missed = (0..<joiner).filter { !mesh.knows(joiner, $0) }
        #expect(missed.count < 3)
        for node in missed {
            mesh.nodes[node].service._test_forceAnnounce()
        }
        mesh.settle()
        for node in 0..<joiner {
            #expect(mesh.knows(joiner, node))
        }
    }

    /// The joiner's new edges are claimed from both ends straight away, so
    /// a node across the mesh can source-route to it without waiting for a
    /// periodic announce.
    @Test
    func joinerIsSourceRoutableAsSoonAsItJoins() {
        let mesh = SimulatedMesh.grid(width: 6, height: 6, kingMoves: true)
        let joiner = mesh.launch(nickname: "joiner")
        mesh.join(joiner, linkingTo: Self.anchors)

        let joinerID = mesh.nodes[joiner].service.myPeerID
        #expect(mesh.nodes[35].service._test_confirmedRouteHops(to: joinerID) != nil)
    }

    /// A new link between two nodes that already knew each other through
    /// relays: one announce per side, plus the central's second announce
    /// listing the peripheral it had not seen when its link-up went out.
    @Test
    func linkBetweenKnownPeersCostsThreeAnnounces() {
        let mesh = SimulatedMesh.grid(width: 6, height: 6, kingMoves: true)
        // Two king moves apart: known to each other through relays only.
        let (central, peripheral) = (7, 21)
        #expect(mesh.knows(central, peripheral) && mesh.knows(peripheral, central))
        // Node 35 is four king moves from the central, the peripheral is on
        // the way, and the link saves one hop: the route can only shorten if
        // both ends claim the new edge.
        let centralID = mesh.nodes[central].service.myPeerID
        #expect(mesh.nodes[35].service._test_confirmedRouteHops(to: centralID) == 3)
        let before = originations(mesh)
        let framesBefore = mesh.floodFrameCount(ofType: .announce)

        mesh.join(central, linkingTo: [peripheral])

        let spent = delta(originations(mesh), before)
        report("link 6x6 king", spent, frames: mesh.floodFrameCount(ofType: .announce) - framesBefore)
        #expect(spent[central] == 2)
        #expect(spent[peripheral] == 1)
        #expect(othersSpentNothing(spent, except: [central, peripheral]))
        #expect(mesh.nodes[peripheral].service.getConnectedPeers().contains(centralID))
        #expect(mesh.nodes[35].service._test_confirmedRouteHops(to: centralID) == 2)
    }

    /// The peripheral's own link-up announce is skipped: the announce it
    /// owed the central (listing it) already went out on every live link,
    /// this one included, before its link-up fired.
    @Test
    func peripheralLinkUpIsSkippedOnceAnAnnounceReachedTheLink() {
        let mesh = SimulatedMesh(announceAccounting: true)
        let central = mesh.launch(nickname: "central")
        let peripheral = mesh.launch(nickname: "peripheral")
        let before = originations(mesh)

        mesh.linkUp(central: central, peripheral: peripheral)
        mesh.settle()

        let spent = delta(originations(mesh), before)
        #expect(spent[peripheral] == 1)
        #expect(spent[central] == 2)
        #expect(mesh.nodes[central].service._test_centralBinding(mesh.linkUUID(from: peripheral, at: central))
            == mesh.nodes[peripheral].service.myPeerID)
        #expect(mesh.nodes[peripheral].service._test_centralBinding(mesh.linkUUID(from: central, at: peripheral))
            == mesh.nodes[central].service.myPeerID)
    }

    /// A link-up announce the forced throttle refuses is not lost: the
    /// announce that tripped the throttle went out before the link existed,
    /// so the link-up is retried once the window has passed.
    @Test
    func throttledLinkUpAnnounceIsRetriedAfterTheForcedWindow() {
        let mesh = SimulatedMesh(announceAccounting: true)
        let central = mesh.launch(nickname: "central")
        let peripheral = mesh.launch(nickname: "peripheral")
        // An announce a moment before the link exists reaches nobody.
        mesh.nodes[central].service._test_forceAnnounce()
        mesh.pump()
        let before = mesh.announceOriginations(from: central)

        // Production order: the link is registered, then its link-up is
        // scheduled; nothing is broadcast in between.
        mesh.connect(central, peripheral)
        mesh.nodes[central].service.scheduleLinkUpAnnounce(
            after: TransportConfig.blePostSubscribeAnnounceDelaySeconds
        )
        mesh.advanceTime(by: 0.3, inStepsOf: 0.05)

        #expect(mesh.announceOriginations(from: central) - before == 1)
        #expect(mesh.nodes[peripheral].service._test_centralBinding(mesh.linkUUID(from: central, at: peripheral))
            == mesh.nodes[central].service.myPeerID)
    }

    /// A central that resubscribes right after its link dropped is
    /// rate-limited (BCH-01-004), so it gets no link-up announce at once,
    /// but it still gets one when the backoff ends. Until one of our
    /// announces reaches its new link, the central cannot bind the link and
    /// shows us as gone. (Answering its announce, and the announce that used
    /// to end a handshake, covered this.)
    @Test
    func rateLimitedResubscriptionGetsItsAnnounceWhenTheBackoffEnds() {
        let mesh = SimulatedMesh(announceAccounting: true)
        let central = mesh.launch(nickname: "central")
        let peripheral = mesh.launch(nickname: "peripheral")
        let peripheralID = mesh.nodes[peripheral].service.myPeerID
        let subscription = mesh.linkUUID(from: central, at: peripheral)
        let linkAtCentral = mesh.linkUUID(from: peripheral, at: central)
        let firstSubscription = Date(timeIntervalSinceReferenceDate: 0)
        mesh.connect(central, peripheral)
        mesh.nodes[central].service.scheduleLinkUpAnnounce(after: TransportConfig.blePostSubscribeAnnounceDelaySeconds)
        mesh.nodes[peripheral].service.scheduleSubscriptionLinkUpAnnounce(forCentral: subscription, now: firstSubscription)
        mesh.settle()
        #expect(mesh.nodes[central].service._test_centralBinding(linkAtCentral) == peripheralID)

        // The link drops on both sides and comes straight back, inside the
        // peripheral's 2 s backoff for that central.
        mesh.nodes[central].service.emitLinkEvent(.centralLinkEnded(centralUUID: linkAtCentral))
        mesh.nodes[peripheral].service.emitLinkEvent(.centralLinkEnded(centralUUID: subscription))
        mesh.pump()
        let before = mesh.announceOriginations(from: peripheral)
        mesh.nodes[central].service.scheduleLinkUpAnnounce(after: TransportConfig.blePostSubscribeAnnounceDelaySeconds)
        mesh.nodes[peripheral].service.scheduleSubscriptionLinkUpAnnounce(
            forCentral: subscription,
            now: firstSubscription.addingTimeInterval(1.5)
        )
        mesh.advanceTime(by: 1, inStepsOf: 0.05)
        #expect(mesh.announceOriginations(from: peripheral) == before)
        #expect(!mesh.nodes[central].service.getConnectedPeers().contains(peripheralID))

        mesh.advanceTime(by: TransportConfig.bleSubscriptionRateLimitMinSeconds, inStepsOf: 0.05)
        mesh.settle()

        #expect(mesh.announceOriginations(from: peripheral) - before == 1)
        #expect(mesh.nodes[central].service._test_centralBinding(linkAtCentral) == peripheralID)
        #expect(mesh.nodes[central].service.getConnectedPeers().contains(peripheralID))
    }

    /// Phones usually hold two links to each other, one per role, formed at
    /// different times. The second link costs one link-up announce per side
    /// (each must reach and bind it) and nothing else: both sides already
    /// claim each other.
    @Test
    func secondLinkOfADualRolePairCostsOneAnnouncePerSide() {
        let mesh = SimulatedMesh(announceAccounting: true)
        let a = mesh.launch(nickname: "a")
        let b = mesh.launch(nickname: "b")
        mesh.linkUp(central: a, peripheral: b)
        mesh.settle()
        let before = originations(mesh)

        // B connects to A's peripheral role a moment later.
        mesh.connectDuplicateLinks(a, b)
        mesh.nodes[b].service.scheduleLinkUpAnnounce(after: TransportConfig.blePostSubscribeAnnounceDelaySeconds)
        mesh.nodes[a].service.scheduleLinkUpAnnounce(after: TransportConfig.blePostAnnounceDelaySeconds)
        mesh.settle()

        let spent = delta(originations(mesh), before)
        #expect(spent[a] == 1)
        #expect(spent[b] == 1)
        #expect(mesh.nodes[a].service._test_linkBinding(.central(mesh.duplicateLinkUUID(from: b, at: a)))
            == mesh.nodes[b].service.myPeerID)
        #expect(mesh.nodes[b].service._test_linkBinding(.central(mesh.duplicateLinkUUID(from: a, at: b)))
            == mesh.nodes[a].service.myPeerID)
    }

    /// One periodic announce round in a busy mesh costs one announce per
    /// node. Ordinary traffic churns the packet deduplicator, which is where
    /// the old per-peer "already answered" markers lived, so nodes answered
    /// each other's relayed periodic announces again: up to N² floods per
    /// round instead of N.
    @Test
    func periodicRoundInABusyMeshCostsOneAnnouncePerNode() {
        let mesh = SimulatedMesh.grid(width: 4, height: 4, kingMoves: false)
        for node in mesh.nodes {
            node.service._test_churnDeduplicator(count: 1_200)
        }
        let before = originations(mesh)
        let framesBefore = mesh.floodFrameCount(ofType: .announce)

        // Maintenance timers are not aligned: stagger the round.
        for node in mesh.nodes {
            node.service._test_forceAnnounce()
            mesh.advanceTime(by: 0.5, inStepsOf: 0.05)
        }
        mesh.settle()

        let spent = delta(originations(mesh), before)
        report("periodic round 4x4 busy", spent, frames: mesh.floodFrameCount(ofType: .announce) - framesBefore)
        #expect(spent.allSatisfy { $0 == 1 })
    }

    /// A hub with more neighbours than an announce can list (the encoder
    /// keeps 10) owes nothing for the ones left out: the record of what it
    /// claimed holds every connected neighbour, so their periodic announces
    /// never make it re-announce.
    @Test
    func highDegreeNodeOwesNothingForNeighborsTheListCapLeftOut() {
        let mesh = SimulatedMesh(announceAccounting: true)
        let hub = 0
        mesh.addNode(nickname: "hub")
        for spoke in 1...12 {
            mesh.addNode(nickname: "spoke\(spoke)")
            mesh.connect(hub, spoke)
        }
        mesh.announceAll()
        mesh.settle()
        let before = mesh.announceOriginations(from: hub)

        for spoke in 1...12 {
            mesh.nodes[spoke].service._test_forceAnnounce()
            mesh.advanceTime(by: 0.5, inStepsOf: 0.05)
        }
        mesh.settle()

        #expect(mesh.announceOriginations(from: hub) - before == 0)
    }

    /// Relayed announces are never answered, however much ordinary traffic
    /// passes. The old "already answered" marker lived in the packet
    /// deduplicator's FIFO, so churn evicted it and re-armed the answer.
    @Test
    func relayedAnnouncesAreNeverAnsweredEvenAfterDeduplicatorChurn() {
        let mesh = SimulatedMesh(announceAccounting: true)
        for name in ["alice", "bob", "carol"] {
            mesh.addNode(nickname: name)
        }
        mesh.connect(0, 1)
        mesh.connect(1, 2)
        mesh.announceAll()
        mesh.settle()
        let before = mesh.announceOriginations(from: 0)

        for _ in 0..<3 {
            mesh.nodes[0].service._test_churnDeduplicator(count: 1_200)
            mesh.nodes[2].service._test_forceAnnounce()
            mesh.settle()
        }

        let spent = mesh.announceOriginations(from: 0) - before
        print("BUDGET[relayed announces after churn]: originations=\(spent)")
        #expect(spent == 0)
    }

    /// A fresh identity costs microseconds to mint, so a verified announce
    /// alone proves nothing. Twenty fresh identities announced directly on
    /// one link get at most one announce in return — the one the link's
    /// rebind permits (rebinds are limited per link) — not one each.
    @Test
    func freshIdentitiesOnOneLinkGetAtMostOneAnnounce() throws {
        let mesh = SimulatedMesh(announceAccounting: true)
        mesh.addNode(nickname: "alice")
        mesh.addNode(nickname: "mallory")
        mesh.connect(0, 1)
        mesh.announceAll()
        mesh.settle()
        let before = mesh.announceOriginations(from: 0)
        let malloryLink = BLEIngressLinkID.central(mesh.linkUUID(from: 1, at: 0))

        for index in 0..<20 {
            let identity = NoiseEncryptionService(keychain: MockKeychain())
            let packet = try #require(makeDirectAnnounce(
                nickname: "sybil\(index)",
                noisePublicKey: identity.getStaticPublicKeyData(),
                signingPublicKey: identity.getSigningPublicKeyData()
            ).flatMap { identity.signPacket($0) })
            mesh.nodes[0].service._test_ingestFrame(packet, link: malloryLink)
            // Past the forced throttle window, so nothing coalesces.
            mesh.advanceTime(by: 0.2)
        }
        mesh.settle()

        let spent = mesh.announceOriginations(from: 0) - before
        print("BUDGET[20 fresh signed identities on one link]: originations=\(spent)")
        #expect(spent <= 1)
    }

    /// Unsigned announces never make a peer connected, so they never earn
    /// an announce (they used to be answered one for one).
    @Test
    func unsignedAnnouncesNeverEarnAnAnnounce() throws {
        let mesh = SimulatedMesh(announceAccounting: true)
        mesh.addNode(nickname: "alice")
        mesh.addNode(nickname: "mallory")
        mesh.connect(0, 1)
        mesh.announceAll()
        mesh.settle()
        let before = mesh.announceOriginations(from: 0)
        let malloryLink = BLEIngressLinkID.central(mesh.linkUUID(from: 1, at: 0))

        for index in 0..<100 {
            // Any 32 bytes satisfy the sender binding of an unsigned announce.
            let noiseKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let packet = try #require(makeDirectAnnounce(
                nickname: "junk\(index)",
                noisePublicKey: noiseKey,
                signingPublicKey: Data(repeating: 0x5A, count: 32)
            ))
            mesh.nodes[0].service._test_ingestFrame(packet, link: malloryLink)
            mesh.advanceTime(by: 0.2)
        }
        mesh.settle()

        let spent = mesh.announceOriginations(from: 0) - before
        print("BUDGET[100 unsigned identities on one link]: originations=\(spent)")
        #expect(spent == 0)
    }

    /// A panic rotation on a live link: the survivor's link is still bound
    /// to the old ID, so the rotated announce is stored disconnected until
    /// the containment-checked rebind promotes it — and that promotion is
    /// what earns the rotated phone exactly one announce from the survivor.
    @Test
    func rotatedPeerGetsOneAnnounceAfterTheRebind() {
        let mesh = SimulatedMesh(announceAccounting: true)
        let alice = mesh.addNode(nickname: "alice")
        let bob = mesh.addNode(nickname: "bob")
        mesh.connect(0, 1)
        mesh.announceAll()
        mesh.settle()

        bob.service.suspendForPanicReset()
        bob.service.resetIdentityForPanic(currentNickname: "anon", restartServices: false)
        bob.service.completePanicReset(restartServices: false)
        mesh.pump()
        let before = mesh.announceOriginations(from: 0)

        mesh.forceAnnounce(from: 1)
        mesh.settle()

        let spent = mesh.announceOriginations(from: 0) - before
        print("BUDGET[rotation answer]: originations=\(spent)")
        #expect(spent == 1)
        #expect(alice.service._test_centralBinding(mesh.linkUUID(from: 1, at: 0)) == bob.service.myPeerID)
        // The rotated phone learned the survivor from that one announce.
        #expect(bob.service.getConnectedPeers().contains(alice.service.myPeerID))
    }

    /// Two settled 3-node lines meet over one new link. Each line learns the
    /// link's far endpoint from its announces at once and the endpoints
    /// learn the far side through initial sync; the rest of each line learns
    /// the far side from the far side's next periodic announce. (Every node
    /// used to answer every relayed announce, which spread full knowledge
    /// within a second at the cost of a mesh-wide storm.)
    @Test
    func meetingGroupsLearnTheFarSideWithinOnePeriodicAnnounceRound() {
        let mesh = SimulatedMesh(announceAccounting: true)
        for name in ["a0", "a1", "a2", "b0", "b1", "b2"] {
            mesh.addNode(nickname: name)
        }
        mesh.connect(0, 1)
        mesh.connect(1, 2)
        mesh.connect(3, 4)
        mesh.connect(4, 5)
        mesh.announceAll()
        mesh.settle()

        mesh.join(2, linkingTo: [3])

        // Each line learned the far endpoint of the link from its announces.
        // (The endpoints learn the far side through initial sync, which a
        // GCS false positive can delay to the next periodic announce.)
        for node in [0, 1] { #expect(mesh.knows(node, 3)) }
        for node in [4, 5] { #expect(mesh.knows(node, 2)) }
        print("BUDGET[groups meet]: known pairs before periodic round=\(knownPairs(mesh))/30")

        // One periodic announce from every node — what the maintenance
        // timer sends within one announce interval — completes discovery.
        let everyone = 0..<6
        for node in everyone {
            mesh.nodes[node].service._test_forceAnnounce()
        }
        mesh.settle()
        print("BUDGET[groups meet]: known pairs after periodic round=\(knownPairs(mesh))/30")
        for a in everyone {
            for b in everyone where a != b {
                #expect(mesh.knows(a, b))
            }
        }
    }

    /// A courier hands mail over the moment it authenticates the recipient
    /// on a direct link, and sprays copies of mail it carries for others to
    /// it as a fellow courier. It used to wait for the recipient's next
    /// announce on that link, which the post-handshake announce happened to
    /// supply; here every announce the recipient sends predates the
    /// handshake.
    @Test
    func courierMailIsHandedOverWhenCarrierAuthenticatesRecipient() async throws {
        let mesh = SimulatedMesh(announceAccounting: true)
        let alice = mesh.addNode(nickname: "alice")
        let carol = mesh.addNode(nickname: "carol")
        alice.service.courierStore = CourierStore(persistsToDisk: false)
        carol.service.courierStore = CourierStore(persistsToDisk: false)
        carol.service.courierDepositPolicy = { _, _ in .favorite }
        mesh.connect(0, 1)
        mesh.announceAll()
        mesh.settle()
        let bobIndex = mesh.launch(nickname: "bob")
        let bob = mesh.nodes[bobIndex].service
        bob.courierStore = CourierStore(persistsToDisk: false)

        #expect(alice.service.sendCourierMessage(
            "the camp moved north",
            messageID: "courier-handover-on-auth",
            recipientNoiseKey: bob.noiseStaticPublicKeyData(),
            via: [carol.service.myPeerID]
        ))
        mesh.settle()
        // The deposit is accepted on the main actor.
        let carried = await mainActorDrained { !carol.service.courierStore.isEmpty }
        #expect(carried)
        // Carol also carries Alice's mail for Dave, who is nowhere near.
        let daveKey = NoiseEncryptionService(keychain: MockKeychain()).getStaticPublicKeyData()
        let forDave = CourierEnvelope(
            recipientTag: CourierEnvelope.recipientTag(
                noiseStaticKey: daveKey,
                epochDay: CourierEnvelope.epochDay(for: Date())
            ),
            expiry: UInt64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            ciphertext: Data(repeating: 0xD0, count: 128),
            copies: TransportConfig.courierInitialCopies
        )
        #expect(carol.service.courierStore.deposit(forDave, from: alice.service.noiseStaticPublicKeyData()))

        // Carol's central role reaches Bob: Bob's only announce on the link
        // answers Carol's link-up, before any Noise session exists.
        mesh.linkUp(central: 1, peripheral: bobIndex)
        mesh.settle()
        // The spray's trust gate runs on the main actor; the send itself
        // goes back to Carol's engine.
        let sprayed = await mainActorDrained {
            carol.service._test_fenceEngine()
            return courierFrames(from: mesh, sender: 1, to: bob.myPeerID).contains { $0.envelope.ciphertext == forDave.ciphertext }
        }
        #expect(sprayed)

        let lastHandshake = mesh.emittedPackets(from: 1).lastIndex { $0.type == MessageType.noiseHandshake.rawValue } ?? .max
        let frames = courierFrames(from: mesh, sender: 1, to: bob.myPeerID)
        let bobsMail = frames.filter { $0.envelope.ciphertext != forDave.ciphertext }
        print("BUDGET[courier handover]: courierFramesToRecipient=\(bobsMail.count)")
        // Bob's own mail goes over once the link is authenticated (the
        // earlier speculative copy is a separate path). No physical link
        // accepts the send in the harness, so Carol keeps the durable copy;
        // the attempt is what the tap records.
        #expect(bobsMail.filter { $0.index > lastHandshake }.count == 1)
        // Half of the copies of Dave's mail go to Bob to spread.
        let daveCopies = frames.filter { $0.envelope.ciphertext == forDave.ciphertext }
        #expect(daveCopies.map(\.envelope.copies) == [TransportConfig.courierInitialCopies / 2])
        #expect(daveCopies.allSatisfy { $0.index > lastHandshake })
        #expect(carol.service._test_isNoiseAuthenticatedCentral(mesh.linkUUID(from: bobIndex, at: 1), for: bob.myPeerID))
    }

    /// A rename right after another announce still reaches peers: its
    /// announce is owed, so the forced throttle defers it instead of
    /// dropping it. (A per-keystroke flood used to hide the drop.)
    @Test
    func renameRightAfterAnAnnounceStillReachesPeers() {
        let mesh = SimulatedMesh(announceAccounting: true)
        let alice = mesh.addNode(nickname: "alice")
        let bob = mesh.addNode(nickname: "bob")
        mesh.connect(0, 1)
        mesh.announceAll()
        mesh.settle()

        bob.service._test_forceAnnounce()
        bob.service.setNickname("robert")
        mesh.advanceTime(by: 0.3, inStepsOf: 0.05)

        #expect(alice.service.getPeerNicknames()[bob.service.myPeerID] == "robert")
    }

    /// A rename refused while an earlier owed announce's retry is pending,
    /// with another announce sent in between, still reaches peers. The
    /// pending retry lands inside that announce's throttle window and is
    /// refused too, so the rename needs a retry of its own.
    @Test
    func renameRefusedAfterAnInterveningAnnounceStillReachesPeers() {
        let mesh = SimulatedMesh(announceAccounting: true)
        let alice = mesh.addNode(nickname: "alice")
        let bob = mesh.addNode(nickname: "bob")
        mesh.connect(0, 1)
        mesh.announceAll()
        mesh.settle()

        bob.service._test_forceAnnounce()
        mesh.pump()
        mesh.advanceTime(by: 0.05)
        // Refused; its retry is due 0.2 s later.
        bob.service.setNickname("robert")
        mesh.pump()
        mesh.advanceTime(by: 0.12)
        // Admitted, carrying "robert", 0.08 s before that retry.
        bob.service._test_forceAnnounce()
        mesh.pump()
        mesh.advanceTime(by: 0.02)
        // Refused while the first retry is still pending.
        bob.service.setNickname("bobby")
        mesh.pump()
        mesh.advanceTime(by: 1.0, inStepsOf: 0.01)
        mesh.settle()

        #expect(alice.service.getPeerNicknames()[bob.service.myPeerID] == "bobby")
    }

    /// Phones bring links up one at a time. When the second comes up while
    /// the announce owed for the first is still waiting out the throttle,
    /// the joiner still claims both neighbours, so routes cross both new
    /// edges at once.
    @Test
    func joinerClaimsEveryNeighborWhenItsLinksFormInSequence() {
        let mesh = SimulatedMesh(announceAccounting: true)
        let a = mesh.launch(nickname: "a")
        let b = mesh.launch(nickname: "b")
        let joiner = mesh.launch(nickname: "joiner")

        mesh.linkUp(central: joiner, peripheral: a)
        mesh.advanceTime(by: 0.16, inStepsOf: 0.01)
        mesh.linkUp(central: joiner, peripheral: b)
        mesh.advanceTime(by: 1.0, inStepsOf: 0.01)
        mesh.exchangeInitialSync(joiner, a)
        mesh.exchangeInitialSync(joiner, b)
        mesh.settle()

        let aID = mesh.nodes[a].service.myPeerID
        let bID = mesh.nodes[b].service.myPeerID
        let lastClaims = mesh.emittedPackets(from: joiner)
            .last { $0.type == MessageType.announce.rawValue && $0.ttl == TransportConfig.messageTTLDefault }
            .flatMap { AnnouncementPacket.decode(from: $0.payload) }?
            .directNeighbors ?? []
        #expect(Set(lastClaims) == Set([aID.routingData, bID.routingData].compactMap { $0 }))
        #expect(mesh.nodes[a].service._test_confirmedRouteHops(to: bID) == 1)
        #expect(mesh.nodes[b].service._test_confirmedRouteHops(to: aID) == 1)
    }

    /// An owed announce's retry is dropped once another announce went out:
    /// that announce was built later, so it already carries what the retry
    /// would (here, the new name).
    @Test
    func owedRetryIsDroppedOnceAnotherAnnounceWentOut() {
        let mesh = SimulatedMesh(announceAccounting: true)
        let alice = mesh.addNode(nickname: "alice")
        let bob = mesh.addNode(nickname: "bob")
        mesh.connect(0, 1)
        mesh.announceAll()
        mesh.settle()
        let before = mesh.announceOriginations(from: 1)

        bob.service._test_forceAnnounce()
        mesh.pump()
        mesh.advanceTime(by: 0.12)
        // Refused; its retry is due 0.2 s later.
        bob.service.setNickname("robert")
        mesh.pump()
        mesh.advanceTime(by: 0.04)
        // Admitted, already carrying "robert".
        bob.service._test_forceAnnounce()
        mesh.pump()
        mesh.advanceTime(by: 1.0, inStepsOf: 0.01)
        mesh.settle()

        #expect(mesh.announceOriginations(from: 1) - before == 2)
        #expect(alice.service.getPeerNicknames()[bob.service.myPeerID] == "robert")
    }

    /// An owed announce that cannot be built (a nickname over the 255-byte
    /// field fails to encode) is retried once, not on a timer that keeps
    /// re-arming itself.
    @Test
    func unbuildableOwedAnnounceIsNotRetriedForever() {
        let mesh = SimulatedMesh(announceAccounting: true)
        let bob = mesh.addNode(nickname: "bob")
        mesh.addNode(nickname: "alice")
        mesh.connect(0, 1)
        mesh.announceAll()
        mesh.settle()

        bob.service._test_forceAnnounce()
        mesh.pump()
        // Refused (an announce just went out), so its retry is armed.
        bob.service.setNickname(String(repeating: "b", count: 256))
        mesh.pump()
        mesh.settle()
        // Long past every other deferred task of the setup.
        mesh.advanceTime(by: 60)

        #expect(bob.scheduler.pendingCount == 0)
    }

    /// Setting the nickname a node already has announces nothing (launch
    /// sets it twice: once while loading, once while wiring the transport).
    @Test
    func unchangedNicknameSendsNoAnnounce() {
        let mesh = SimulatedMesh(announceAccounting: true)
        let bob = mesh.addNode(nickname: "bob")
        mesh.addNode(nickname: "alice")
        mesh.connect(0, 1)
        mesh.announceAll()
        mesh.settle()
        let before = mesh.announceOriginations(from: 0)

        bob.service.setNickname("bob")
        mesh.settle()

        #expect(mesh.announceOriginations(from: 0) - before == 0)
    }

    // MARK: - Helpers

    /// Lets main-actor hops the engines already queued run (a bounded number
    /// of turns; nothing here waits on wall-clock time).
    private func mainActorDrained(until condition: () -> Bool) async -> Bool {
        for _ in 0..<50 where !condition() {
            await MainActor.run {}
        }
        return condition()
    }

    /// Courier envelopes `sender` addressed to `recipient`, with their
    /// position among everything `sender` emitted.
    private func courierFrames(
        from mesh: SimulatedMesh,
        sender: Int,
        to recipient: PeerID
    ) -> [(index: Int, envelope: CourierEnvelope)] {
        mesh.emittedPackets(from: sender).enumerated().compactMap { index, packet in
            guard packet.type == MessageType.courierEnvelope.rawValue,
                  PeerID(hexData: packet.recipientID) == recipient,
                  let envelope = CourierEnvelope.decode(packet.payload) else { return nil }
            return (index, envelope)
        }
    }

    private func originations(_ mesh: SimulatedMesh) -> [Int] {
        (0..<mesh.nodes.count).map { mesh.announceOriginations(from: $0) }
    }

    /// Per-node difference; nodes added after `before` count from zero.
    private func delta(_ after: [Int], _ before: [Int]) -> [Int] {
        after.indices.map { after[$0] - (before.indices.contains($0) ? before[$0] : 0) }
    }

    private func othersSpentNothing(_ spent: [Int], except endpoints: Set<Int>) -> Bool {
        spent.indices.allSatisfy { endpoints.contains($0) || spent[$0] == 0 }
    }

    private func knownPairs(_ mesh: SimulatedMesh) -> Int {
        let nodes = mesh.nodes.indices
        return nodes.reduce(0) { total, a in
            total + nodes.filter { $0 != a && mesh.knows(a, $0) }.count
        }
    }

    private func report(_ name: String, _ spent: [Int], frames: Int) {
        print("BUDGET[\(name)]: originations=\(spent.reduce(0, +)) maxPerNode=\(spent.max() ?? 0) announceFrames(ttl>0)=\(frames)")
    }

    /// A direct (TTL 7) announce for an identity the mesh has never seen.
    private func makeDirectAnnounce(
        nickname: String,
        noisePublicKey: Data,
        signingPublicKey: Data
    ) -> BitchatPacket? {
        let announcement = AnnouncementPacket(
            nickname: nickname,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            directNeighbors: nil
        )
        guard let payload = announcement.encode() else { return nil }
        return BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: PeerID(publicKey: noisePublicKey).id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )
    }
}
