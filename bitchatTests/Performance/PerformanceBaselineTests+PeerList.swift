//
// PerformanceBaselineTests+PeerList.swift
// bitchatTests
//
// Mesh peer-list benchmarks at a busy-mesh size. Every verified announce
// delivered its own `.peerListUpdated`, and each delivery did O(N) main-actor
// work, so a crowd of N peers re-announcing every ~10 s cost O(N^2) per
// second. These guard the per-delivery costs that grew with N:
//
// - the sightings tally hashed every listed peer and wrote UserDefaults
//   once per peer per update, even for peers already counted today;
// - reachability recounted the registry's connected peers per lookup;
// - people-list rows rebuilt the private-chat dictionary per row;
// - each mesh color lookup rebuilt the palette seeds, so one people-sheet
//   render was O(N^2);
// - each roster rebuild hashed every noise key twice.
//
// How often an announce burst delivers updates is a count, not a CPU cost:
// the SimulatedMesh tests gate that.
//

import XCTest
import BitFoundation
@testable import bitchat

extension PerformanceBaselineTests {
    /// The mesh size at which per-update O(N) work became a main-thread
    /// problem once multiplied by the announce rate.
    private static let peerListPeers = 200

    // MARK: - Peer-list update

    /// One `.peerListUpdated` through the production entry point for a mesh
    /// whose peers were all seen before: the steady state, where nearly
    /// every announce comes from a peer already counted today.
    func testPeerListUpdate() {
        let fixture = PeerListPerfFixture(peers: Self.peerListPeers)
        let updatesPerPass = 20
        var samples: [TimeInterval] = []

        measure {
            fixture.drainMainQueue()
            let start = Date()
            for _ in 0..<updatesPerPass {
                fixture.viewModel.didReceiveTransportEvent(.peerListUpdated(fixture.peerIDs))
            }
            samples.append(Date().timeIntervalSince(start))
        }

        reportThroughput("peerList.update", samples: samples, operations: updatesPerPass, unit: "updates")
    }

    // MARK: - Registry reachability

    /// The peer-list handler's mesh filter (`isConnected || isReachable`
    /// over every listed peer) against the lock-backed transport registry.
    func testPeerRegistryReachability() {
        let store = BLEPeerRegistryStore()
        let now = Date()
        var ids: [PeerID] = []
        store.mutate { registry in
            for index in 0..<Self.peerListPeers {
                let key = PeerListPerfFixture.noiseKey(index)
                let peerID = PeerID(publicKey: key)
                ids.append(peerID)
                _ = registry.upsertVerifiedAnnounce(
                    peerID: peerID,
                    nickname: "peer\(index)",
                    noisePublicKey: key,
                    signingPublicKey: nil,
                    isConnected: index < PeerListPerfFixture.connectedPeers,
                    now: now
                )
            }
        }
        let rounds = 20
        var samples: [TimeInterval] = []

        measure {
            let start = Date()
            var reachable = 0
            for _ in 0..<rounds {
                reachable += ids.filter { store.isConnected($0) || store.isReachable($0, now: now) }.count
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertEqual(reachable, rounds * ids.count)
        }

        reportThroughput("peerRegistry.reachability", samples: samples, operations: rounds * ids.count, unit: "peers")
    }

    // MARK: - People-list rows

    /// One PeerListModel rebuild (every mesh, group and recent-chat row)
    /// with nothing unread: the common case.
    func testPeerListRefresh() {
        let fixture = PeerListPerfFixture(peers: Self.peerListPeers, dmThreads: 30)
        runPeerListRefreshBenchmark(fixture, name: "peerList.refresh")
    }

    /// The same rebuild with one unread conversation, so every row resolves
    /// its unread state in full.
    func testPeerListRefreshWithUnread() {
        let fixture = PeerListPerfFixture(peers: Self.peerListPeers, dmThreads: 30)
        fixture.viewModel.conversations.markUnread(.directPeer(fixture.peerIDs[0]))
        XCTAssertEqual(fixture.viewModel.unreadPrivateMessages.count, 1)
        runPeerListRefreshBenchmark(fixture, name: "peerList.refreshUnread")
    }

    private func runPeerListRefreshBenchmark(_ fixture: PeerListPerfFixture, name: String) {
        let rounds = 20
        var samples: [TimeInterval] = []

        measure {
            fixture.drainMainQueue()
            let start = Date()
            for _ in 0..<rounds {
                fixture.peerListModel.refreshNow()
            }
            samples.append(Date().timeIntervalSince(start))
        }

        XCTAssertEqual(fixture.peerListModel.meshRows.count, Self.peerListPeers)
        reportThroughput(name, samples: samples, operations: rounds, unit: "refreshes")
    }

    // MARK: - Mesh people-list colors

    /// One people-sheet render resolves a color for every mesh row.
    func testMeshPeopleListColors() {
        let fixture = PeerListPerfFixture(peers: 500)
        XCTAssertEqual(fixture.viewModel.allPeers.count, 500)
        let ids = fixture.peerIDs
        var samples: [TimeInterval] = []

        measure {
            let start = Date()
            for peerID in ids {
                _ = fixture.viewModel.colorForMeshPeer(id: peerID, isDark: true)
            }
            samples.append(Date().timeIntervalSince(start))
        }

        reportThroughput("mesh.peopleListColors", samples: samples, operations: ids.count, unit: "rows")
    }

    // MARK: - Roster rebuild

    /// One UnifiedPeerService rebuild from a mesh snapshot publish.
    func testPeerRosterRebuild() {
        let fixture = PeerListPerfFixture(peers: Self.peerListPeers)
        let service = fixture.viewModel.unifiedPeerService
        let snapshots = fixture.transport.currentPeerSnapshots()
        let rounds = 20
        var samples: [TimeInterval] = []

        measure {
            fixture.drainMainQueue()
            let start = Date()
            for _ in 0..<rounds {
                service.didUpdatePeerSnapshots(snapshots)
            }
            samples.append(Date().timeIntervalSince(start))
        }

        XCTAssertEqual(service.peers.count, Self.peerListPeers)
        reportThroughput("peers.rosterRebuild", samples: samples, operations: rounds, unit: "rebuilds")
    }
}

/// A real `ChatViewModel` (real identity manager) over a mock transport
/// listing `peers` mesh peers, with the feature models that observe peer
/// state attached and a realistic timeline: a full mesh channel plus DM
/// threads. Every peer has been counted once before the benchmark starts.
@MainActor
final class PeerListPerfFixture {
    static let connectedPeers = 8

    let viewModel: ChatViewModel
    let transport: MockTransport
    let tracker: MeshSightingsTracker
    let peerIDs: [PeerID]
    let peerListModel: PeerListModel
    let privateConversationModel: PrivateConversationModel
    // periphery:ignore - held so its peer-state subscriptions stay attached
    // while the benchmarks run, as in the app; nothing reads it.
    let verificationModel: VerificationModel
    private let suiteName: String

    /// A distinct 32-byte noise key per index (the index fills the first
    /// four bytes), so every fixture peer has its own peer ID.
    static func noiseKey(_ index: Int) -> Data {
        var key = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })
        for byte in 0..<4 {
            key[byte] = UInt8(truncatingIfNeeded: index >> (8 * byte))
        }
        return key
    }

    init(peers: Int, dmThreads: Int = 12, messagesPerThread: Int = 100) {
        let keychain = MockKeychain()
        suiteName = "PerformanceBaselineTests.peerList.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        transport = MockTransport()
        tracker = MeshSightingsTracker(defaults: defaults)
        let locationManager = LocationChannelManager(storage: defaults)
        viewModel = ChatViewModel(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: SecureIdentityStateManager(keychain),
            transport: transport,
            conversations: ConversationStore(),
            locationManager: locationManager,
            readReceiptsDefaults: defaults,
            meshSightings: tracker
        )
        Self.drainMainQueue()

        var ids: [PeerID] = []
        var snapshots: [TransportPeerSnapshot] = []
        let now = Date()
        for index in 0..<peers {
            let key = Self.noiseKey(index)
            let peerID = PeerID(publicKey: key)
            ids.append(peerID)
            transport.peerNicknames[peerID] = "peer\(index)"
            snapshots.append(TransportPeerSnapshot(
                peerID: peerID,
                nickname: "peer\(index)",
                isConnected: index < Self.connectedPeers,
                noisePublicKey: key,
                lastSeen: now
            ))
        }
        peerIDs = ids
        transport.connectedPeers = Set(ids.prefix(Self.connectedPeers))
        transport.reachablePeers = Set(ids.dropFirst(Self.connectedPeers))
        transport.updatePeerSnapshots(snapshots)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<TransportConfig.meshTimelineCap {
            _ = viewModel.conversations.append(BitchatMessage(
                id: "mesh-\(index)",
                sender: "peer\(index % peers)",
                content: "anyone near the station tonight? heading over in ten minutes",
                timestamp: base.addingTimeInterval(Double(index)),
                isRelay: false,
                senderPeerID: ids[index % peers]
            ), to: .mesh)
        }
        for thread in 0..<min(dmThreads, peers) {
            for index in 0..<messagesPerThread {
                _ = viewModel.conversations.append(BitchatMessage(
                    id: "dm-\(thread)-\(index)",
                    sender: index.isMultiple(of: 2) ? "peer\(thread)" : "me",
                    content: "see you at the north entrance",
                    timestamp: base.addingTimeInterval(Double(index)),
                    isRelay: false,
                    isPrivate: true,
                    recipientNickname: "me",
                    senderPeerID: ids[thread]
                ), to: .directPeer(ids[thread]))
            }
        }
        viewModel.isStartupPhase = false

        let locationChannelsModel = LocationChannelsModel(manager: locationManager)
        privateConversationModel = PrivateConversationModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: locationChannelsModel
        )
        verificationModel = VerificationModel(
            chatViewModel: viewModel,
            privateConversationModel: privateConversationModel
        )
        peerListModel = PeerListModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: locationChannelsModel
        )
        Self.drainMainQueue()

        // Every peer's first sighting happens once, outside the benchmark.
        viewModel.didReceiveTransportEvent(.peerListUpdated(peerIDs))
        Self.drainMainQueue()

        // Sanity: the benchmark must exercise the busy-mesh state it claims.
        XCTAssertEqual(Set(peerIDs).count, peers)
        XCTAssertEqual(tracker.todayCount, peers)
        XCTAssertEqual(viewModel.allPeers.count, peers)
        XCTAssertEqual(viewModel.connectedPeers.count, Self.connectedPeers)
        XCTAssertEqual(peerListModel.meshRows.count, peers)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
        // Removing the domain still leaves an empty plist behind.
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(
                at: library.appendingPathComponent("Preferences/\(suiteName).plist")
            )
        }
    }

    func drainMainQueue() { Self.drainMainQueue() }

    /// Runs the main run loop until it has been idle for a few polls.
    static func drainMainQueue() {
        var idlePolls = 0
        let deadline = Date().addingTimeInterval(10)
        while idlePolls < 3, Date() < deadline {
            if CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.001, true) == .handledSource {
                idlePolls = 0
            } else {
                idlePolls += 1
            }
        }
    }
}
