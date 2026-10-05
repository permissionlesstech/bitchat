//
// PeerDisplayNameResolverTests.swift
// bitchatTests
//
// Tests for PeerDisplayNameResolver nickname-collision suffixing
//

import Testing
import BitFoundation
@testable import bitchat

struct PeerDisplayNameResolverTests {

    @Test func uniqueNicknamesPassThroughUnchanged() {
        let alice = PeerID(str: "aaaa000000000000")
        let bob = PeerID(str: "bbbb000000000000")

        let result = PeerDisplayNameResolver.resolve(
            [
                (peerID: alice, nickname: "alice", isConnected: true),
                (peerID: bob, nickname: "bob", isConnected: true)
            ],
            selfNickname: "me"
        )

        #expect(result[alice] == "alice")
        #expect(result[bob] == "bob")
    }

    @Test func connectedCollisionSuffixesBothPeers() {
        let first = PeerID(str: "1111000000000000")
        let second = PeerID(str: "2222000000000000")

        let result = PeerDisplayNameResolver.resolve(
            [
                (peerID: first, nickname: "sam", isConnected: true),
                (peerID: second, nickname: "sam", isConnected: true)
            ],
            selfNickname: "me"
        )

        #expect(result[first] == "sam#" + String(first.id.prefix(4)))
        #expect(result[second] == "sam#" + String(second.id.prefix(4)))
    }



    @Test func emptyPeerListReturnsEmptyMap() {
        let result = PeerDisplayNameResolver.resolve([], selfNickname: "me")
        #expect(result.isEmpty)
    }
}
