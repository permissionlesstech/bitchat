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
        var ingressChecks: [(packet: BitchatPacket, innerSender: PeerID)] = []
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
            isAcceptedIngressPayload: { packet, innerSender in
                recorder.ingressChecks.append((packet, innerSender))
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

        handler.handle(packet, from: localPeerID)

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

        handler.handle(packet, from: remotePeerID)

        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.appendedHeaders.isEmpty)
    }

    @Test
    func broadcastFragmentIsTrackedAndAppended() {
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder)
        let chunk = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let packet = makeFragmentPacket(sender: remotePeerID, index: 0, total: 3, chunk: chunk)

        handler.handle(packet, from: remotePeerID)

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

        handler.handle(packet, from: remotePeerID)

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

        handler.handle(packet, from: remotePeerID)

        #expect(recorder.ingressChecks.count == 1)
        #expect(recorder.ingressChecks.first?.innerSender == innerSender)
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

        handler.handle(packet, from: remotePeerID)

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
                    handler.handle(fragment, from: remotePeerID)
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

        handler.handle(packet, from: remotePeerID)

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

        handler.handle(packet, from: remotePeerID)

        #expect(recorder.ingressChecks.isEmpty)
        #expect(recorder.reinjectedPackets.isEmpty)
    }

    @Test
    func incompleteAssemblyDoesNotReinject() {
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder)
        let packet = makeFragmentPacket(sender: remotePeerID, index: 0, total: 2)

        handler.handle(packet, from: remotePeerID)

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
}
