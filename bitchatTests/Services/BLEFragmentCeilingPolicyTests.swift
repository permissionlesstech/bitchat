import BitFoundation
import Foundation
import Testing

@testable import bitchat

struct BLEFragmentCeilingPolicyTests {
    private let fileTransfer = MessageType.fileTransfer.rawValue
    private let noiseEncrypted = MessageType.noiseEncrypted.rawValue

    // MARK: - The proxy, unchanged where nothing was negotiated

    @Test
    func directedFileTransferWithoutAnAdvertisementKeepsTheMigrationCap() {
        let decision = BLEFragmentCeilingPolicy.decide(
            packetType: fileTransfer,
            isDirectedToPeer: true,
            negotiatedCeiling: nil
        )

        #expect(decision.source == .migrationFallbackProxy)
        #expect(decision.maxFragments == BLEOutboundFragmentPlanner.privateMediaV1MaxFragments)
        #expect(decision.admits(fragmentCount: 256))
        #expect(!decision.admits(fragmentCount: 257))
    }

    @Test
    func encryptedMediaWithoutAnAdvertisementKeepsTheFullLocalCeiling() {
        let decision = BLEFragmentCeilingPolicy.decide(
            packetType: noiseEncrypted,
            isDirectedToPeer: true,
            negotiatedCeiling: nil
        )

        #expect(decision.source == .localCeiling)
        #expect(decision.maxFragments == BLEFragmentAssemblyBuffer.maxReassemblyFragments)
        // The regression the 256 cap caused for iOS→iOS photos in the
        // ~120–512 KiB range: those plans must still be admitted.
        #expect(decision.admits(fragmentCount: 900))
    }

    @Test
    func broadcastFileTransferIsNotTreatedAsTheDirectedMigrationPath() {
        let decision = BLEFragmentCeilingPolicy.decide(
            packetType: fileTransfer,
            isDirectedToPeer: false,
            negotiatedCeiling: nil
        )

        #expect(decision.source == .localCeiling)
        #expect(decision.maxFragments == BLEFragmentAssemblyBuffer.maxReassemblyFragments)
    }

    // MARK: - An advertisement replaces the proxy

    @Test
    func anAdvertisedCeilingBelowTheMigrationCapIsHonoured() {
        // The case the type proxy gets wrong in the silent direction: a client
        // on the encrypted path whose reassembler is smaller than ours. Without
        // the advertisement we would happily plan 900 fragments it will drop.
        let decision = BLEFragmentCeilingPolicy.decide(
            packetType: noiseEncrypted,
            isDirectedToPeer: true,
            negotiatedCeiling: 128
        )

        #expect(decision.source == .negotiated)
        #expect(decision.maxFragments == 128)
        #expect(decision.admits(fragmentCount: 128))
        #expect(!decision.admits(fragmentCount: 129))
    }

    @Test
    func anAdvertisedCeilingAboveTheMigrationCapLiftsItForThatPeer() {
        // A peer that speaks 0x21 has told us the deployed-Android assumption
        // behind the 256 cap does not describe it.
        let decision = BLEFragmentCeilingPolicy.decide(
            packetType: fileTransfer,
            isDirectedToPeer: true,
            negotiatedCeiling: 1024
        )

        #expect(decision.source == .negotiated)
        #expect(decision.maxFragments == 1024)
        #expect(decision.admits(fragmentCount: 1024))
    }

    @Test
    func anAdvertisedCeilingIsClampedToWhatWeWouldReassembleOurselves() {
        let local = BLEFragmentAssemblyBuffer.maxReassemblyFragments
        let decision = BLEFragmentCeilingPolicy.decide(
            packetType: noiseEncrypted,
            isDirectedToPeer: true,
            negotiatedCeiling: UInt16.max
        )

        #expect(decision.source == .negotiated)
        #expect(decision.maxFragments == local)
        #expect(!decision.admits(fragmentCount: local + 1))
    }

    @Test
    func aZeroAdvertisementFallsBackRatherThanBlockingEveryTransfer() {
        // The decoder rejects a zero on the wire, so this can only arrive from
        // a future caller passing one through. Treat it as absent: refusing
        // every fragment to that peer would be a worse failure than the proxy.
        let decision = BLEFragmentCeilingPolicy.decide(
            packetType: fileTransfer,
            isDirectedToPeer: true,
            negotiatedCeiling: 0
        )

        #expect(decision.source == .migrationFallbackProxy)
        #expect(decision.maxFragments == BLEOutboundFragmentPlanner.privateMediaV1MaxFragments)
    }

    // MARK: - Invariants across the whole input space

    @Test
    func noDecisionEverExceedsTheLocalCeiling() {
        let local = BLEFragmentAssemblyBuffer.maxReassemblyFragments
        let ceilings: [UInt16?] = [nil, 1, 255, 256, 257, 9_999, 10_000, 10_001, UInt16.max]
        let types: [UInt8] = [
            fileTransfer,
            noiseEncrypted,
            MessageType.message.rawValue,
            MessageType.announce.rawValue
        ]

        for ceiling in ceilings {
            for type in types {
                for directed in [true, false] {
                    let decision = BLEFragmentCeilingPolicy.decide(
                        packetType: type,
                        isDirectedToPeer: directed,
                        negotiatedCeiling: ceiling
                    )
                    #expect(decision.maxFragments >= 1)
                    #expect(decision.maxFragments <= local)
                }
            }
        }
    }

    @Test
    func advertisingOurOwnCeilingRoundTripsThroughTheWireField() throws {
        // The advertised number has to fit the 2-byte TLV, or we would ship a
        // truncated ceiling that reads as a much smaller buffer.
        let local = BLEFragmentAssemblyBuffer.maxReassemblyFragments
        #expect(local > 0)
        #expect(local <= Int(UInt16.max))

        let packet = AuthenticatedPeerStatePacket(
            capabilities: [.privateMedia],
            signingPublicKey: Data(repeating: 0x11, count: 32),
            maxReassemblyFragments: UInt16(local)
        )
        let encoded = try #require(packet.encode())
        let decoded = try #require(AuthenticatedPeerStatePacket.decode(from: encoded))
        let advertised = try #require(decoded.maxReassemblyFragments)
        #expect(Int(advertised) == local)
    }
}
