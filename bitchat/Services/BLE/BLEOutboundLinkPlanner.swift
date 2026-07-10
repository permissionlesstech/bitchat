import BitFoundation
import Foundation

struct BLEOutboundLinkPlan: Equatable {
    let directedPeerHint: PeerID?
    let fragmentChunkSize: Int?
    let selectedLinks: BLEFanoutSelection
    let shouldSpoolDirectedPacket: Bool
}

enum BLEOutboundLinkPlanner {
    static func plan(
        packet: BitchatPacket,
        dataCount: Int,
        peripheralIDs: [String],
        peripheralWriteLimits: [Int],
        centralIDs: [String],
        centralNotifyLimits: [Int],
        ingressRecord: BLEIngressLinkRecord?,
        excludedLinks: Set<BLEIngressLinkID>,
        peripheralPeerBindings: [String: PeerID] = [:],
        centralPeerBindings: [String: PeerID] = [:],
        preferredPeripheralPerPeer: [PeerID: String] = [:],
        directAnnounceTTL: UInt8 = TransportConfig.messageTTLDefault,
        directedOnlyPeer: PeerID?,
        requireDirectPeerLink: Bool = false
    ) -> BLEOutboundLinkPlan {
        let directedPeerHint = directedPeerHint(for: packet, explicitPeer: directedOnlyPeer)
        // Direct announces bypass the per-peer duplicate-link collapse so
        // every live link gets bound (see BLEFanoutSelector.selectLinks).
        let isDirectAnnounce = packet.type == MessageType.announce.rawValue && packet.ttl == directAnnounceTTL
        let selectedLinks = BLEFanoutSelector.selectLinks(
            peripheralIDs: peripheralIDs,
            centralIDs: centralIDs,
            ingressLink: ingressRecord?.link,
            excludedLinks: excludedLinks,
            peripheralPeerBindings: peripheralPeerBindings,
            centralPeerBindings: centralPeerBindings,
            preferredPeripheralPerPeer: preferredPeripheralPerPeer,
            collapseDuplicatePeerLinks: !isDirectAnnounce,
            directedPeerHint: directedPeerHint,
            requireDirectPeerLink: requireDirectPeerLink,
            packetType: packet.type,
            messageID: BLEOutboundPacketPolicy.messageID(for: packet)
        )

        // Fragment only for links that this packet can actually use. Looking
        // at every connected link before directed-peer selection lets an
        // unrelated peer's MTU make an oversized directed send look routable,
        // even though every resulting fragment will select zero target links.
        let selectedPeripheralLimits = zip(peripheralIDs, peripheralWriteLimits).compactMap { id, limit in
            selectedLinks.peripheralIDs.contains(id) ? limit : nil
        }
        let selectedCentralLimits = zip(centralIDs, centralNotifyLimits).compactMap { id, limit in
            selectedLinks.centralIDs.contains(id) ? limit : nil
        }
        if let minLimit = minimumLinkLimit(
            peripheralWriteLimits: selectedPeripheralLimits,
            centralNotifyLimits: selectedCentralLimits
        ), packet.type != MessageType.fragment.rawValue,
           dataCount > minLimit {
            return BLEOutboundLinkPlan(
                directedPeerHint: directedPeerHint,
                fragmentChunkSize: BLEOutboundPacketPolicy.fragmentChunkSize(forLinkLimit: minLimit),
                selectedLinks: selectedLinks,
                shouldSpoolDirectedPacket: false
            )
        }

        return BLEOutboundLinkPlan(
            directedPeerHint: directedPeerHint,
            fragmentChunkSize: nil,
            selectedLinks: selectedLinks,
            shouldSpoolDirectedPacket: shouldSpoolDirectedPacket(
                directedPeerHint: directedPeerHint,
                selectedLinks: selectedLinks,
                packetType: packet.type
            )
        )
    }

    static func directedPeerHint(for packet: BitchatPacket, explicitPeer: PeerID?) -> PeerID? {
        if let explicitPeer { return explicitPeer }
        if let recipient = PeerID(str: packet.recipientID?.hexEncodedString()), !recipient.isEmpty {
            return recipient
        }
        return nil
    }

    static func minimumLinkLimit(peripheralWriteLimits: [Int], centralNotifyLimits: [Int]) -> Int? {
        [peripheralWriteLimits.min(), centralNotifyLimits.min()]
            .compactMap { $0 }
            .min()
    }

    static func shouldSpoolDirectedPacket(
        directedPeerHint: PeerID?,
        selectedLinks: BLEFanoutSelection,
        packetType: UInt8
    ) -> Bool {
        guard directedPeerHint != nil,
              selectedLinks.peripheralIDs.isEmpty,
              selectedLinks.centralIDs.isEmpty else {
            return false
        }

        return packetType == MessageType.noiseEncrypted.rawValue ||
            packetType == MessageType.noiseHandshake.rawValue
    }
}
