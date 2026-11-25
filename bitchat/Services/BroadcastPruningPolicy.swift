//
// BroadcastPruningPolicy.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

/// Shared target-filtering policy for broadcast relaying.
///
/// Guarantees two invariants:
/// 1. Echo/loopback suppression always skips the incoming transport link,
///    packet origin (`senderID`), and immediate previous hop (`previousHopPeerID`).
/// 2. When relaying a non-conservative broadcast packet whose previous hop has
///    a fresh topology announcement, skips forwarding to any identified target
///    peer that is a fresh confirmed neighbor of either `senderID` (origin) or
///    `previousHopPeerID`.
enum BroadcastPruningPolicy {
    /// Returns `true` if transmitting `packet` to the candidate link/peer should
    /// be skipped.
    static func shouldSkipTarget(
        packet: BitchatPacket,
        localPeerID: PeerID,
        targetPeerID: PeerID?,
        targetLink: BLEIngressLinkID? = nil,
        ingressLink: BLEIngressLinkID? = nil,
        previousHopPeerID: PeerID? = nil,
        skipNeighborPruning: Bool = false,
        topology: MeshTopologyTracker,
        edgeMaxAge: TimeInterval = TransportConfig.bleMprEdgeMaxAgeSeconds,
        now: Date = Date()
    ) -> Bool {
        // 1. Never echo back onto the exact link the packet arrived on.
        if let targetLink, let ingressLink, targetLink == ingressLink {
            return true
        }

        let originPeerID = PeerID(hexData: packet.senderID)

        // 2. Never send back to the packet's originator.
        if let targetPeerID, targetPeerID == originPeerID {
            return true
        }

        // 3. Never echo back to the immediate previous hop (even over an
        // alternate or dual-role link).
        if let targetPeerID, let previousHopPeerID, targetPeerID == previousHopPeerID {
            return true
        }

        // 4. Locally originated packets always fan out to all direct neighbors.
        if originPeerID == localPeerID {
            return false
        }

        // 5. Conservative / topology-healing packets skip neighbor pruning so
        // broken links heal.
        if skipNeighborPruning || isConservativePacket(packet) {
            return false
        }

        // 6. Unidentified target links are never pruned (fail-safe for newly
        // connected or legacy peers).
        guard let targetPeerID else {
            return false
        }

        // 7. Unknown, unbound, or expired previous hop disables neighbor pruning
        // completely (including origin neighbors) so late packets cannot prune
        // the only live path.
        guard let previousHopPeerID,
              !previousHopPeerID.isEmpty,
              topology.isFreshAnnouncement(for: previousHopPeerID, maxAge: edgeMaxAge, now: now) else {
            return false
        }

        // 8. Prune targets that are fresh confirmed neighbors of origin or previous hop.
        if topology.isFreshConfirmedNeighbor(originPeerID, targetPeerID, maxAge: edgeMaxAge, now: now) {
            return true
        }
        if previousHopPeerID != originPeerID &&
            topology.isFreshConfirmedNeighbor(previousHopPeerID, targetPeerID, maxAge: edgeMaxAge, now: now) {
            return true
        }

        return false
    }

    /// Computes the set of candidate BLE links to exclude for a broadcast relay.
    static func prunedLinks(
        packet: BitchatPacket,
        localPeerID: PeerID,
        peripheralIDs: [String],
        centralIDs: [String],
        peripheralPeerBindings: [String: PeerID],
        centralPeerBindings: [String: PeerID],
        ingressLink: BLEIngressLinkID?,
        previousHopPeerID: PeerID?,
        skipNeighborPruning: Bool,
        topology: MeshTopologyTracker,
        edgeMaxAge: TimeInterval = TransportConfig.bleMprEdgeMaxAgeSeconds,
        now: Date = Date()
    ) -> Set<BLEIngressLinkID> {
        var excluded = Set<BLEIngressLinkID>()

        for peripheralID in peripheralIDs {
            let link = BLEIngressLinkID.peripheral(peripheralID)
            if shouldSkipTarget(
                packet: packet,
                localPeerID: localPeerID,
                targetPeerID: peripheralPeerBindings[peripheralID],
                targetLink: link,
                ingressLink: ingressLink,
                previousHopPeerID: previousHopPeerID,
                skipNeighborPruning: skipNeighborPruning,
                topology: topology,
                edgeMaxAge: edgeMaxAge,
                now: now
            ) {
                excluded.insert(link)
            }
        }

        for centralID in centralIDs {
            let link = BLEIngressLinkID.central(centralID)
            if shouldSkipTarget(
                packet: packet,
                localPeerID: localPeerID,
                targetPeerID: centralPeerBindings[centralID],
                targetLink: link,
                ingressLink: ingressLink,
                previousHopPeerID: previousHopPeerID,
                skipNeighborPruning: skipNeighborPruning,
                topology: topology,
                edgeMaxAge: edgeMaxAge,
                now: now
            ) {
                excluded.insert(link)
            }
        }

        return excluded
    }

    private static func isConservativePacket(_ packet: BitchatPacket) -> Bool {
        if !BLEPacketFreshnessPolicy.isBroadcastRecipient(packet.recipientID) {
            return true
        }
        guard let messageType = MessageType(rawValue: packet.type) else {
            return true
        }
        switch messageType {
        case .leave,
             .noiseHandshake,
             .noiseEncrypted,
             .requestSync,
             .courierEnvelope,
             .ping,
             .pong,
             .nostrCarrier,
             .announceV2:
            return true
        case .boardPost:
            return BoardWire.urgentFlag(in: packet.payload)
        case .announce, .message, .fragment, .fileTransfer, .prekeyBundle, .groupMessage, .voiceFrame:
            return false
        }
    }
}
