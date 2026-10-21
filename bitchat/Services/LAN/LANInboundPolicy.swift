//
// LANInboundPolicy.swift
// bitchat
//
// Pure inbound-packet identity checks for the Wi-Fi LAN transport.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

/// Checks that a packet received on a LAN link belongs to that link.
///
/// The checks are deliberately pure so the security policy can be tested
/// without a socket. The transport must call them before acting on a packet;
/// otherwise a peer could claim a different sender ID on its own TCP link.
enum LANInboundPolicy {
    /// The packet claims the peer this link authenticated as.
    static func senderMatches(_ packet: BitchatPacket, peerID: PeerID) -> Bool {
        PeerID(hexData: packet.senderID) == peerID
    }

    /// A packet with no recipient is a broadcast; a packet with one must be
    /// addressed to us, not to a third party.
    static func recipientMatches(_ packet: BitchatPacket, localPeerID: PeerID) -> Bool {
        guard let recipientID = packet.recipientID else { return true }
        return PeerID(hexData: recipientID) == localPeerID
    }

    /// Both checks together.
    static func matches(_ packet: BitchatPacket, peerID: PeerID, localPeerID: PeerID) -> Bool {
        senderMatches(packet, peerID: peerID) && recipientMatches(packet, localPeerID: localPeerID)
    }
}

/// Deterministic choice when both peers opened a connection to each other.
///
/// Both sides must keep the same physical link or both links are torn down.
/// The smaller peer ID keeps its outbound link and the larger peer keeps its
/// inbound link; equal directions fall back to the older connection.
enum LANLinkArbitration {
    static func shouldKeep(
        existingIsOutbound: Bool,
        incomingIsOutbound: Bool,
        existingCreatedAt: Date,
        incomingCreatedAt: Date,
        localPeerID: PeerID,
        remotePeerID: PeerID
    ) -> Bool {
        if existingIsOutbound != incomingIsOutbound {
            let preferOutbound = localPeerID.id < remotePeerID.id
            return existingIsOutbound == preferOutbound
        }
        return existingCreatedAt <= incomingCreatedAt
    }
}
