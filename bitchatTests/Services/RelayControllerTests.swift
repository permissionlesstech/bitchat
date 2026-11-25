//
// RelayControllerTests.swift
// bitchatTests
//
// Tests for relay decision logic.
//

import BitFoundation
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

    @Test
    func broadcastRelayPolicyMatchesTrafficClasses() {
        let tracker = MeshTopologyTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        let origin = PeerID(str: "0100000000000000")
        let recipient = PeerID(str: "0200000000000000")
        let sig = Data(repeating: 0xAA, count: 64)

        tracker.updateNeighbors(for: origin.routingData, neighbors: [], at: now)

        func packet(
            _ type: MessageType,
            recipient: PeerID? = nil,
            signature: Data? = sig,
            payload: Data = Data([0x01])
        ) -> BitchatPacket {
            BitchatPacket(
                type: type.rawValue,
                senderID: origin.routingData ?? Data(),
                recipientID: recipient?.routingData,
                timestamp: 1_000,
                payload: payload,
                signature: signature,
                ttl: 6
            )
        }

        // 1-covered MPR classes
        #expect(RelayController.broadcastRelayPolicy(
            for: packet(.message),
            originPeerID: origin,
            forceConservativeRelay: false,
            sourceRouteFallback: false,
            topology: tracker,
            now: now
        ) == .mpr1Covered)
        #expect(RelayController.broadcastRelayPolicy(
            for: packet(.voiceFrame),
            originPeerID: origin,
            forceConservativeRelay: false,
            sourceRouteFallback: false,
            topology: tracker,
            now: now
        ) == .mpr1Covered)
        #expect(RelayController.broadcastRelayPolicy(
            for: packet(.announce),
            originPeerID: origin,
            forceConservativeRelay: false,
            sourceRouteFallback: false,
            topology: tracker,
            now: now
        ) == .mpr1Covered)

        // 2-covered MPR classes
        #expect(RelayController.broadcastRelayPolicy(
            for: packet(.fileTransfer),
            originPeerID: origin,
            forceConservativeRelay: false,
            sourceRouteFallback: false,
            topology: tracker,
            now: now
        ) == .mpr2Covered)
        #expect(RelayController.broadcastRelayPolicy(
            for: packet(.fragment, signature: sig),
            originPeerID: origin,
            forceConservativeRelay: false,
            sourceRouteFallback: false,
            topology: tracker,
            now: now
        ) == .mpr2Covered)

        // Unsigned or unauthenticated broadcast envelopes fail closed to prunedFlood
        #expect(RelayController.broadcastRelayPolicy(
            for: packet(.fragment, signature: nil),
            originPeerID: origin,
            forceConservativeRelay: false,
            sourceRouteFallback: false,
            topology: tracker,
            now: now
        ) == .prunedFlood)
        #expect(RelayController.broadcastRelayPolicy(
            for: packet(.fragment, signature: sig),
            originPeerID: origin,
            forceConservativeRelay: false,
            sourceRouteFallback: false,
            isAuthenticated: false,
            topology: tracker,
            now: now
        ) == .prunedFlood)
        #expect(RelayController.broadcastRelayPolicy(
            for: packet(.message, signature: sig),
            originPeerID: origin,
            forceConservativeRelay: false,
            sourceRouteFallback: false,
            isAuthenticated: false,
            topology: tracker,
            now: now
        ) == .prunedFlood)
        #expect(RelayController.broadcastRelayPolicy(
            for: packet(.announce, signature: sig),
            originPeerID: origin,
            forceConservativeRelay: false,
            sourceRouteFallback: false,
            isAuthenticated: false,
            topology: tracker,
            now: now
        ) == .conservativeFlood)
        #expect(RelayController.broadcastRelayPolicy(
            for: packet(.groupMessage, signature: nil),
            originPeerID: origin,
            forceConservativeRelay: false,
            sourceRouteFallback: false,
            topology: tracker,
            now: now
        ) == .prunedFlood)

        // Conservative flood classes
        #expect(RelayController.broadcastRelayPolicy(
            for: packet(.announce),
            originPeerID: origin,
            forceConservativeRelay: true,
            sourceRouteFallback: false,
            topology: tracker,
            now: now
        ) == .conservativeFlood)
        #expect(RelayController.broadcastRelayPolicy(
            for: packet(.leave),
            originPeerID: origin,
            forceConservativeRelay: false,
            sourceRouteFallback: false,
            topology: tracker,
            now: now
        ) == .conservativeFlood)
        #expect(RelayController.broadcastRelayPolicy(
            for: packet(.noiseHandshake, recipient: recipient),
            originPeerID: origin,
            forceConservativeRelay: false,
            sourceRouteFallback: false,
            topology: tracker,
            now: now
        ) == .conservativeFlood)
        #expect(RelayController.broadcastRelayPolicy(
            for: packet(.noiseEncrypted, recipient: recipient),
            originPeerID: origin,
            forceConservativeRelay: false,
            sourceRouteFallback: false,
            topology: tracker,
            now: now
        ) == .conservativeFlood)
        #expect(RelayController.broadcastRelayPolicy(
            for: packet(.message),
            originPeerID: origin,
            forceConservativeRelay: false,
            sourceRouteFallback: true,
            topology: tracker,
            now: now
        ) == .conservativeFlood)
    }

    @Test
    func evaluateBroadcastRelaySuppressesNonMPRAndPreservesFallbacks() {
        let tracker = MeshTopologyTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        let p = PeerID(str: "0100000000000000")
        let bridge = PeerID(str: "0200000000000000")
        let nonBridge = PeerID(str: "0300000000000000")
        let peer4 = PeerID(str: "0400000000000000")
        let w = PeerID(str: "0500000000000000")

        // Cluster {p, bridge, nonBridge, peer4} + bridge-w
        let adj: [PeerID: [PeerID]] = [
            p: [bridge, nonBridge, peer4],
            bridge: [p, nonBridge, peer4, w],
            nonBridge: [p, bridge, peer4],
            peer4: [p, bridge, nonBridge],
            w: [bridge]
        ]
        for (node, neighbors) in adj {
            tracker.updateNeighbors(for: node.routingData, neighbors: neighbors.compactMap(\.routingData), at: now)
        }

        let msg = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: p.routingData ?? Data(),
            recipientID: nil,
            timestamp: 1_000,
            payload: Data("hi".utf8),
            signature: Data(repeating: 0xBB, count: 64),
            ttl: 6
        )

        // Non-bridge in network of size 4 is suppressed.
        let suppressed = RelayController.evaluateBroadcastRelay(
            packet: msg,
            originPeerID: p,
            localPeerID: nonBridge,
            previousHopPeerID: p,
            networkSize: 4,
            directConnectedPeers: [p, bridge, peer4],
            hasUnidentifiedDirectLink: false,
            topology: tracker,
            now: now
        )
        #expect(!suppressed.shouldRelay)
        #expect(suppressed.isMPRGoverned)

        // Bridge is elected and relays with neighbor pruning enabled.
        let elected = RelayController.evaluateBroadcastRelay(
            packet: msg,
            originPeerID: p,
            localPeerID: bridge,
            previousHopPeerID: p,
            networkSize: 4,
            directConnectedPeers: [p, nonBridge, peer4, w],
            hasUnidentifiedDirectLink: false,
            topology: tracker,
            now: now
        )
        #expect(elected.shouldRelay)
        #expect(!elected.skipNeighborPruning)
        #expect(elected.isMPRGoverned)

        // Small network (<= 3) always relays even for non-bridge.
        let smallNet = RelayController.evaluateBroadcastRelay(
            packet: msg,
            originPeerID: p,
            localPeerID: nonBridge,
            previousHopPeerID: p,
            networkSize: 3,
            directConnectedPeers: [p, bridge, peer4],
            hasUnidentifiedDirectLink: false,
            topology: tracker,
            now: now
        )
        #expect(smallNet.shouldRelay)
        #expect(!smallNet.skipNeighborPruning)

        // Unknown previous hop relays and disables neighbor pruning.
        let unknownPrev = RelayController.evaluateBroadcastRelay(
            packet: msg,
            originPeerID: p,
            localPeerID: nonBridge,
            previousHopPeerID: nil,
            networkSize: 4,
            directConnectedPeers: [p, bridge, peer4],
            hasUnidentifiedDirectLink: false,
            topology: tracker,
            now: now
        )
        #expect(unknownPrev.shouldRelay)
        #expect(unknownPrev.skipNeighborPruning)
    }
}
