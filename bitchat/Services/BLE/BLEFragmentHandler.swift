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
    /// Ingress acceptance check for the reassembled inner packet, judged
    /// against the peer it is attributed to.
    let isAcceptedIngressPayload: (_ packet: BitchatPacket, _ validationPeerID: PeerID) -> Bool
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

    /// - Parameters:
    ///   - peerID: the fragment's claimed sender, which is the original
    ///     packet's author. Self-fragment suppression keys on it.
    ///   - boundPeerID: the peer bound to the link the fragment arrived on, or
    ///     nil when the link is unbound or the fragment did not arrive on a
    ///     link (a re-injected packet).
    func handle(_ packet: BitchatPacket, from peerID: PeerID, boundTo boundPeerID: PeerID?) {
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

            // Reassembled packet validation. A solicited sync response is
            // judged against the peer bound to the link that served it, the
            // rule the ingress registry applies to a flagged single frame: the
            // inner sender is the message's original author, who may hold no
            // sync request with us. With no bound link the packet is judged
            // against its own sender, as a single frame would be; the
            // fragments' claimed sender is never the anchor, because anyone
            // can name a peer we asked. validatePayload is the seam a
            // reassembled packet has always passed through; the guard's other
            // checks describe a frame on a link, not a packet rebuilt from one.
            let innerSender = PeerID(hexData: originalPacket.senderID)
            let validationPeerID = originalPacket.isRSR ? (boundPeerID ?? innerSender) : innerSender
            if !env.isAcceptedIngressPayload(originalPacket, validationPeerID) {
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
