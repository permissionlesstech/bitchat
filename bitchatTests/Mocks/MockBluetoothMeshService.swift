//
// MockBluetoothMeshService.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import MultipeerConnectivity
@testable import bitchat

class MockBluetoothMeshService: BluetoothMeshService {
    var sentMessages: [(message: BitchatMessage, packet: BitchatPacket)] = []
    var sentPackets: [BitchatPacket] = []
    var connectedPeers: Set<String> = []
    var messageDeliveryHandler: ((BitchatMessage) -> Void)?
    var packetDeliveryHandler: ((BitchatPacket) -> Void)?
    
    override init() {
        super.init()
    }
    
    func simulateConnectedPeer(_ peerID: String) {
        connectedPeers.insert(peerID)
        delegate?.bluetoothMeshService(self, didConnectToPeer: peerID, peerInfo: PeerInfo(
            mcPeerID: MCPeerID(displayName: peerID),
            peerID: peerID,
            nickname: "Test User",
            publicKey: nil,
            capabilities: PeerCapabilities(supportedProtocolVersions: [1])
        ))
    }
    
    func simulateDisconnectedPeer(_ peerID: String) {
        connectedPeers.remove(peerID)
        delegate?.bluetoothMeshService(self, didDisconnectFromPeer: peerID)
    }
    
    override func sendMessage(_ content: String, mentions: [String], to room: String? = nil, messageID: String? = nil, timestamp: Date? = nil) {
        let message = BitchatMessage(
            id: messageID ?? UUID().uuidString,
            sender: nickname,
            content: content,
            timestamp: timestamp ?? Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: peerID,
            mentions: mentions.isEmpty ? nil : mentions
        )
        
        if let payload = message.toBinaryPayload() {
            let packet = BitchatPacket(
                type: 0x01,
                senderID: peerID.data(using: .utf8)!,
                recipientID: nil,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload,
                signature: nil,
                ttl: 3
            )
            
            sentMessages.append((message, packet))
            sentPackets.append(packet)
            
            // Simulate local echo
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.bluetoothMeshService(self!, didReceiveMessage: message)
            }
            
            // Call delivery handler if set
            messageDeliveryHandler?(message)
        }
    }
    
    override func sendPrivateMessage(_ content: String, to recipientPeerID: String, recipientNickname: String, messageID: String? = nil) {
        let message = BitchatMessage(
            id: messageID ?? UUID().uuidString,
            sender: nickname,
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: recipientNickname,
            senderPeerID: peerID,
            mentions: nil
        )
        
        if let payload = message.toBinaryPayload() {
            let packet = BitchatPacket(
                type: 0x01,
                senderID: peerID.data(using: .utf8)!,
                recipientID: recipientPeerID.data(using: .utf8)!,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload,
                signature: nil,
                ttl: 3
            )
            
            sentMessages.append((message, packet))
            sentPackets.append(packet)
            
            // Simulate local echo
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.bluetoothMeshService(self!, didReceiveMessage: message)
            }
            
            // Call delivery handler if set
            messageDeliveryHandler?(message)
        }
    }
    
    func simulateIncomingMessage(_ message: BitchatMessage) {
        delegate?.bluetoothMeshService(self, didReceiveMessage: message)
    }
    
    func simulateIncomingPacket(_ packet: BitchatPacket) {
        // Process through the actual handling logic
        if let message = BitchatMessage.fromBinaryPayload(packet.payload) {
            delegate?.bluetoothMeshService(self, didReceiveMessage: message)
        }
        packetDeliveryHandler?(packet)
    }
    
    override func getConnectedPeers() -> [String] {
        return Array(connectedPeers)
    }
}