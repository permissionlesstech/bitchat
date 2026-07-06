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

    private func decide(
        packet: BitchatPacket,
        isRecipientConnected: Bool = false,
        shouldAttemptRoute: Bool = true,
        computedRoute: [Data]? = nil
    ) -> BLESourceRouteOriginationPolicy.Decision {
        BLESourceRouteOriginationPolicy.decide(
            for: packet,
            to: recipient,
            localPeerIDData: localPeerIDData,
            isRecipientConnected: { _ in isRecipientConnected },
            shouldAttemptRoute: { _ in shouldAttemptRoute },
            computeRoute: { _ in computedRoute ?? [self.hop] }
        )
    }

    @Test func routesWhenAllGatesPass() {
        #expect(decide(packet: makePacket()) == .route([hop]))
    }

    @Test func relayedPacketNeverGetsRoute() {
        let relayed = makePacket(senderID: Data(hexString: "aabbccddeeff0011"))
        #expect(decide(packet: relayed) == .flood(.relayedNotOriginator))
    }

    @Test func broadcastRecipientNeverGetsRoute() {
        let broadcast = makePacket(recipientID: Data(repeating: 0xFF, count: 8))
        #expect(decide(packet: broadcast) == .flood(.broadcast))
        let noRecipient = makePacket(recipientID: nil)
        #expect(decide(packet: noRecipient) == .flood(.broadcast))
    }

    @Test func linkLocalTTLNeverGetsRoute() {
        // TTL 0/1 packets (e.g. REQUEST_SYNC) cannot traverse hops.
        #expect(decide(packet: makePacket(ttl: 0)) == .flood(.noTTLHeadroom))
        #expect(decide(packet: makePacket(ttl: 1)) == .flood(.noTTLHeadroom))
    }

    @Test func directlyConnectedRecipientNeverGetsRoute() {
        #expect(decide(packet: makePacket(), isRecipientConnected: true) == .flood(.recipientDirect))
    }

    @Test func suppressedRecipientFallsBackToFlood() {
        #expect(decide(packet: makePacket(), shouldAttemptRoute: false) == .flood(.routeSuppressed))
    }

    @Test func missingOrEmptyRouteFallsBackToFlood() {
        var sawComputeRoute = false
        let result = BLESourceRouteOriginationPolicy.decide(
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
        #expect(result == .flood(.noPath))
        #expect(sawComputeRoute)
        #expect(decide(packet: makePacket(), computedRoute: []) == .flood(.noPath))
    }
}
