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




    @Test func emptyPeerListReturnsEmptyMap() {
        let result = PeerDisplayNameResolver.resolve([], selfNickname: "me")
        #expect(result.isEmpty)
    }
}
