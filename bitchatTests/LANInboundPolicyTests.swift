//
// LANInboundPolicyTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct LANInboundPolicyTests {

    private let local = PeerID(str: "1111111111111111")
    private let remote = PeerID(str: "2222222222222222")
    private let thirdParty = PeerID(str: "3333333333333333")

    private func packet(
        sender: PeerID,
        recipient: PeerID? = nil
    ) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data(hexString: sender.id) ?? Data(),
            recipientID: recipient.flatMap { Data(hexString: $0.id) },
            timestamp: 1,
            payload: Data("hello".utf8),
            signature: nil,
            ttl: 1
        )
    }

    @Test("A packet must claim the identity of the link it arrived on")
    func senderMustMatchTheLink() {
        #expect(LANInboundPolicy.senderMatches(packet(sender: remote), peerID: remote))
        #expect(!LANInboundPolicy.senderMatches(packet(sender: local), peerID: remote))
        #expect(!LANInboundPolicy.senderMatches(packet(sender: thirdParty), peerID: remote))
    }

    @Test("A broadcast packet is accepted, a packet for a third party is not")
    func recipientMustBeUsOrBroadcast() {
        #expect(LANInboundPolicy.recipientMatches(packet(sender: remote), localPeerID: local))
        #expect(
            LANInboundPolicy.recipientMatches(
                packet(sender: remote, recipient: local),
                localPeerID: local
            )
        )
        #expect(
            !LANInboundPolicy.recipientMatches(
                packet(sender: remote, recipient: thirdParty),
                localPeerID: local
            )
        )
    }

    @Test("Both checks are required together")
    func combinedCheck() {
        #expect(
            LANInboundPolicy.matches(
                packet(sender: remote, recipient: local),
                peerID: remote,
                localPeerID: local
            )
        )
        #expect(
            !LANInboundPolicy.matches(
                packet(sender: thirdParty, recipient: local),
                peerID: remote,
                localPeerID: local
            )
        )
    }

    @Test("Crossed links keep the outbound link of the smaller peer ID")
    func crossedLinksAgree() {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)

        // The smaller peer keeps its outbound link: it keeps an existing
        // outbound link and rejects an incoming one.
        #expect(
            LANLinkArbitration.shouldKeep(
                existingIsOutbound: true,
                incomingIsOutbound: false,
                existingCreatedAt: older,
                incomingCreatedAt: newer,
                localPeerID: local,
                remotePeerID: remote
            )
        )
        // The larger peer keeps its inbound link, so it drops its own
        // outbound connection to the smaller peer.
        #expect(
            !LANLinkArbitration.shouldKeep(
                existingIsOutbound: true,
                incomingIsOutbound: false,
                existingCreatedAt: older,
                incomingCreatedAt: newer,
                localPeerID: remote,
                remotePeerID: local
            )
        )
    }

    @Test("Two links in the same direction keep the older one")
    func sameDirectionUsesAge() {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        #expect(
            LANLinkArbitration.shouldKeep(
                existingIsOutbound: true,
                incomingIsOutbound: true,
                existingCreatedAt: older,
                incomingCreatedAt: newer,
                localPeerID: local,
                remotePeerID: remote
            )
        )
        #expect(
            !LANLinkArbitration.shouldKeep(
                existingIsOutbound: true,
                incomingIsOutbound: true,
                existingCreatedAt: newer,
                incomingCreatedAt: older,
                localPeerID: local,
                remotePeerID: remote
            )
        )
    }
}
