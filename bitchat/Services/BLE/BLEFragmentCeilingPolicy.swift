import BitFoundation
import Foundation

/// Applies authenticated peer fragment-count limits to outbound media.
/// A peer limit may lower either path, but may raise the migration ceiling only
/// on encrypted media. iOS does not advertise its own count: its reassembler
/// has a separate byte budget that cannot be expressed by this TLV.
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

    /// Preserve the existing fast path for encrypted peers without a limit.
    static func requiresPreflight(packetType: UInt8, negotiatedCeiling: UInt16?) -> Bool {
        packetType == MessageType.fileTransfer.rawValue || negotiatedCeiling != nil
    }

    /// The local clamp bounds the number of fragments we originate. It does
    /// not describe another peer's byte budget or guarantee relay capacity.
    static func decide(
        packetType: UInt8,
        isDirectedToPeer: Bool,
        negotiatedCeiling: UInt16?,
        localCeiling: Int = BLEFragmentAssemblyBuffer.maxReassemblyFragments,
        migrationFallbackCeiling: Int = BLEOutboundFragmentPlanner.privateMediaV1MaxFragments
    ) -> Decision {
        if isDirectedToPeer, let negotiatedCeiling, negotiatedCeiling > 0 {
            let pathCeiling = packetType == MessageType.noiseEncrypted.rawValue
                ? localCeiling : min(localCeiling, migrationFallbackCeiling)
            return Decision(
                maxFragments: min(Int(negotiatedCeiling), pathCeiling),
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
