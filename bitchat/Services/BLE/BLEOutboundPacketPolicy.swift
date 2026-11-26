import BitFoundation
import Foundation

enum BLEOutboundPacketPolicy {
    private static let fragmentFrameOverhead = 13 + 8 + 8 + 13

    static func messageID(for packet: BitchatPacket) -> String {
        BLEIngressLinkRegistry.messageID(for: packet)
    }

    static func padsBLEFrame(for packetType: UInt8) -> Bool {
        switch MessageType(rawValue: packetType) {
        case .noiseEncrypted, .noiseHandshake:
            return true
        // voiceFrame is deliberately unpadded: padding to the 512 block would
        // push every ~490-byte signed voice packet over the MTU into the
        // fragment path.
        //
        // announceV2 is unpadded too, but for a different reason and it is worth
        // revisiting: it is ~75 bytes, so the smallest bucket would triple the
        // airtime of the most frequently sent packet in the protocol. Its length
        // is already near-constant by construction (the tag block is fixed
        // width); the residual variation is the capability width and whether a
        // bridge geohash is present. Making those fixed-width would be cheaper
        // than padding. See docs/PEER-ID-ROTATION.md.
        case .none, .announce, .announceV2, .message, .leave, .requestSync, .fragment, .fileTransfer, .courierEnvelope, .boardPost, .ping, .pong, .nostrCarrier, .prekeyBundle, .groupMessage, .voiceFrame:
            return false
        }
    }

    static func priority(for packet: BitchatPacket, data _: Data) -> BLEOutboundWritePriority {
        guard let messageType = MessageType(rawValue: packet.type) else { return .low }
        switch messageType {
        case .fragment:
            return .fragment(totalFragments: fragmentTotalCount(from: packet.payload))
        case .fileTransfer:
            return .fileTransfer
        case .announceV2:
            // Stated rather than inherited from `default`. Presence is small,
            // time-bounded to its epoch, and useless once stale, so it belongs
            // with the other control traffic at high priority — but that should
            // be a decision on the record, not a fall-through, since this type
            // is not emitted yet and nobody would notice the choice being made.
            return .high
        default:
            return .high
        }
    }

    static func fragmentChunkSize(forLinkLimit limit: Int) -> Int {
        max(64, limit - fragmentFrameOverhead)
    }

    /// Exact wire overhead in bytes for an unpadded v1 broadcast fragment packet
    /// (`v1 header 14 + sender 8 + fragment payload header 13`).
    static func v1BroadcastFragmentFrameOverhead() -> Int {
        BinaryProtocol.v1HeaderSize + BinaryProtocol.senderIDSize + 13
    }

    /// Exact wire overhead in bytes for an unpadded v1 directed fragment packet
    /// (`v1 header 14 + sender 8 + recipient 8 + fragment payload header 13`).
    static func v1DirectedFragmentFrameOverhead() -> Int {
        BinaryProtocol.v1HeaderSize + BinaryProtocol.senderIDSize + BinaryProtocol.recipientIDSize + 13
    }

    /// Exact wire overhead in bytes for an unpadded v2 routed fragment packet
    /// carrying `routeHopCount` intermediate hops (`v2 header 16 + sender 8 +
    /// recipient 8 + route (1 + 8 * hops) + fragment payload header 13`).
    static func routedFragmentFrameOverhead(routeHopCount: Int) -> Int {
        16 + BinaryProtocol.senderIDSize + BinaryProtocol.recipientIDSize + (1 + routeHopCount * BinaryProtocol.senderIDSize) + 13
    }

    /// Computes the maximum fragment data chunk that fits inside `linkLimit`,
    /// accounting for exact v1 broadcast/directed (`14`-byte header) or v2
    /// routed framing and source-route hops. Returns `nil` when `linkLimit` is
    /// too small to carry even a 1-byte fragment or when `dataCount` would
    /// exceed `maxFragments`.
    static func fragmentChunkSize(
        for packet: BitchatPacket,
        linkLimit limit: Int,
        dataCount: Int? = nil,
        maxFragments: Int = BLEOutboundFragmentPlanner.maxSupportedFragments
    ) -> Int? {
        let chunkSize: Int
        if let route = packet.route, !route.isEmpty {
            let routedOverhead = routedFragmentFrameOverhead(routeHopCount: route.count)
            let available = limit - routedOverhead
            guard available > 0 else { return nil }
            chunkSize = available
        } else if packet.recipientID != nil {
            let directedOverhead = v1DirectedFragmentFrameOverhead()
            let available = limit - directedOverhead
            guard available > 0 else { return nil }
            chunkSize = available
        } else if packet.type == MessageType.fileTransfer.rawValue {
            let broadcastOverhead = v1BroadcastFragmentFrameOverhead()
            let available = limit - broadcastOverhead
            guard available > 0 else { return nil }
            chunkSize = available
        } else {
            chunkSize = fragmentChunkSize(forLinkLimit: limit)
        }
        if let dataCount, dataCount > 0 {
            let requiredFragments = BLEOutboundFragmentPlanner.fragmentCount(
                forDataCount: dataCount,
                chunkSize: chunkSize
            )
            guard requiredFragments > 0,
                  requiredFragments <= maxFragments else {
                return nil
            }
        }
        return chunkSize
    }

    private static func fragmentTotalCount(from payload: Data) -> Int {
        guard payload.count >= 12 else { return Int(UInt16.max) }
        let totalHigh = Int(payload[10])
        let totalLow = Int(payload[11])
        let total = (totalHigh << 8) | totalLow
        return max(total, 1)
    }
}
