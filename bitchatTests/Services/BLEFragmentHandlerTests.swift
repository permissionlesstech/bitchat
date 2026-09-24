@testable import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEFragmentHandlerTests {
    private final class Recorder {
        /// Optional override for the assembly result; defaults to `.stored`.
        var appendResult: ((BLEFragmentHeader) -> BLEFragmentAssemblyBuffer.AppendResult)?
        var accepted = true

        var trackedPackets: [BitchatPacket] = []
        var appendedHeaders: [BLEFragmentHeader] = []
        var ingressChecks: [(packet: BitchatPacket, validationPeer: PeerID)] = []
        var reinjectedPackets: [(packet: BitchatPacket, from: PeerID)] = []
    }

    private let localPeerID = PeerID(str: "0102030405060708")
    private let remotePeerID = PeerID(str: "1122334455667788")

    private func makeHandler(recorder: Recorder) -> BLEFragmentHandler {
        let environment = BLEFragmentHandlerEnvironment(
            localPeerID: { [localPeerID] in localPeerID },
            trackPacketSeen: { packet in
                recorder.trackedPackets.append(packet)
            },
            appendFragment: { header in
                recorder.appendedHeaders.append(header)
                return recorder.appendResult?(header) ?? .stored(header: header, started: true)
            },
            isAcceptedIngressPayload: { packet, validationPeer in
                recorder.ingressChecks.append((packet, validationPeer))
                return recorder.accepted
            },
            processReassembledPacket: { packet, from in
                recorder.reinjectedPackets.append((packet, from))
            }
        )
        return BLEFragmentHandler(environment: environment)
    }

    @Test
    func ownFragmentIsTrackedForSyncButNotAssembled() {
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder)
        let packet = makeFragmentPacket(sender: localPeerID, index: 0, total: 2)

        handler.handle(packet, from: localPeerID, boundTo: remotePeerID)

        // Sync replay hands own fragments back after a relaunch; they must
        // re-enter the sync store (so the next round's filter covers them
        // and redelivery stops) without being reassembled.
        #expect(recorder.trackedPackets.count == 1)
        #expect(recorder.appendedHeaders.isEmpty)
        #expect(recorder.reinjectedPackets.isEmpty)
    }

    @Test
    func malformedFragmentPayloadIsIgnored() {
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder)
        let packet = BitchatPacket(
            type: MessageType.fragment.rawValue,
            senderID: Data(hexString: remotePeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: 900_000,
            payload: Data([0x01, 0x02, 0x03]),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )

        handler.handle(packet, from: remotePeerID, boundTo: remotePeerID)

        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.appendedHeaders.isEmpty)
    }

    @Test
    func broadcastFragmentIsTrackedAndAppended() {
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder)
        let chunk = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let packet = makeFragmentPacket(sender: remotePeerID, index: 0, total: 3, chunk: chunk)

        handler.handle(packet, from: remotePeerID, boundTo: remotePeerID)

        #expect(recorder.trackedPackets.count == 1)
        #expect(recorder.appendedHeaders.count == 1)
        #expect(recorder.appendedHeaders.first?.index == 0)
        #expect(recorder.appendedHeaders.first?.total == 3)
        #expect(recorder.appendedHeaders.first?.originalType == MessageType.message.rawValue)
        #expect(recorder.appendedHeaders.first?.fragmentData == chunk)
        #expect(recorder.ingressChecks.isEmpty)
        #expect(recorder.reinjectedPackets.isEmpty)
    }

    @Test
    func directedFragmentIsNotTrackedForSync() {
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder)
        let packet = makeFragmentPacket(
            sender: remotePeerID,
            index: 1,
            total: 3,
            recipientID: Data(hexString: localPeerID.id)
        )

        handler.handle(packet, from: remotePeerID, boundTo: remotePeerID)

        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.appendedHeaders.count == 1)
    }

    @Test
    func completedReassemblyReinjectsAcceptedPacketWithZeroTTL() throws {
        let innerSender = PeerID(str: "99AABBCCDDEEFF00")
        let innerPacket = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data(hexString: innerSender.id) ?? Data(),
            recipientID: nil,
            timestamp: 900_000,
            payload: Data("hello".utf8),
            signature: nil,
            ttl: 5
        )
        let reassembled = try #require(innerPacket.toBinaryData())

        let recorder = Recorder()
        recorder.appendResult = { header in
            .complete(header: header, reassembledData: reassembled, started: false)
        }
        let handler = makeHandler(recorder: recorder)
        let packet = makeFragmentPacket(sender: remotePeerID, index: 1, total: 2)

        handler.handle(packet, from: remotePeerID, boundTo: remotePeerID)

        #expect(recorder.ingressChecks.count == 1)
        #expect(recorder.ingressChecks.first?.validationPeer == innerSender)
        #expect(recorder.reinjectedPackets.count == 1)
        let reinjected = recorder.reinjectedPackets.first
        #expect(reinjected?.from == remotePeerID)
        #expect(reinjected?.packet.type == MessageType.message.rawValue)
        #expect(reinjected?.packet.payload == Data("hello".utf8))
        // Reassembled packets must re-enter the pipeline with TTL zeroed.
        #expect(reinjected?.packet.ttl == 0)
    }

    @Test
    func rejectedReassembledPacketIsNotReinjected() throws {
        let innerPacket = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data(hexString: "99AABBCCDDEEFF00") ?? Data(),
            recipientID: nil,
            timestamp: 900_000,
            payload: Data("hello".utf8),
            signature: nil,
            ttl: 5
        )
        let reassembled = try #require(innerPacket.toBinaryData())

        let recorder = Recorder()
        recorder.accepted = false
        recorder.appendResult = { header in
            .complete(header: header, reassembledData: reassembled, started: false)
        }
        let handler = makeHandler(recorder: recorder)
        let packet = makeFragmentPacket(sender: remotePeerID, index: 1, total: 2)

        handler.handle(packet, from: remotePeerID, boundTo: remotePeerID)

        #expect(recorder.ingressChecks.count == 1)
        #expect(recorder.reinjectedPackets.isEmpty)
    }

    @Test
    func reassembledPacketPastItsTypeCapNeverReachesThePipeline() throws {
        // A large uncompressed inner frame streamed as compressed fragments
        // (each zero-filled chunk is a few dozen bytes on air) through the
        // real fragmenter and assembly buffer. One byte past the type's cap still fits the
        // assembly, whose ceiling adds framing, so decode must stop it.
        for type in [MessageType.message, .announce] {
            let cap = PacketPayloadLimits.maxPayloadBytes(forType: type.rawValue)
            var buffer = BLEFragmentAssemblyBuffer()
            let recorder = Recorder()
            recorder.appendResult = { header in
                buffer.append(header, maxInFlightAssemblies: 8)
            }
            let handler = makeHandler(recorder: recorder)

            for payloadSize in [cap, cap + 1] {
                let inner = BitchatPacket(
                    type: type.rawValue,
                    senderID: Data(hexString: "99AABBCCDDEEFF00") ?? Data(),
                    recipientID: nil,
                    timestamp: 900_000,
                    payload: uncompressiblePrefixThenZeros(count: payloadSize),
                    signature: nil,
                    ttl: 5,
                    version: payloadSize > Int(UInt16.max) ? 2 : 1
                )
                for fragment in try fragmentsAsReceived(inner) {
                    handler.handle(fragment, from: remotePeerID, boundTo: remotePeerID)
                }
            }

            #expect(
                recorder.reinjectedPackets.map(\.packet.payload.count) == [cap],
                "\(type.description) past its cap must not be reassembled into the pipeline"
            )
        }
    }

    @Test
    func reassembledPacketOfAnotherTypeThanItsFragmentsClaimIsDropped() throws {
        let innerPacket = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data(hexString: "99AABBCCDDEEFF00") ?? Data(),
            recipientID: nil,
            timestamp: 900_000,
            payload: Data("hello".utf8),
            signature: nil,
            ttl: 5
        )
        let reassembled = try #require(innerPacket.toBinaryData())

        let recorder = Recorder()
        recorder.appendResult = { header in
            .complete(header: header, reassembledData: reassembled, started: false)
        }
        let handler = makeHandler(recorder: recorder)
        // A file-transfer claim buys a framed-file-sized assembly; the
        // packet it produced must be a file transfer.
        let packet = makeFragmentPacket(
            sender: remotePeerID,
            index: 1,
            total: 2,
            originalType: MessageType.fileTransfer.rawValue
        )

        handler.handle(packet, from: remotePeerID, boundTo: remotePeerID)

        #expect(recorder.ingressChecks.isEmpty)
        #expect(recorder.reinjectedPackets.isEmpty)
    }

    @Test
    func undecodableReassembledDataIsDropped() {
        let recorder = Recorder()
        recorder.appendResult = { header in
            .complete(header: header, reassembledData: Data([0x00, 0x01]), started: false)
        }
        let handler = makeHandler(recorder: recorder)
        let packet = makeFragmentPacket(sender: remotePeerID, index: 1, total: 2)

        handler.handle(packet, from: remotePeerID, boundTo: remotePeerID)

        #expect(recorder.ingressChecks.isEmpty)
        #expect(recorder.reinjectedPackets.isEmpty)
    }

    @Test
    func incompleteAssemblyDoesNotReinject() {
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder)
        let packet = makeFragmentPacket(sender: remotePeerID, index: 0, total: 2)

        handler.handle(packet, from: remotePeerID, boundTo: remotePeerID)

        #expect(recorder.appendedHeaders.count == 1)
        #expect(recorder.ingressChecks.isEmpty)
        #expect(recorder.reinjectedPackets.isEmpty)
    }

    /// Every byte value once, then zeros: the encoder leaves the inner
    /// payload uncompressed (100% byte diversity), while the zero chunks
    /// compress inside their fragments.
    private func uncompressiblePrefixThenZeros(count: Int) -> Data {
        var payload = Data((0...255).map { UInt8($0) })
        payload.append(Data(count: count - payload.count))
        return payload
    }

    /// Fragments `packet` with the real planner, then puts each fragment
    /// through the wire codec as a receiver would.
    private func fragmentsAsReceived(_ packet: BitchatPacket) throws -> [BitchatPacket] {
        let request = BLEOutboundFragmentTransferRequest(
            packet: packet,
            pad: false,
            maxChunk: nil,
            directedPeer: nil,
            transferId: nil
        )
        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: request,
            defaultChunkSize: TransportConfig.bleDefaultFragmentSize,
            bleMaxMTU: 512
        ))
        var compressedFragments = 0
        let received = try plan.fragmentPackets.map { fragment in
            let frame = try #require(fragment.toBinaryData())
            if frame[BinaryProtocol.Offsets.flags] & BinaryProtocol.Flags.isCompressed != 0 {
                compressedFragments += 1
            }
            return try #require(BinaryProtocol.decode(frame))
        }
        // All but the first (the diverse bytes) and a short tail.
        #expect(compressedFragments >= received.count - 2)
        return received
    }

    // MARK: Reassembled sync replies

    @Test
    func reassembledSyncReplyIsAcceptedOnTheServingPeersRequest() throws {
        // The local peer asked servingPeer for sync. The served message was
        // written by another peer that the local peer holds no request with.
        let author = PeerID(str: "99AABBCCDDEEFF00")
        let servingPeer = remotePeerID
        let rig = SyncReplyRig()
        rig.requestSyncManager.registerRequest(to: servingPeer)
        let handler = makeHandler(rig: rig)
        // An hour old: only a solicited sync response gets past the skew window.
        let reply = makeSyncReply(author: author, isRSR: true, timestamp: SyncReplyRig.nowMs - 3_600_000)
        let fragments = try fragments(of: reply, servedTo: localPeerID)

        let admitted = ingest(fragments, boundTo: servingPeer, rig: rig, handler: handler)

        #expect(admitted == fragments.count)
        #expect(rig.ingressChecks.count == 1)
        #expect(rig.ingressChecks.first?.peer == servingPeer)
        #expect(rig.ingressChecks.first?.accepted == true)
        #expect(rig.reinjectedPackets.count == 1)
        // Re-injection keeps the author as the packet's peer, as before; only
        // the acceptance check moved to the serving peer.
        #expect(rig.reinjectedPackets.first?.from == author)
        #expect(rig.reinjectedPackets.first?.packet.senderID == Data(hexString: author.id))
        #expect(rig.reinjectedPackets.first?.packet.isRSR == true)
        #expect(rig.reinjectedPackets.first?.packet.ttl == 0)
    }

    @Test
    func reassembledSyncReplyWithoutARequestToTheServingPeerIsDropped() throws {
        let author = PeerID(str: "99AABBCCDDEEFF00")
        let servingPeer = remotePeerID
        let rig = SyncReplyRig()
        let handler = makeHandler(rig: rig)
        let reply = makeSyncReply(author: author, isRSR: true, timestamp: SyncReplyRig.nowMs - 3_600_000)
        let fragments = try fragments(of: reply, servedTo: localPeerID)

        // Fed straight to the handler, the way BLEService dispatches: the
        // claimed sender as `from`, the link's bound peer as `boundTo`. With no
        // request to the serving peer the ingress guard already drops each
        // fragment; this pins the handler's own check on the reassembled packet.
        for fragment in fragments {
            handler.handle(fragment, from: author, boundTo: servingPeer)
        }

        #expect(rig.ingressChecks.count == 1)
        #expect(rig.ingressChecks.first?.accepted == false)
        #expect(rig.reinjectedPackets.isEmpty)
    }

    @Test
    func unflaggedReassembledPacketIsStillJudgedOnItsAuthor() throws {
        // A request to the serving peer must not rescue an ordinary stale train
        // from another author: without the flag the author's timestamp decides.
        let author = PeerID(str: "99AABBCCDDEEFF00")
        let servingPeer = remotePeerID
        let rig = SyncReplyRig()
        rig.requestSyncManager.registerRequest(to: servingPeer)
        let handler = makeHandler(rig: rig)
        let reply = makeSyncReply(author: author, isRSR: false, timestamp: SyncReplyRig.nowMs - 3_600_000)
        let fragments = try fragments(of: reply, servedTo: localPeerID)

        for fragment in fragments {
            handler.handle(fragment, from: author, boundTo: servingPeer)
        }

        #expect(rig.ingressChecks.count == 1)
        #expect(rig.ingressChecks.first?.peer == author)
        #expect(rig.ingressChecks.first?.accepted == false)
        #expect(rig.reinjectedPackets.isEmpty)
    }

    @Test
    func reassemblyFollowsTheDirectPathsAcceptanceRule() throws {
        // The direct path is the reference: on a bound link a flagged frame is
        // judged against the bound peer, on an unbound link against its own
        // sender, and an unflagged frame needs a fresh timestamp. Across flag
        // placement, request state, age, author, link binding, and the sender
        // the fragments claim, a train accepted at reassembly is one the same
        // packet would pass as a single frame on the same link, and a train
        // whose fragments were all admitted is accepted exactly when that
        // frame would be.
        let servingPeer = remotePeerID
        let otherAuthor = PeerID(str: "99AABBCCDDEEFF00")
        let requestStates: [[PeerID]] = [[], [servingPeer], [otherAuthor], [servingPeer, otherAuthor]]
        var comparisons = 0

        for author in [otherAuthor, servingPeer] {
            for innerFlagged in [false, true] {
                for outerFlagged in [false, true] {
                    for timestamp in [SyncReplyRig.nowMs - 1_000, SyncReplyRig.nowMs - 3_600_000] {
                        for requested in requestStates {
                            for boundPeer in [servingPeer, nil] as [PeerID?] {
                                // The planner stamps the author on every fragment; a
                                // crafted train may name any peer instead.
                                for claimedSender in [author, servingPeer] {
                                    let rig = SyncReplyRig()
                                    for peer in requested {
                                        rig.requestSyncManager.registerRequest(to: peer)
                                    }
                                    let handler = makeHandler(rig: rig)
                                    let reply = makeSyncReply(author: author, isRSR: innerFlagged, timestamp: timestamp)
                                    let train = try fragments(of: reply, servedTo: localPeerID).map { fragment in
                                        BitchatPacket(
                                            type: fragment.type,
                                            senderID: Data(hexString: claimedSender.id) ?? Data(),
                                            recipientID: fragment.recipientID,
                                            timestamp: fragment.timestamp,
                                            payload: fragment.payload,
                                            signature: nil,
                                            ttl: fragment.ttl,
                                            version: fragment.version,
                                            route: fragment.route,
                                            isRSR: outerFlagged
                                        )
                                    }

                                    let directAccepted: Bool
                                    switch evaluate(reply, boundTo: boundPeer, rig: rig) {
                                    case .success: directAccepted = true
                                    case .failure: directAccepted = false
                                    }
                                    let admitted = ingest(train, boundTo: boundPeer, rig: rig, handler: handler)
                                    let reassemblyAccepted = !rig.reinjectedPackets.isEmpty

                                    let label = "author=\(author == servingPeer ? "servingPeer" : "other") inner=\(innerFlagged) outer=\(outerFlagged) age=\(SyncReplyRig.nowMs - timestamp)ms requested=\(requested.map { $0 == servingPeer ? "servingPeer" : "other" }) bound=\(boundPeer == nil ? "none" : "servingPeer") claimed=\(claimedSender == servingPeer ? "servingPeer" : "author")"
                                    #expect(!reassemblyAccepted || directAccepted, "reassembly accepted a packet the direct path refuses: \(label)")
                                    if admitted == train.count {
                                        #expect(reassemblyAccepted == directAccepted, "reassembly and direct path disagree on a fully admitted train: \(label)")
                                    }
                                    comparisons += 1
                                }
                            }
                        }
                    }
                }
            }
        }

        #expect(comparisons == 256)
    }

    private func makeFragmentPacket(
        sender: PeerID,
        index: UInt16,
        total: UInt16,
        originalType: UInt8 = MessageType.message.rawValue,
        chunk: Data = Data([0xAA, 0xBB]),
        recipientID: Data? = nil
    ) -> BitchatPacket {
        var payload = Data()
        payload.append(contentsOf: [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]) // fragment ID
        payload.append(UInt8(index >> 8))
        payload.append(UInt8(index & 0xFF))
        payload.append(UInt8(total >> 8))
        payload.append(UInt8(total & 0xFF))
        payload.append(originalType)
        payload.append(chunk)

        return BitchatPacket(
            type: MessageType.fragment.rawValue,
            senderID: Data(hexString: sender.id) ?? Data(),
            recipientID: recipientID,
            timestamp: 900_000,
            payload: payload,
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )
    }

    // MARK: Sync reply rig

    /// The real pieces a reassembled sync reply meets in production, wired the
    /// way `BLEService` wires them: the assembly buffer, and the ingress guard
    /// backed by a `RequestSyncManager`.
    private final class SyncReplyRig {
        /// Fixed clock (milliseconds since 1970) shared by the guard and the
        /// request window. Both the skew check and the window check read it.
        static let nowMs: UInt64 = 1_800_000_000_000
        static var now: Date { Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000) }

        let requestSyncManager = RequestSyncManager(now: { TimeInterval(SyncReplyRig.nowMs) / 1000 })
        var buffer = BLEFragmentAssemblyBuffer()
        var ingressChecks: [(packet: BitchatPacket, peer: PeerID, accepted: Bool)] = []
        var reinjectedPackets: [(packet: BitchatPacket, from: PeerID)] = []

        func isValidSyncResponse(_ peerID: PeerID) -> Bool {
            requestSyncManager.isValidResponse(from: peerID, isRSR: true)
        }
    }

    private func makeHandler(rig: SyncReplyRig) -> BLEFragmentHandler {
        let environment = BLEFragmentHandlerEnvironment(
            localPeerID: { [localPeerID] in localPeerID },
            trackPacketSeen: { _ in },
            appendFragment: { header in
                rig.buffer.append(
                    header,
                    maxInFlightAssemblies: TransportConfig.bleMaxInFlightAssemblies,
                    now: SyncReplyRig.now
                )
            },
            isAcceptedIngressPayload: { packet, peer in
                let result = BLEIngressPacketGuard.validatePayload(
                    packet,
                    from: peer,
                    nowMs: SyncReplyRig.nowMs,
                    isValidSyncResponse: rig.isValidSyncResponse
                )
                let accepted: Bool
                switch result {
                case .success: accepted = true
                case .failure: accepted = false
                }
                rig.ingressChecks.append((packet, peer, accepted))
                return accepted
            },
            processReassembledPacket: { packet, from in
                rig.reinjectedPackets.append((packet, from))
            }
        )
        return BLEFragmentHandler(environment: environment)
    }

    /// A sync reply as `GossipSyncManager` hands it to the transport: the
    /// stored broadcast message with ttl 0 and the flag as given.
    private func makeSyncReply(author: PeerID, isRSR: Bool, timestamp: UInt64) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data(hexString: author.id) ?? Data(),
            recipientID: nil,
            timestamp: timestamp,
            payload: Self.incompressiblePayload(count: 1_200),
            signature: nil,
            ttl: 0,
            isRSR: isRSR
        )
    }

    /// The fragments the requester's link receives: the reply split by the
    /// outbound planner exactly as `BLEService.sendFragmentedPacket` does for
    /// a directed send.
    private func fragments(of reply: BitchatPacket, servedTo requester: PeerID) throws -> [BitchatPacket] {
        let request = BLEOutboundFragmentTransferRequest(
            packet: reply,
            pad: false,
            maxChunk: nil,
            directedPeer: requester,
            transferId: nil
        )
        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: request,
            defaultChunkSize: TransportConfig.bleDefaultFragmentSize,
            bleMaxMTU: 512
        ))
        #expect(plan.totalFragments > 1)
        return plan.fragmentPackets
    }

    /// The transport compresses payloads before splitting them, and a repeated
    /// byte would collapse into one fragment. A fixed-seed xorshift stream is
    /// deterministic and does not compress.
    private static func incompressiblePayload(count: Int) -> Data {
        var state: UInt32 = 0x2545_F491
        return Data((0..<count).map { _ in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return UInt8(truncatingIfNeeded: state)
        })
    }

    /// What BLEService does to each fragment before the handler sees it: the
    /// ingress guard admits it on the link (`attributeAndHandlePacket`), then
    /// the dispatch hands the handler the fragment's claimed sender as `from`
    /// and the link's bound peer, nil when unbound, as `boundTo`
    /// (`handleReceivedPacketOnQueue`). Returns how many fragments the guard
    /// admitted; the rest never reach the handler.
    @discardableResult
    private func ingest(
        _ fragments: [BitchatPacket],
        boundTo boundPeer: PeerID?,
        rig: SyncReplyRig,
        handler: BLEFragmentHandler
    ) -> Int {
        var admitted = 0
        for fragment in fragments {
            guard case .success = evaluate(fragment, boundTo: boundPeer, rig: rig) else { continue }
            admitted += 1
            handler.handle(fragment, from: PeerID(hexData: fragment.senderID), boundTo: boundPeer)
        }
        return admitted
    }

    /// The direct path's decision for a packet arriving whole on a link bound
    /// to `boundPeer`, or on an unbound link when nil.
    private func evaluate(
        _ packet: BitchatPacket,
        boundTo boundPeer: PeerID?,
        rig: SyncReplyRig
    ) -> Result<BLEIngressPacketContext, BLEIngressPacketGuard.Rejection> {
        BLEIngressPacketGuard.evaluate(
            packet: packet,
            claimedSenderID: PeerID(hexData: packet.senderID),
            boundPeerID: boundPeer,
            localPeerID: localPeerID,
            directAnnounceTTL: TransportConfig.messageTTLDefault,
            nowMs: SyncReplyRig.nowMs,
            isValidSyncResponse: rig.isValidSyncResponse
        )
    }
}
