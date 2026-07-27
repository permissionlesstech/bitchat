//
// LargeTopologyTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import BitFoundation // to avoid unnecessary public's
@testable import bitchat

/// Production-shaped topology tests: deep relay chains, larger partial meshes,
/// partitions, and churn.
///
/// Determinism: `MockBLEService` flooding is fully synchronous — `sendMessage`
/// recurses through `simulateIncomingPacket` across the whole connected
/// component before returning — so every test here sends, then asserts, with
/// no waits, sleeps, or confirmations needed.
struct LargeTopologyTests {

    private let helper = TestNetworkHelper()

    /// content -> receiver name -> delivery count.
    /// Delivery in the mock harness is single-threaded and synchronous, so
    /// plain (unlocked) mutation is safe here.
    private final class DeliveryLog {
        private(set) var counts: [String: [String: Int]] = [:]
        func record(receiver: String, content: String) {
            counts[content, default: [:]][receiver, default: 0] += 1
        }
        func deliveries(of content: String) -> [String: Int] {
            counts[content] ?? [:]
        }
    }

    private func makeNodes(_ names: [String]) {
        for name in names {
            helper.createNode(name, peerID: PeerID(str: UUID().uuidString))
        }
    }

    /// Installs a counting message handler on every node. Local echo does not
    /// trigger `messageDeliveryHandler`, so the sender of a broadcast records
    /// no delivery for its own message.
    private func installDeliveryLog() -> DeliveryLog {
        let log = DeliveryLog()
        for (name, node) in helper.nodes {
            node.messageDeliveryHandler = { message in
                log.record(receiver: name, content: message.content)
            }
        }
        return log
    }

    // MARK: - Deep chain

    @Test func deepChainBroadcastTraversesAllHopsWithTTLDecay() {
        // A - B - C - D - E - F - G - H (7 hops end to end)
        let chain = ["A", "B", "C", "D", "E", "F", "G", "H"]
        makeNodes(chain)
        for i in 0..<(chain.count - 1) {
            helper.connect(chain[i], chain[i + 1])
        }

        let log = installDeliveryLog()

        // Record the highest TTL each node observes for the broadcast. The
        // shortest-path arrival carries the highest TTL (back-floods from
        // further down the chain have decayed further), and unlike
        // "first handler call" this is independent of recursion order — the
        // mock invokes packetDeliveryHandler after its recursive flood, so
        // innermost calls fire first.
        var maxSeenTTL: [String: UInt8] = [:]
        for name in chain.dropFirst() {
            helper.nodes[name]!.packetDeliveryHandler = { packet in
                if let message = BitchatMessage(packet.payload),
                   message.content == "deep chain probe" {
                    maxSeenTTL[name] = max(maxSeenTTL[name] ?? 0, packet.ttl)
                }
            }
        }

        helper.nodes["A"]!.sendMessage("deep chain probe")

        // Reachability: the broadcast relays across all 7 hops and lands
        // exactly once at every other node (seenMessageIDs dedup).
        let deliveries = log.deliveries(of: "deep chain probe")
        for name in chain.dropFirst() {
            #expect(deliveries[name] == 1, "\(name) should receive the broadcast exactly once")
        }
        #expect(deliveries["A"] == nil, "sender must not receive its own broadcast")

        // TTL-modeling gap: the mock decrements and clamps TTL while flooding,
        // but it intentionally does NOT stop relaying when TTL reaches 0 —
        // MockBLEService floods the entire connected component and relies on
        // seenMessageIDs dedup (see the comment in simulateIncomingPacket).
        // Production BLEService enforces TTL and drops packets at 0 (max 7
        // hops), so this 7-hop chain only succeeds end to end because the mock
        // does not enforce TTL. We therefore assert decay and clamping here,
        // not enforcement.
        let initialTTL = helper.nodes["A"]!.sentPackets.last!.ttl
        var previousTTL = initialTTL
        for (hop, name) in chain.dropFirst().enumerated() {
            // The first hop carries the original TTL (sendMessage delivers the
            // packet unmodified); each subsequent relay decrements, clamped at 0.
            let expected = initialTTL > UInt8(hop) ? initialTTL - UInt8(hop) : 0
            let observed = maxSeenTTL[name]
            #expect(observed == expected, "\(name) expected shortest-path TTL \(expected), got \(String(describing: observed))")
            if let observed {
                #expect(observed <= initialTTL, "TTL must never exceed the initial TTL")
                #expect(observed <= previousTTL, "TTL must be non-increasing along the chain")
                previousTTL = observed
            }
        }
    }

    // MARK: - Larger partial mesh

    @Test func partialMeshBroadcastReachesAllExactlyOnce() {
        // 14 peers in a ring with chord edges: redundant paths create cycles,
        // so duplicate suppression (seenMessageIDs) is genuinely exercised.
        let names = (0..<14).map { String(format: "M%02d", $0) }
        makeNodes(names)
        for i in 0..<names.count {
            helper.connect(names[i], names[(i + 1) % names.count])
        }
        for i in [0, 3, 6, 9] {
            helper.connect(names[i], names[(i + 5) % names.count])
        }

        let log = installDeliveryLog()
        helper.nodes[names[0]]!.sendMessage("mesh broadcast")

        let deliveries = log.deliveries(of: "mesh broadcast")
        for name in names.dropFirst() {
            #expect(deliveries[name] == 1, "\(name) should receive exactly once despite redundant paths, got \(String(describing: deliveries[name]))")
        }
        #expect(deliveries[names[0]] == nil, "sender must not receive its own broadcast")
    }

    // MARK: - Partition and heal

    @Test func partitionIsolatesComponentsAndBridgeHeals() {
        // Two 5-node components, each with a redundant internal edge.
        let names = (0..<10).map { "P\($0)" }
        makeNodes(names)
        for i in 0..<4 { helper.connect("P\(i)", "P\(i + 1)") }
        helper.connect("P0", "P2")
        for i in 5..<9 { helper.connect("P\(i)", "P\(i + 1)") }
        helper.connect("P7", "P9")

        let log = installDeliveryLog()

        // While partitioned, nothing crosses.
        helper.nodes["P0"]!.sendMessage("pre-heal")
        var deliveries = log.deliveries(of: "pre-heal")
        for i in 1...4 { #expect(deliveries["P\(i)"] == 1, "P\(i) is in the sender's component") }
        for i in 5...9 { #expect(deliveries["P\(i)"] == nil, "P\(i) must not receive across the partition") }

        // Heal with a single bridge edge; newly sent messages flow across.
        helper.connect("P4", "P5")
        helper.nodes["P0"]!.sendMessage("post-heal")
        deliveries = log.deliveries(of: "post-heal")
        for i in 1...9 { #expect(deliveries["P\(i)"] == 1, "P\(i) should receive after the bridge heals the partition") }

        // The harness has no store-and-forward: the pre-partition message is
        // not retroactively delivered once the bridge appears.
        let preHeal = log.deliveries(of: "pre-heal")
        for i in 5...9 { #expect(preHeal["P\(i)"] == nil, "no store-and-forward of pre-partition messages") }
    }

    // MARK: - Churn

    @Test func churnDeliversToCurrentlyConnectedComponentOnly() {
        // 10-peer ring, then repeatedly mutate the topology between broadcasts.
        let names = (0..<10).map { "C\($0)" }
        makeNodes(names)
        for i in 0..<10 { helper.connect("C\(i)", "C\((i + 1) % 10)") }

        let log = installDeliveryLog()

        // Round 1: cut the ring in two places ->
        // components {C8, C9, C0, C1, C2} and {C3, C4, C5, C6, C7}.
        helper.disconnect("C2", "C3")
        helper.disconnect("C7", "C8")
        helper.nodes["C0"]!.sendMessage("split round")
        var deliveries = log.deliveries(of: "split round")
        for name in ["C1", "C2", "C8", "C9"] {
            #expect(deliveries[name] == 1, "\(name) is in C0's component and should receive exactly once")
        }
        for i in 3...7 { #expect(deliveries["C\(i)"] == nil, "C\(i) is in the other component") }

        // Round 2: restore the ring; a broadcast from the far side reaches all.
        helper.connect("C2", "C3")
        helper.connect("C7", "C8")
        helper.nodes["C5"]!.sendMessage("healed round")
        deliveries = log.deliveries(of: "healed round")
        for name in names where name != "C5" {
            #expect(deliveries[name] == 1, "\(name) should receive exactly once after the ring heals")
        }
        #expect(deliveries["C5"] == nil, "sender must not receive its own broadcast")

        // Round 3: fully isolate C9; everyone else still receives.
        helper.disconnect("C8", "C9")
        helper.disconnect("C9", "C0")
        helper.nodes["C0"]!.sendMessage("isolated round")
        deliveries = log.deliveries(of: "isolated round")
        for i in 1...8 { #expect(deliveries["C\(i)"] == 1, "C\(i) remains connected and should receive") }
        #expect(deliveries["C9"] == nil, "isolated node must not receive")

        // Round 4: rejoin C9; a broadcast from the rejoined node reaches all.
        helper.connect("C9", "C0")
        helper.nodes["C9"]!.sendMessage("rejoined round")
        deliveries = log.deliveries(of: "rejoined round")
        for i in 0...8 { #expect(deliveries["C\(i)"] == 1, "C\(i) should receive from the rejoined node") }
        #expect(deliveries["C9"] == nil, "sender must not receive its own broadcast")
    }
}
