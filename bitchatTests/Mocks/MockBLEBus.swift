//
// MockBLEBus.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
@testable import bitchat

final class MockBLEBus {
    private var registry: [PeerID: MockBLEService] = [:]
    private var adjacency: [PeerID: Set<PeerID>] = [:]

    // Enable automatic flooding for public messages in integration tests only
    let autoFloodEnabled: Bool
    
    init(autoFloodEnabled: Bool = false) {
        self.autoFloodEnabled = autoFloodEnabled
    }

    func register(_ service: MockBLEService, for peerID: PeerID) {
        registry[peerID] = service
        if adjacency[peerID] == nil { adjacency[peerID] = [] }
    }

    func connect(_ a: PeerID, _ b: PeerID) {
        var setA = adjacency[a] ?? []
        setA.insert(b)
        adjacency[a] = setA
        var setB = adjacency[b] ?? []
        setB.insert(a)
        adjacency[b] = setB
    }

    func disconnect(_ a: PeerID, _ b: PeerID) {
        if var setA = adjacency[a] { setA.remove(b); adjacency[a] = setA }
        if var setB = adjacency[b] { setB.remove(a); adjacency[b] = setB }
    }

    func neighbors(of peerID: PeerID) -> [MockBLEService] {
        let ids = adjacency[peerID] ?? []
        let result = ids.compactMap { registry[$0] }
        return result
    }

    func isDirectNeighbor(_ a: PeerID, _ b: PeerID) -> Bool {
        let res = adjacency[a]?.contains(b) ?? false
        return res
    }

    func service(for peerID: PeerID) -> MockBLEService? {
        let svc = registry[peerID]
        return svc
    }
}
