//
// BLESourceRouteOriginationPolicyTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

struct BLESourceRouteOriginationPolicyTests {
    private let localPeerIDData = Data(hexString: "0102030405060708")!
    private let recipient = PeerID(str: "1112131415161718")
    private let hop = Data(hexString: "2122232425262728")!

    private func makePacket(
        senderID: Data? = nil,
        recipientID: Data? = Data(hexString: "1112131415161718"),
        ttl: UInt8 = 7
    ) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: senderID ?? localPeerIDData,
            recipientID: recipientID,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data([0x01]),
            signature: nil,
            ttl: ttl
        )
    }

    private func route(
        packet: BitchatPacket,
        isRecipientConnected: Bool = false,
        shouldAttemptRoute: Bool = true,
        computedRoute: [Data]? = nil
    ) -> [Data]? {
        BLESourceRouteOriginationPolicy.route(
            for: packet,
            to: recipient,
            localPeerIDData: localPeerIDData,
            isRecipientConnected: { _ in isRecipientConnected },
            shouldAttemptRoute: { _ in shouldAttemptRoute },
            computeRoute: { _ in computedRoute ?? [self.hop] }
        )
    }

    @Test func routesWhenAllGatesPass() {
        #expect(route(packet: makePacket()) == [hop])
    }

    @Test func relayedPacketNeverGetsRoute() {
        let relayed = makePacket(senderID: Data(hexString: "aabbccddeeff0011"))
        #expect(route(packet: relayed) == nil)
    }

    @Test func broadcastRecipientNeverGetsRoute() {
        let broadcast = makePacket(recipientID: Data(repeating: 0xFF, count: 8))
        #expect(route(packet: broadcast) == nil)
        let noRecipient = makePacket(recipientID: nil)
        #expect(route(packet: noRecipient) == nil)
    }

    @Test func linkLocalTTLNeverGetsRoute() {
        // TTL 0/1 packets (e.g. REQUEST_SYNC) cannot traverse hops.
        #expect(route(packet: makePacket(ttl: 0)) == nil)
        #expect(route(packet: makePacket(ttl: 1)) == nil)
    }

    @Test func directlyConnectedRecipientNeverGetsRoute() {
        #expect(route(packet: makePacket(), isRecipientConnected: true) == nil)
    }

    @Test func suppressedRecipientFallsBackToFlood() {
        #expect(route(packet: makePacket(), shouldAttemptRoute: false) == nil)
    }

    @Test func missingOrEmptyRouteFallsBackToFlood() {
        var sawComputeRoute = false
        let result = BLESourceRouteOriginationPolicy.route(
            for: makePacket(),
            to: recipient,
            localPeerIDData: localPeerIDData,
            isRecipientConnected: { _ in false },
            shouldAttemptRoute: { _ in true },
            computeRoute: { _ in
                sawComputeRoute = true
                return nil
            }
        )
        #expect(result == nil)
        #expect(sawComputeRoute)
        #expect(route(packet: makePacket(), computedRoute: []) == nil)
    }
}
