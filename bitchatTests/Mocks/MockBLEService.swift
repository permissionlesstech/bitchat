//
// MockBLEService.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CoreBluetooth
@testable import bitchat

// Mock implementation that mimics BLEService behavior
class MockBLEService: NSObject {
    
    // MARK: - Properties matching BLEService
    
    weak var delegate: BitchatDelegate?
    var myPeerID: String = "MOCK1234"
    var myNickname: String = "MockUser"
    
    // Test-specific properties
    var sentMessages: [(message: BitchatMessage, packet: BitchatPacket)] = []
    var sentPackets: [BitchatPacket] = []
    var connectedPeers: Set<String> = []
    var messageDeliveryHandler: ((BitchatMessage) -> Void)?
    var packetDeliveryHandler: ((BitchatPacket) -> Void)?
    
    // Compatibility properties for old tests
    var mockNickname: String {
        get { return myNickname }
        set { myNickname = newValue }
    }
    
    var nickname: String {
        return myNickname
    }
    
    var peerID: String {
        return myPeerID
    }
    
    // MARK: - Initialization
    
    override init() {
        super.init()
    }
    
    // MARK: - Methods matching BLEService
    
    func setNickname(_ nickname: String) {
        self.myNickname = nickname
    }
    
    func startServices() {
        // Mock implementation - do nothing
    }
    
    func stopServices() {
        // Mock implementation - do nothing
    }
    
    func isPeerConnected(_ peerID: String) -> Bool {
        return connectedPeers.contains(peerID)
    }

    func peerNickname(peerID: String) -> String? {
        "MockPeer_\(peerID)"
    }

    func getPeerNicknames() -> [String: String] {
        var nicknames: [String: String] = [:]
        for peer in connectedPeers {
            nicknames[peer] = "MockPeer_\(peer)"
        }
        return nicknames
    }
    
    func getPeers() -> [String: String] {
        return getPeerNicknames()
    }
    
    func sendMessage(_ content: String, mentions: [String] = [], to recipientID: String? = nil, messageID: String? = nil, timestamp: Date? = nil) {
        let message = BitchatMessage(
            id: messageID ?? UUID().uuidString,
            sender: myNickname,
            content: content,
            timestamp: timestamp ?? Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: recipientID != nil,
            recipientNickname: nil,
            senderPeerID: myPeerID,
            mentions: mentions.isEmpty ? nil : mentions
        )
        
        if let payload = message.toBinaryPayload() {
            let packet = BitchatPacket(
                type: 0x01,
                senderID: myPeerID.data(using: .utf8)!,
                recipientID: recipientID?.data(using: .utf8),
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload,
                signature: nil,
                ttl: 3
            )
            
            sentMessages.append((message, packet))
            sentPackets.append(packet)
            
            // Simulate local echo
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didReceiveMessage(message)
            }
            
            // Call delivery handler if set
            messageDeliveryHandler?(message)
        }
    }
    
    func sendPrivateMessage(_ content: String, to recipientPeerID: String, recipientNickname: String, messageID: String) {
        let message = BitchatMessage(
            id: messageID,
            sender: myNickname,
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: recipientNickname,
            senderPeerID: myPeerID,
            mentions: nil
        )
        
        if let payload = message.toBinaryPayload() {
            let packet = BitchatPacket(
                type: 0x01,
                senderID: myPeerID.data(using: .utf8)!,
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
                self?.delegate?.didReceiveMessage(message)
            }
            
            // Call delivery handler if set
            messageDeliveryHandler?(message)
        }
    }
    
    func sendFavoriteNotification(to peerID: String, isFavorite: Bool) {
        // Mock implementation
    }
    
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: String) {
        // Mock implementation
    }
    
    func sendBroadcastAnnounce() {
        // Mock implementation
    }
    
    func getPeerFingerprint(_ peerID: String) -> String? {
        return nil
    }
    
    func getNoiseSessionState(for peerID: String) -> LazyHandshakeState {
        return .none
    }
    
    func triggerHandshake(with peerID: String) {
        // Mock implementation
    }
    
    func emergencyDisconnectAll() {
        connectedPeers.removeAll()
        delegate?.didUpdatePeerList([])
    }
    
    func getNoiseService() -> NoiseEncryptionService {
        return NoiseEncryptionService()
    }
    
    func getFingerprint(for peerID: String) -> String? {
        return nil
    }
    
    // MARK: - Test Helper Methods
    
    func simulateConnectedPeer(_ peerID: String) {
        connectedPeers.insert(peerID)
        delegate?.didConnectToPeer(peerID)
        delegate?.didUpdatePeerList(Array(connectedPeers))
    }
    
    func simulateDisconnectedPeer(_ peerID: String) {
        connectedPeers.remove(peerID)
        delegate?.didDisconnectFromPeer(peerID)
        delegate?.didUpdatePeerList(Array(connectedPeers))
    }
    
    func simulateIncomingMessage(_ message: BitchatMessage) {
        delegate?.didReceiveMessage(message)
    }
    
    func simulateIncomingPacket(_ packet: BitchatPacket) {
        // Process through the actual handling logic
        if let message = BitchatMessage.fromBinaryPayload(packet.payload) {
            delegate?.didReceiveMessage(message)
        }
        packetDeliveryHandler?(packet)
    }
    
    func getConnectedPeers() -> [String] {
        return Array(connectedPeers)
    }
    
    // MARK: - Compatibility methods for old tests
    
    func sendPrivateMessage(_ content: String, to recipientPeerID: String, recipientNickname: String, messageID: String? = nil) {
        sendPrivateMessage(content, to: recipientPeerID, recipientNickname: recipientNickname, messageID: messageID ?? UUID().uuidString)
    }
}

// Backward compatibility for older tests
typealias MockSimplifiedBluetoothService = MockBLEService
