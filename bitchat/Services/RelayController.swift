//
// RelayController.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

// RelayDecision encapsulates a single relay scheduling choice.
struct RelayDecision {
    let shouldRelay: Bool
    let newTTL: UInt8
    let delayMs: Int
}

/// Traffic-class-aware broadcast relay policy.
enum BroadcastRelayPolicy: Equatable {
    case mpr1Covered
    case mpr2Covered
    case prunedFlood
    case conservativeFlood
}

/// Outcome of deterministic MPR / broadcast-policy evaluation.
struct BroadcastRelayDecision: Equatable {
    let shouldRelay: Bool
    let skipNeighborPruning: Bool
    let isMPRGoverned: Bool
    let reason: String
}

// RelayController centralizes flood control and deterministic MPR policy for relays.
struct RelayController {
    static func decide(ttl: UInt8,
                       senderIsSelf: Bool,
                       recipientIsSelf: Bool = false,
                       isEncrypted _: Bool,
                       isDirectedEncrypted: Bool,
                       isFragment: Bool,
                       isDirectedFragment: Bool,
                       isHandshake: Bool,
                       isAnnounce: Bool,
                       isRequestSync: Bool = false,
                       isUrgentBoardPost: Bool = false,
                       isVoiceFrame: Bool = false,
                       degree: Int,
                       highDegreeThreshold: Int) -> RelayDecision {
        let ttlCap = min(ttl, TransportConfig.messageTTLDefault)

        // REQUEST_SYNC is link-local: never relay it, even when a peer crafts
        // one with TTL headroom to turn every reachable node into a responder.
        if isRequestSync {
            return RelayDecision(shouldRelay: false, newTTL: ttlCap, delayMs: 0)
        }

        // Suppress obvious non-relays
        if ttlCap <= 1 || senderIsSelf || recipientIsSelf {
            return RelayDecision(shouldRelay: false, newTTL: ttlCap, delayMs: 0)
        }

        // For session-critical or directed traffic, be deterministic and reliable
        if isHandshake || isDirectedFragment || isDirectedEncrypted {
            // Always relay with no TTL cap for these types
            let newTTL = ttlCap &- 1
            // Slight jitter to desynchronize without adding too much latency
            // Tighter for faster multi-hop handshakes and directed DMs
            let delayRange: ClosedRange<Int> = isHandshake ? 10...35 : 20...60
            let delayMs = Int.random(in: delayRange)
            return RelayDecision(shouldRelay: true, newTTL: newTTL, delayMs: delayMs)
        }

        // Live voice floods with the fragment policy: the dense clamp
        // contains the sustained ~15 pkt/s per-talker stream, and the tight
        // jitter window keeps per-hop latency inside the receiver's ~350 ms
        // jitter buffer across multi-hop paths.
        if isFragment || isVoiceFrame {
            // Dense graphs clamp harder to contain full-fanout fragment floods;
            // sparse graphs get full depth so media reaches as far as text.
            let fragmentCap = degree >= highDegreeThreshold
                ? TransportConfig.bleFragmentRelayTtlCapDense
                : TransportConfig.bleFragmentRelayTtlCap
            let ttlLimit = min(ttlCap, fragmentCap)
            guard ttlLimit > 1 else {
                return RelayDecision(shouldRelay: false, newTTL: ttlLimit, delayMs: 0)
            }
            let newTTL = ttlLimit &- 1
            let delayMs = Int.random(in: TransportConfig.bleFragmentRelayMinDelayMs...TransportConfig.bleFragmentRelayMaxDelayMs)
            return RelayDecision(shouldRelay: true, newTTL: newTTL, delayMs: delayMs)
        }

        // TTL clamping for broadcast
        // - Dense graphs: keep lower but still allow multi-hop bridging
        // - Thin chains (degree <= 2): every hop counts and flood cost is
        //   minimal, so relay at full incoming depth
        // - Announces (and urgent board posts) get a bit more headroom
        let ttlLimit: UInt8 = {
            if degree >= highDegreeThreshold {
                return max(UInt8(2), min(ttlCap, UInt8(5)))
            }
            if degree <= 2 {
                return ttlCap
            }
            let preferred = UInt8((isAnnounce || isUrgentBoardPost) ? 7 : 6)
            return max(UInt8(2), min(ttlCap, preferred))
        }()
        let newTTL = ttlLimit &- 1

        // Wider jitter window to allow duplicate suppression to win more often
        // For sparse graphs (<=2), relay quickly to avoid cancellation races
        let delayMs: Int
        switch degree {
        case 0...2: delayMs = Int.random(in: 10...40)
        case 3...5: delayMs = Int.random(in: 60...150)
        case 6...9: delayMs = Int.random(in: 80...180)
        default:    delayMs = Int.random(in: 100...220)
        }
        return RelayDecision(shouldRelay: true, newTTL: newTTL, delayMs: delayMs)
    }

    // MARK: - Traffic-Class-Aware MPR Relay Policy

    /// Determines the broadcast relay policy for a packet, in parity with
    /// Android's `PacketRelayManager.relayPolicyFor`.
    static func broadcastRelayPolicy(
        for packet: BitchatPacket,
        originPeerID: PeerID,
        forceConservativeRelay: Bool,
        sourceRouteFallback: Bool,
        topology: MeshTopologyTracker,
        edgeMaxAge: TimeInterval = TransportConfig.bleMprEdgeMaxAgeSeconds,
        now: Date = Date()
    ) -> BroadcastRelayPolicy {
        if sourceRouteFallback {
            return .conservativeFlood
        }

        let isBroadcast = BLEPacketFreshnessPolicy.isBroadcastRecipient(packet.recipientID)
        guard let messageType = MessageType(rawValue: packet.type) else {
            return .conservativeFlood
        }

        switch messageType {
        case .voiceFrame:
            return isBroadcast ? .mpr1Covered : .conservativeFlood

        case .message:
            return isBroadcast ? .mpr1Covered : .conservativeFlood

        case .fragment:
            guard isBroadcast else { return .conservativeFlood }
            // Unsigned legacy/v1 fragment envelopes cannot be cryptographically
            // re-authenticated on duplicate ingress, so fail closed to
            // neighbor-pruned relaying rather than irreversibly MPR-suppressing
            // on first arrival.
            return packet.signature != nil ? .mpr2Covered : .prunedFlood

        case .fileTransfer:
            return isBroadcast ? .mpr2Covered : .conservativeFlood

        case .announce:
            if forceConservativeRelay || !topology.isFreshAnnouncement(for: originPeerID, maxAge: edgeMaxAge, now: now) {
                return .conservativeFlood
            }
            return .mpr1Covered

        case .boardPost:
            guard isBroadcast else { return .conservativeFlood }
            return BoardWire.urgentFlag(in: packet.payload) ? .conservativeFlood : .mpr1Covered

        case .groupMessage:
            // Sealed group messages have an unsigned outer envelope (authenticated
            // inside ChaChaPoly only by group members), so non-member relays
            // cannot re-authenticate duplicates; use neighbor-pruned relaying.
            return isBroadcast ? .prunedFlood : .conservativeFlood

        case .prekeyBundle:
            guard isBroadcast else { return .conservativeFlood }
            return packet.signature != nil ? .mpr1Covered : .prunedFlood

        case .leave,
             .noiseHandshake,
             .noiseEncrypted,
             .requestSync,
             .courierEnvelope,
             .ping,
             .pong,
             .nostrCarrier,
             .announceV2:
            return .conservativeFlood
        }
    }

    /// Evaluates whether the local node should relay a broadcast packet under
    /// deterministic 2-hop MPR hub selection and mixed/moving-mesh fail-safes.
    static func evaluateBroadcastRelay(
        packet: BitchatPacket,
        originPeerID: PeerID,
        localPeerID: PeerID,
        previousHopPeerID: PeerID?,
        networkSize: Int,
        directConnectedPeers: Set<PeerID>,
        hasUnidentifiedDirectLink: Bool,
        forceConservativeRelay: Bool = false,
        sourceRouteFallback: Bool = false,
        topology: MeshTopologyTracker,
        smallNetworkThreshold: Int = TransportConfig.bleMprSmallNetworkRelayThreshold,
        edgeMaxAge: TimeInterval = TransportConfig.bleMprEdgeMaxAgeSeconds,
        now: Date = Date()
    ) -> BroadcastRelayDecision {
        let policy = broadcastRelayPolicy(
            for: packet,
            originPeerID: originPeerID,
            forceConservativeRelay: forceConservativeRelay,
            sourceRouteFallback: sourceRouteFallback,
            topology: topology,
            edgeMaxAge: edgeMaxAge,
            now: now
        )

        if policy == .conservativeFlood {
            return BroadcastRelayDecision(
                shouldRelay: true,
                skipNeighborPruning: true,
                isMPRGoverned: false,
                reason: sourceRouteFallback ? "source-route-fallback" : "conservative-policy"
            )
        }

        let previousHopMissingOrStale: Bool = {
            guard let previousHopPeerID, !previousHopPeerID.isEmpty else { return true }
            return !topology.isFreshAnnouncement(for: previousHopPeerID, maxAge: edgeMaxAge, now: now)
        }()

        if policy == .prunedFlood {
            return BroadcastRelayDecision(
                shouldRelay: true,
                skipNeighborPruning: previousHopMissingOrStale,
                isMPRGoverned: false,
                reason: "pruned-flood"
            )
        }

        // Small networks always relay to preserve connectivity while still
        // guarding neighbor pruning on a fresh previous-hop graph.
        if networkSize <= smallNetworkThreshold {
            return BroadcastRelayDecision(
                shouldRelay: true,
                skipNeighborPruning: previousHopMissingOrStale,
                isMPRGoverned: false,
                reason: "small-network(\(networkSize))"
            )
        }

        // Unknown previous hop cannot safely compute N1(P)/N2(P) or prune neighbors.
        guard let previousHopPeerID, !previousHopPeerID.isEmpty else {
            return BroadcastRelayDecision(
                shouldRelay: true,
                skipNeighborPruning: true,
                isMPRGoverned: false,
                reason: "unknown-previous-hop"
            )
        }

        let coverageK = (policy == .mpr2Covered) ? 2 : 1
        let mprDecision = MPRSelector.evaluateRelay(
            myPeerID: localPeerID,
            previousHopPeerID: previousHopPeerID,
            originPeerID: originPeerID,
            topology: topology,
            directConnectedNeighbors: directConnectedPeers,
            hasUnidentifiedDirectLink: hasUnidentifiedDirectLink,
            coverageK: coverageK,
            maxAge: edgeMaxAge,
            now: now
        )

        return BroadcastRelayDecision(
            shouldRelay: mprDecision.shouldRelay,
            skipNeighborPruning: mprDecision.reason == .staleOrMissingGraph,
            isMPRGoverned: mprDecision.reason != .staleOrMissingGraph,
            reason: "mpr(k=\(coverageK)):\(mprDecision.reason)"
        )
    }
}
