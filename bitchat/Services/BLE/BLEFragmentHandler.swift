import BitFoundation
import BitLogger
import Foundation

/// Narrow environment for `BLEFragmentHandler`.
///
/// All queue hops (the message-queue entry hop and the collections barrier
/// around the assembly buffer) live on the `BLEService` side — the entry hop
/// in `BLEService.handleFragment`, the barrier inside the supplied closures —
/// keeping the handler queue-agnostic and synchronously testable.
struct BLEFragmentHandlerEnvironment {
    /// Local peer identity at the time the fragment is handled.
    let localPeerID: () -> PeerID
    /// Tracks broadcast fragments for gossip sync.
    let trackPacketSeen: (BitchatPacket) -> Void
    /// Appends the fragment to the assembly buffer (collections barrier write).
    let appendFragment: (BLEFragmentHeader) -> BLEFragmentAssemblyBuffer.AppendResult
    /// Ingress acceptance check for the reassembled inner packet.
    let isAcceptedIngressPayload: (_ packet: BitchatPacket, _ innerSender: PeerID) -> Bool
    /// Re-enters the receive pipeline with the reassembled packet (TTL already zeroed).
    let processReassembledPacket: (_ packet: BitchatPacket, _ from: PeerID) -> Void
}

/// Orchestrates inbound fragments: self-fragment suppression, gossip tracking,
/// assembly-buffer appends, and reassembled-packet validation and re-injection
/// into the receive pipeline.
final class BLEFragmentHandler {
    private let environment: BLEFragmentHandlerEnvironment

    init(environment: BLEFragmentHandlerEnvironment) {
        self.environment = environment
    }

    @discardableResult
    func handle(_ packet: BitchatPacket, from peerID: PeerID) -> Bool {
        let env = environment
        guard let header = BLEFragmentHeader(packet: packet) else { return false }

        // REQUEST_SYNC is strictly link-local (ttl == 0) and never fragmented.
        // Rejecting it here stops a relayed fragment from zeroing TTL on
        // reassembly and triggering a mesh-wide gossip store replay.
        if header.originalType == MessageType.requestSync.rawValue {
            SecureLogger.warning("🚫 Dropping fragmented REQUEST_SYNC from \(peerID.id.prefix(8))…", category: .security)
            return false
        }

        // Sync replay legitimately hands us our own fragments back (the RSR
        // ttl=0 restore path): after a relaunch the fragment store starts
        // empty, so our sync filter doesn't cover them and peers re-offer
        // them. Record them as seen — the next round's filter then covers
        // them and the redelivery stops — but skip assembly: we authored
        // the original, there is nothing to reassemble.
        if peerID == env.localPeerID() {
            if header.isBroadcastFragment {
                env.trackPacketSeen(packet)
            }
            return true
        }

        // Keep broadcast sync tracking and mesh relay independent of local
        // first-wins storage rejection so an injected conflicting fragment
        // cannot suppress honest downstream copies or REQUEST_SYNC recovery.
        if header.isBroadcastFragment {
            env.trackPacketSeen(packet)
        }

        let assemblyResult = env.appendFragment(header)

        logFragmentAssemblyResult(assemblyResult)

        switch assemblyResult {
        case .oversized, .mismatched, .stored:
            return true
        case let .complete(completedHeader, reassembled, _):
            // Decode the original packet bytes we reassembled, so flags/compression are preserved
            if var originalPacket = BinaryProtocol.decode(reassembled) {

                // Reassembled packet validation. Both platforms' fragmenters copy
                // the inner type into every fragment, and the assembly was sized
                // for that claim, so a packet of any other type is forged.
                let innerSender = PeerID(hexData: originalPacket.senderID)
                if originalPacket.type != completedHeader.originalType {
                    SecureLogger.warning(
                        "🚫 Reassembled packet id=\(completedHeader.idLogString) is type \(originalPacket.type), fragments claimed \(completedHeader.originalType)",
                        category: .security
                    )
                    return false
                } else if originalPacket.type == MessageType.requestSync.rawValue {
                    SecureLogger.warning("🚫 Dropping reassembled REQUEST_SYNC from \(peerID.id.prefix(8))…", category: .security)
                    return false
                } else if !env.isAcceptedIngressPayload(originalPacket, innerSender) {
                    return false
                } else {
                    SecureLogger.debug("✅ Reassembled packet id=\(completedHeader.idLogString) type=\(originalPacket.type) bytes=\(reassembled.count)", category: .session)
                    originalPacket.ttl = 0
                    env.processReassembledPacket(originalPacket, peerID)
                    return true
                }
            } else {
                SecureLogger.error("❌ Failed to decode reassembled packet (type=\(completedHeader.originalType), total=\(completedHeader.total))", category: .session)
                return false
            }
        }
    }

    private func logFragmentAssemblyResult(_ result: BLEFragmentAssemblyBuffer.AppendResult) {
        func logStartedIfNeeded(header: BLEFragmentHeader, started: Bool) {
            if started {
                SecureLogger.debug("📦 Started fragment assembly id=\(header.idLogString) total=\(header.total)", category: .session)
            }
        }

        switch result {
        case let .stored(header, started):
            logStartedIfNeeded(header: header, started: started)
            SecureLogger.debug("📦 Fragment \(header.index + 1)/\(header.total) (len=\(header.fragmentData.count)) for id=\(header.idLogString)", category: .session)

        case let .complete(header, _, started):
            logStartedIfNeeded(header: header, started: started)
            SecureLogger.debug("📦 Fragment \(header.index + 1)/\(header.total) (len=\(header.fragmentData.count)) for id=\(header.idLogString)", category: .session)

        case let .oversized(header, projectedSize, limit, started):
            logStartedIfNeeded(header: header, started: started)
            SecureLogger.warning(
                "🚫 Fragment assembly exceeds size limit (\(projectedSize) bytes > \(limit)), evicting. Type=\(header.originalType) Index=\(header.index)/\(header.total)",
                category: .security
            )

        case let .mismatched(header, expectedTotal, expectedOriginalType):
            SecureLogger.warning(
                "🚫 Dropping mismatched fragment for id=\(header.idLogString): got total=\(header.total) type=\(header.originalType), expected total=\(expectedTotal) type=\(expectedOriginalType)",
                category: .security
            )
        }
    }
}
