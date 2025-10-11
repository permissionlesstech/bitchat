//
// TestNetworkHelper.swift
// bitchatTests
//
// Extracted shared, mutable integration state for nodes and noise sessions.
// Keeps test containers nonmutating (Swift Testing-friendly).
//

import Foundation
import CryptoKit
@testable import bitchat

final class TestNetworkHelper {
    // Public, read-only views for tests; mutation only through methods
    var nodes: [String: MockBLEService] = [:]
    var noiseManagers: [String: NoiseSessionManager] = [:]
    let mockKeychain = MockKeychain()
    private let bus = MockBLEBus(autoFloodEnabled: true)
    
    // MARK: - Node/Manager management
    
    @discardableResult
    func createNode(_ name: String, peerID: PeerID) -> MockBLEService {
        let node = MockBLEService(bus: bus)
        node.myPeerID = peerID
        node.mockNickname = name
        nodes[name] = node
        
        // Create/replace Noise manager for this node
        let key = Curve25519.KeyAgreement.PrivateKey()
        noiseManagers[name] = NoiseSessionManager(localStaticKey: key, keychain: mockKeychain)
        return node
    }
    
    func getNode(_ name: String) -> MockBLEService? {
        nodes[name]
    }
    
    func getManager(_ name: String) -> NoiseSessionManager? {
        noiseManagers[name]
    }
    
    // MARK: - Topology
    
    func connect(_ a: String, _ b: String) {
        guard let n1 = nodes[a], let n2 = nodes[b] else { return }
        n1.simulateConnectedPeer(n2.peerID)
        n2.simulateConnectedPeer(n1.peerID)
    }
    
    func disconnect(_ a: String, _ b: String) {
        guard let n1 = nodes[a], let n2 = nodes[b] else { return }
        n1.simulateDisconnectedPeer(n2.peerID)
        n2.simulateDisconnectedPeer(n1.peerID)
    }
    
    func connectFullMesh() {
        let names = Array(nodes.keys)
        for i in 0..<names.count {
            for j in (i+1)..<names.count {
                connect(names[i], names[j])
            }
        }
    }
    
    // MARK: - Relay
    
    func setupRelay(_ nodeName: String, nextHops: [String]) {
        guard let node = nodes[nodeName] else { return }
        node.packetDeliveryHandler = { [weak self] packet in
            guard let self else { return }
            guard packet.ttl > 1 else { return }
            
            if let message = BitchatMessage(packet.payload) {
                guard message.senderPeerID != node.peerID else { return }
                
                let relayMessage = BitchatMessage(
                    id: message.id,
                    sender: message.sender,
                    content: message.content,
                    timestamp: message.timestamp,
                    isRelay: true,
                    originalSender: message.isRelay ? message.originalSender : message.sender,
                    isPrivate: message.isPrivate,
                    recipientNickname: message.recipientNickname,
                    senderPeerID: message.senderPeerID,
                    mentions: message.mentions
                )
                
                if let relayPayload = relayMessage.toBinaryPayload() {
                    let relayPacket = BitchatPacket(
                        type: packet.type,
                        senderID: packet.senderID,
                        recipientID: packet.recipientID,
                        timestamp: packet.timestamp,
                        payload: relayPayload,
                        signature: packet.signature,
                        ttl: packet.ttl - 1
                    )
                    
                    for hop in nextHops {
                        self.nodes[hop]?.simulateIncomingPacket(relayPacket)
                    }
                }
            }
        }
    }
    
    // MARK: - Noise sessions
    
    func establishNoiseSession(_ node1: String, _ node2: String) throws {
        guard let manager1 = noiseManagers[node1],
              let manager2 = noiseManagers[node2],
              let peer1ID = nodes[node1]?.peerID,
              let peer2ID = nodes[node2]?.peerID else { return }
        
        let msg1 = try manager1.initiateHandshake(with: peer2ID)
        let msg2 = try manager2.handleIncomingHandshake(from: peer1ID, message: msg1)!
        let msg3 = try manager1.handleIncomingHandshake(from: peer2ID, message: msg2)!
        _ = try manager2.handleIncomingHandshake(from: peer1ID, message: msg3)
    }
}

