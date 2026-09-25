import BitFoundation
import Foundation

/// Decides how many BLE fragments one outbound packet may be split into for a
/// particular recipient.
///
/// Before an explicit ceiling existed on the wire, this was inferred from the
/// packet type: a directed `fileTransfer` was assumed to be the raw migration
/// fallback aimed at current Android (256 fragments), and anything else was
/// assumed to be aimed at a client with a reassembler as large as our own.
/// That proxy holds only while "implements the encrypted `0x20` path" and "has
/// a large reassembler" are the same population. A client that adopts `0x20`
/// with a smaller buffer breaks it in the silent direction: we would send
/// fragments the peer drops, and the transfer fails with no local signal.
///
/// An authenticated peer that advertised `maxReassemblyFragments` has stated
/// its own limit inside the Noise session, so that number is used instead of
/// the proxy — in both directions. A peer asking for less than 256 is the case
/// the proxy gets dangerously wrong; a peer asking for more has told us the
/// migration cap does not apply to it.
///
/// Deliberately free of BLE, Combine and app-model imports: the whole decision
/// is inputs to outputs, and every branch below is exercised directly in
/// `BLEFragmentCeilingPolicyTests`.
enum BLEFragmentCeilingPolicy {
    /// Why a particular ceiling was chosen. Carried so the caller can log and
    /// explain a rejection, and so tests assert the reasoning rather than just
    /// the number — two sources can agree on a value by coincidence.
    enum Source: Equatable {
        /// The recipient advertised its own limit in authenticated peer state.
        case negotiated
        /// No advertisement; the recipient is assumed to be a released client
        /// on the directed raw-file migration path.
        case migrationFallbackProxy
        /// No advertisement and no reason to assume a small reassembler.
        case localCeiling
    }

    struct Decision: Equatable {
        let maxFragments: Int
        let source: Source

        func admits(fragmentCount: Int) -> Bool {
            fragmentCount <= maxFragments
        }
    }

    /// We never originate a transfer larger than we would be willing to
    /// reassemble ourselves. A peer advertising a ceiling above our own is not
    /// treated as an invitation to exceed it: the symmetric bound keeps one
    /// side's configuration change from silently raising the other side's
    /// memory exposure, and nothing today needs more.
    static func decide(
        packetType: UInt8,
        isDirectedToPeer: Bool,
        negotiatedCeiling: UInt16?,
        localCeiling: Int = BLEFragmentAssemblyBuffer.maxReassemblyFragments,
        migrationFallbackCeiling: Int = BLEOutboundFragmentPlanner.privateMediaV1MaxFragments
    ) -> Decision {
        if let negotiatedCeiling, negotiatedCeiling > 0 {
            return Decision(
                maxFragments: min(Int(negotiatedCeiling), localCeiling),
                source: .negotiated
            )
        }

        if isDirectedToPeer, packetType == MessageType.fileTransfer.rawValue {
            return Decision(
                maxFragments: min(migrationFallbackCeiling, localCeiling),
                source: .migrationFallbackProxy
            )
        }

        return Decision(maxFragments: localCeiling, source: .localCeiling)
    }
}
