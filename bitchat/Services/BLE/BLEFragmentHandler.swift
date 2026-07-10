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

    func handle(_ packet: BitchatPacket, from peerID: PeerID) {
        let env = environment
        guard let header = BLEFragmentHeader(packet: packet) else { return }

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
            return
        }

        if header.isBroadcastFragment {
            env.trackPacketSeen(packet)
        }

        let assemblyResult = env.appendFragment(header)

        logFragmentAssemblyResult(assemblyResult)

        guard case let .complete(completedHeader, reassembled, _) = assemblyResult else { return }

        // Decode the original packet bytes we reassembled, so flags/compression are preserved
        if var originalPacket = BinaryProtocol.decode(reassembled) {

            // Reassembled packet validation
            let innerSender = PeerID(hexData: originalPacket.senderID)
            if !env.isAcceptedIngressPayload(originalPacket, innerSender) {
                // Cleanup below
            } else {
                SecureLogger.debug("✅ Reassembled packet id=\(completedHeader.idLogString) type=\(originalPacket.type) bytes=\(reassembled.count)", category: .session)
                originalPacket.ttl = 0
                env.processReassembledPacket(originalPacket, peerID)
            }
        } else {
            SecureLogger.error("❌ Failed to decode reassembled packet (type=\(completedHeader.originalType), total=\(completedHeader.total))", category: .session)
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
        }
    }
}
