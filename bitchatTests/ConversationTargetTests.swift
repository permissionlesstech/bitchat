//
// ConversationTargetTests.swift
// bitchatTests
//
// Pins the value type the send path is addressed with: where a target
// writes, what it accepts, and how a geohash counts as live.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
import BitFoundation
@testable import bitchat

struct ConversationTargetTests {
    private static let geohash = GeohashChannel(level: .city, geohash: "u4pruy")
    private static let otherGeohash = GeohashChannel(level: .city, geohash: "9q8yyk")
    private static let meshPeer = PeerID(str: "0011223344556677")
    private static let otherMeshPeer = PeerID(str: "8899aabbccddeeff")
    private static let geoDMPeer = PeerID(nostr_: String(repeating: "ab", count: 32))
    private static let geoChatPeer = PeerID(nostr: String(repeating: "cd", count: 32))
    private static let groupPeer = PeerID(groupID: Data(repeating: 0x42, count: 16))

    /// The table `canSendMediaInCurrentContext` used before it was derived
    /// from the target, kept verbatim so the two can't drift apart.
    private static func legacyCanSendMedia(activeChannel: ChannelID, selectedPeer: PeerID?) -> Bool {
        if let peer = selectedPeer {
            return !(peer.isGeoDM || peer.isGeoChat || peer.isGroup)
        }
        switch activeChannel {
        case .mesh: return true
        case .location: return false
        }
    }

    @Test func allowsMediaMatchesTheSelectionTable() {
        let channels: [ChannelID] = [.mesh, .location(Self.geohash)]
        let peers: [PeerID?] = [nil, Self.meshPeer, Self.geoDMPeer, Self.geoChatPeer, Self.groupPeer]
        for channel in channels {
            for peer in peers {
                let target = ConversationTarget(channel: channel, privatePeer: peer)
                #expect(
                    target.allowsMedia == Self.legacyCanSendMedia(activeChannel: channel, selectedPeer: peer),
                    "allowsMedia drifted for \(channel) / \(String(describing: peer))"
                )
            }
        }
        #expect(ConversationTarget.mesh.allowsMedia)
        #expect(!ConversationTarget.publicChannel(.location(Self.geohash)).allowsMedia)
        #expect(ConversationTarget(channel: .location(Self.geohash), privatePeer: Self.meshPeer).allowsMedia)
    }

    @Test func conversationIDNamesTheDMOrTheChannelTimeline() {
        #expect(ConversationTarget.mesh.conversationID == .mesh)
        #expect(ConversationTarget.publicChannel(.location(Self.geohash)).conversationID == .geohash("u4pruy"))
        let dm = ConversationTarget(channel: .location(Self.geohash), privatePeer: Self.meshPeer)
        #expect(dm.conversationID == .directPeer(Self.meshPeer))
        #expect(dm.isPrivate)
        #expect(!ConversationTarget.mesh.isPrivate)
    }

    @Test func draftKeyMatchesTheDraftStoreKey() {
        let fingerprint = String(repeating: "f", count: 64)
        let cases: [(ConversationTarget, String?)] = [
            (.mesh, nil),
            (.publicChannel(.location(Self.geohash)), nil),
            (ConversationTarget(channel: .mesh, privatePeer: Self.meshPeer), fingerprint),
            (ConversationTarget(channel: .mesh, privatePeer: Self.meshPeer), nil),
            (ConversationTarget(channel: .location(Self.geohash), privatePeer: Self.geoDMPeer), nil)
        ]
        for (target, fingerprint) in cases {
            #expect(
                target.draftKey(fingerprint: fingerprint)
                    == ComposerDraftStore.Key.from(peerID: target.privatePeer, fingerprint: fingerprint, channel: target.channel)
            )
        }
        // A Noise key's 64-hex peer ID keys the same draft as its fingerprint,
        // so a handoff keeps the person's draft (and held mic).
        let noiseKey = Data(repeating: 0x11, count: 32)
        let stableTarget = ConversationTarget(channel: .mesh, privatePeer: PeerID(hexData: noiseKey))
        let shortTarget = ConversationTarget(channel: .mesh, privatePeer: PeerID(publicKey: noiseKey))
        #expect(
            stableTarget.draftKey(fingerprint: nil)
                == shortTarget.draftKey(fingerprint: noiseKey.sha256Fingerprint())
        )
    }

    @Test func onlyMeshAndTheSelectedGeohashAreLive() {
        let geo = ChannelID.location(Self.geohash)
        #expect(ChannelID.mesh.isLive(whileSelected: .mesh))
        #expect(ChannelID.mesh.isLive(whileSelected: geo))
        #expect(geo.isLive(whileSelected: geo))
        #expect(!geo.isLive(whileSelected: .mesh))
        #expect(!geo.isLive(whileSelected: .location(Self.otherGeohash)))
        // The geohash is the identity, not its level or case.
        let sameCellOtherLevel = ChannelID.location(GeohashChannel(level: .neighborhood, geohash: "U4PRUY"))
        #expect(geo.isLive(whileSelected: sameCellOtherLevel))
    }
}
