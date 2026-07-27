//
// RelayControllerTests.swift
// bitchatTests
//
// Tests for relay decision logic.
//

import Testing
import Foundation
@testable import bitchat

struct RelayControllerTests {

    @Test
    func ttlOne_doesNotRelay() async {
        let decision = RelayController.decide(
            ttl: 1,
            senderIsSelf: false,
            isEncrypted: false,
            isDirectedEncrypted: false,
            isFragment: false,
            isDirectedFragment: false,
            isHandshake: false,
            isAnnounce: false,
            degree: 0,
            highDegreeThreshold: TransportConfig.bleHighDegreeThreshold
        )

        #expect(!decision.shouldRelay)
        #expect(decision.newTTL == 1)
    }

    @Test
    func handshake_alwaysRelaysWithTTLDecrement() async {
        let decision = RelayController.decide(
            ttl: 3,
            senderIsSelf: false,
            isEncrypted: false,
            isDirectedEncrypted: false,
            isFragment: false,
            isDirectedFragment: false,
            isHandshake: true,
            isAnnounce: false,
            degree: 3,
            highDegreeThreshold: TransportConfig.bleHighDegreeThreshold
        )

        #expect(decision.shouldRelay)
        #expect(decision.newTTL == 2)
        #expect(decision.delayMs >= 10 && decision.delayMs <= 35)
    }

    @Test
    func localRecipientDoesNotRelayDirectedTraffic() async {
        let decision = RelayController.decide(
            ttl: 7,
            senderIsSelf: false,
            recipientIsSelf: true,
            isEncrypted: true,
            isDirectedEncrypted: true,
            isFragment: false,
            isDirectedFragment: false,
            isHandshake: false,
            isAnnounce: false,
            degree: 3,
            highDegreeThreshold: TransportConfig.bleHighDegreeThreshold
        )

        #expect(!decision.shouldRelay)
        #expect(decision.newTTL == 7)
    }

    @Test
    func fragment_relaysWithFragmentCap() async {
        let decision = RelayController.decide(
            ttl: 10,
            senderIsSelf: false,
            isEncrypted: false,
            isDirectedEncrypted: false,
            isFragment: true,
            isDirectedFragment: false,
            isHandshake: false,
            isAnnounce: false,
            degree: 3,
            highDegreeThreshold: TransportConfig.bleHighDegreeThreshold
        )

        let ttlCap = min(UInt8(10), TransportConfig.bleFragmentRelayTtlCap)
        let expected = ttlCap &- 1

        #expect(decision.shouldRelay)
        #expect(decision.newTTL == expected)
        #expect(decision.delayMs >= TransportConfig.bleFragmentRelayMinDelayMs)
        #expect(decision.delayMs <= TransportConfig.bleFragmentRelayMaxDelayMs)
    }

    @Test
    func sparseChain_relaysAtFullIncomingDepth() async {
        // Thin chains (degree <= 2) are exactly the topology that needs every
        // hop, so no clamp below the incoming TTL is applied.
        let decision = RelayController.decide(
            ttl: 7,
            senderIsSelf: false,
            isEncrypted: false,
            isDirectedEncrypted: false,
            isFragment: false,
            isDirectedFragment: false,
            isHandshake: false,
            isAnnounce: false,
            degree: 2,
            highDegreeThreshold: TransportConfig.bleHighDegreeThreshold
        )

        #expect(decision.shouldRelay)
        #expect(decision.newTTL == 6)
    }

    @Test
    func denseGraph_clampsFragmentTTLHarder() async {
        let decision = RelayController.decide(
            ttl: 10,
            senderIsSelf: false,
            isEncrypted: false,
            isDirectedEncrypted: false,
            isFragment: true,
            isDirectedFragment: false,
            isHandshake: false,
            isAnnounce: false,
            degree: TransportConfig.bleHighDegreeThreshold,
            highDegreeThreshold: TransportConfig.bleHighDegreeThreshold
        )

        #expect(decision.shouldRelay)
        #expect(decision.newTTL == TransportConfig.bleFragmentRelayTtlCapDense - 1)
    }

    @Test
    func voiceFrame_relaysWithFragmentPolicy() async {
        // Sparse graph: fragment cap, tight jitter (multi-hop latency must
        // stay inside the receiver's jitter buffer).
        let sparse = RelayController.decide(
            ttl: 7,
            senderIsSelf: false,
            isEncrypted: false,
            isDirectedEncrypted: false,
            isFragment: false,
            isDirectedFragment: false,
            isHandshake: false,
            isAnnounce: false,
            isVoiceFrame: true,
            degree: 3,
            highDegreeThreshold: TransportConfig.bleHighDegreeThreshold
        )
        #expect(sparse.shouldRelay)
        #expect(sparse.newTTL == min(UInt8(7), TransportConfig.bleFragmentRelayTtlCap) &- 1)
        #expect(sparse.delayMs >= TransportConfig.bleFragmentRelayMinDelayMs)
        #expect(sparse.delayMs <= TransportConfig.bleFragmentRelayMaxDelayMs)

        // Dense graph: harder clamp contains the sustained per-talker stream.
        let dense = RelayController.decide(
            ttl: 7,
            senderIsSelf: false,
            isEncrypted: false,
            isDirectedEncrypted: false,
            isFragment: false,
            isDirectedFragment: false,
            isHandshake: false,
            isAnnounce: false,
            isVoiceFrame: true,
            degree: TransportConfig.bleHighDegreeThreshold,
            highDegreeThreshold: TransportConfig.bleHighDegreeThreshold
        )
        #expect(dense.shouldRelay)
        #expect(dense.newTTL == TransportConfig.bleFragmentRelayTtlCapDense - 1)
    }

    @Test
    func requestSync_neverRelaysEvenWithTTLHeadroom() async {
        let decision = RelayController.decide(
            ttl: 7,
            senderIsSelf: false,
            isEncrypted: false,
            isDirectedEncrypted: false,
            isFragment: false,
            isDirectedFragment: false,
            isHandshake: false,
            isAnnounce: false,
            isRequestSync: true,
            degree: 3,
            highDegreeThreshold: TransportConfig.bleHighDegreeThreshold
        )

        #expect(!decision.shouldRelay)
    }

    @Test
    func denseGraph_capsTTL() async {
        let decision = RelayController.decide(
            ttl: 10,
            senderIsSelf: false,
            isEncrypted: false,
            isDirectedEncrypted: false,
            isFragment: false,
            isDirectedFragment: false,
            isHandshake: false,
            isAnnounce: false,
            degree: TransportConfig.bleHighDegreeThreshold,
            highDegreeThreshold: TransportConfig.bleHighDegreeThreshold
        )

        #expect(decision.shouldRelay)
        #expect(decision.newTTL == 4)
    }
}
