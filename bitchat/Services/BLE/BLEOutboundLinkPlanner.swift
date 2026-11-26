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
        let isFragment = packet.type == MessageType.fragment.rawValue
        let isRouted = !(packet.route?.isEmpty ?? true)

        // Filter out links whose physical MTU cannot carry this packet BEFORE
        // duplicate-peer link collapse, so an undersized preferred link (e.g.,
        // a 50-byte peripheral) cannot hide a usable sibling link (e.g., a
        // 512-byte central) to the same peer during strict unicast or fallback.
        func isLinkCapable(limit: Int?) -> Bool {
            guard let limit else { return true }
            if dataCount <= limit { return true }
            if isFragment {
                // Already-fragmented packets cannot be re-fragmented; enforce
                // encoded MTU for strict direct sends and routed fragments.
                return !(requireDirectPeerLink || isRouted)
            }
            return BLEOutboundPacketPolicy.fragmentChunkSize(
                for: packet,
                linkLimit: limit,
                dataCount: dataCount
            ) != nil
        }

        let peripheralLimitByID = Dictionary(zip(peripheralIDs, peripheralWriteLimits), uniquingKeysWith: { first, _ in first })
        let centralLimitByID = Dictionary(zip(centralIDs, centralNotifyLimits), uniquingKeysWith: { first, _ in first })

        let capablePeripheralIDs = peripheralIDs.filter { isLinkCapable(limit: peripheralLimitByID[$0]) }
        let capableCentralIDs = centralIDs.filter { isLinkCapable(limit: centralLimitByID[$0]) }

        let effectiveLinks = BLEFanoutSelector.selectLinks(
            peripheralIDs: capablePeripheralIDs,
            centralIDs: capableCentralIDs,
            ingressLink: ingressRecord?.link,
            excludedLinks: excludedLinks,
            peripheralPeerBindings: peripheralPeerBindings,
            centralPeerBindings: centralPeerBindings,
            preferredPeripheralPerPeer: preferredPeripheralPerPeer,
            collapseDuplicatePeerLinks: !isDirectAnnounce,
            directedPeerHint: directedPeerHint,
            requireDirectPeerLink: requireDirectPeerLink
        )

        // Fragment only for links that this packet can actually use. Looking
        // at every connected link before directed-peer selection lets an
        // unrelated peer's MTU make an oversized directed send look routable,
        // even though every resulting fragment will select zero target links.
        if !isFragment {
            let selectedPeripheralLimits = capablePeripheralIDs.compactMap { id in
                effectiveLinks.peripheralIDs.contains(id) ? peripheralLimitByID[id] : nil
            }
            let selectedCentralLimits = capableCentralIDs.compactMap { id in
                effectiveLinks.centralIDs.contains(id) ? centralLimitByID[id] : nil
            }
            if let minLimit = minimumLinkLimit(
                peripheralWriteLimits: selectedPeripheralLimits,
                centralNotifyLimits: selectedCentralLimits
            ), dataCount > minLimit,
               let chunkSize = BLEOutboundPacketPolicy.fragmentChunkSize(
                   for: packet,
                   linkLimit: minLimit,
                   dataCount: dataCount
               ) {
                return BLEOutboundLinkPlan(
                    directedPeerHint: directedPeerHint,
                    fragmentChunkSize: chunkSize,
                    selectedLinks: effectiveLinks,
                    shouldSpoolDirectedPacket: false
                )
            }
        }

        return BLEOutboundLinkPlan(
            directedPeerHint: directedPeerHint,
            fragmentChunkSize: nil,
            selectedLinks: effectiveLinks,
            shouldSpoolDirectedPacket: shouldSpoolDirectedPacket(
                directedPeerHint: directedPeerHint,
                selectedLinks: effectiveLinks,
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
