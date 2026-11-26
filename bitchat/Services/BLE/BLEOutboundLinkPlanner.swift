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
        requireDirectPeerLink: Bool = false,
        precomputedMessageID: String? = nil
    ) -> BLEOutboundLinkPlan {
        let directedPeerHint = directedPeerHint(for: packet, explicitPeer: directedOnlyPeer)
        // Direct announces bypass the per-peer duplicate-link collapse so
        // every live link gets bound (see BLEFanoutSelector.selectLinks).
        let isDirectAnnounce = packet.type == MessageType.announce.rawValue && packet.ttl == directAnnounceTTL
        // Only compute messageID (which SHA-256 hashes payload) when subsetting
        // might actually need it or when already precomputed by the caller.
        let needsSubsetSeed = BLEFanoutSelector.shouldSubset(
            packetType: packet.type,
            directedPeerHint: directedPeerHint
        ) && (peripheralIDs.count > 2 || centralIDs.count > 2)
        let messageID = precomputedMessageID ?? (needsSubsetSeed ? BLEOutboundPacketPolicy.messageID(for: packet) : "")
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
            messageID: messageID
        )

        // Fragment only for links that this packet can actually use. Looking
        // at every connected link before directed-peer selection lets an
        // unrelated peer's MTU make an oversized directed send look routable,
        // even though every resulting fragment will select zero target links.
        if packet.type != MessageType.fragment.rawValue {
            var minLimit: Int?
            updateMinimumLimit(&minLimit, ids: peripheralIDs, limits: peripheralWriteLimits, selected: selectedLinks.peripheralIDs)
            updateMinimumLimit(&minLimit, ids: centralIDs, limits: centralNotifyLimits, selected: selectedLinks.centralIDs)
            if let minLimit, dataCount > minLimit {
                return BLEOutboundLinkPlan(
                    directedPeerHint: directedPeerHint,
                    fragmentChunkSize: BLEOutboundPacketPolicy.fragmentChunkSize(forLinkLimit: minLimit),
                    selectedLinks: selectedLinks,
                    shouldSpoolDirectedPacket: false
                )
            }
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

    private static func updateMinimumLimit(
        _ minLimit: inout Int?,
        ids: [String],
        limits: [Int],
        selected: Set<String>
    ) {
        guard !selected.isEmpty else { return }
        let count = min(ids.count, limits.count)
        for i in 0..<count where selected.contains(ids[i]) {
            let limit = limits[i]
            if let current = minLimit {
                if limit < current { minLimit = limit }
            } else {
                minLimit = limit
            }
        }
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
