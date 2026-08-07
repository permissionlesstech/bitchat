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
                (peerID: bob, nickname: "bob", isConnected: true),
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
                (peerID: second, nickname: "sam", isConnected: true),
            ],
            selfNickname: "me"
        )

        #expect(result[first] == "sam#" + String(first.id.prefix(4)))
        #expect(result[second] == "sam#" + String(second.id.prefix(4)))
    }

    @Test func disconnectedPeerIsExemptFromSuffixingAndFromCollisionCounting() {
        let connectedA = PeerID(str: "aaaa000000000000")
        let connectedB = PeerID(str: "bbbb000000000000")
        let disconnected = PeerID(str: "cccc000000000000")

        let result = PeerDisplayNameResolver.resolve(
            [
                (peerID: connectedA, nickname: "sam", isConnected: true),
                (peerID: connectedB, nickname: "sam", isConnected: true),
                (peerID: disconnected, nickname: "sam", isConnected: false),
            ],
            selfNickname: "me"
        )

        // The two connected peers still collide with each other and get suffixed.
        #expect(result[connectedA] == "sam#" + String(connectedA.id.prefix(4)))
        #expect(result[connectedB] == "sam#" + String(connectedB.id.prefix(4)))
        // The disconnected peer is never suffixed, regardless of collisions.
        #expect(result[disconnected] == "sam")
    }

    @Test func selfNicknameTriggersSuffixOnLoneRemotePeer() {
        // Only one remote peer shares the nickname, but it collides with the
        // local user's own current nickname, so it still gets suffixed.
        let remote = PeerID(str: "dddd000000000000")

        let result = PeerDisplayNameResolver.resolve(
            [(peerID: remote, nickname: "me", isConnected: true)],
            selfNickname: "me"
        )

        #expect(result[remote] == "me#" + String(remote.id.prefix(4)))
    }

    @Test func emptyPeerListReturnsEmptyMap() {
        let result = PeerDisplayNameResolver.resolve([], selfNickname: "me")
        #expect(result.isEmpty)
    }
}
