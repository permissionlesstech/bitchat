//
// BLEServiceTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import CoreBluetooth
@testable import bitchat

struct BLEServiceTests {
    private let service: MockBLEService
    private let myUUID = UUID()
    private let bus = MockBLEBus()
    
    init() {
        service = MockBLEService.init(bus: bus)
        service.myPeerID = PeerID(str: myUUID.uuidString)
        service.mockNickname = "TestUser"
    }
    
    // MARK: - Basic Functionality Tests
    
    @Test func serviceInitialization() {
        #expect(service.myPeerID == PeerID(str: myUUID.uuidString))
        #expect(service.myNickname == "TestUser")
    }
    
    @Test func peerConnection() {
        let somePeerID = PeerID(str: UUID().uuidString)
        
        service.simulateConnectedPeer(somePeerID)
        #expect(service.isPeerConnected(somePeerID))
        #expect(service.getConnectedPeers().count == 1)
        
        service.simulateDisconnectedPeer(somePeerID)
        #expect(!service.isPeerConnected(somePeerID))
        #expect(service.getConnectedPeers().count == 0)
    }
    
    @Test func multiplePeerConnections() {
        let peerID1 = PeerID(str: UUID().uuidString)
        let peerID2 = PeerID(str: UUID().uuidString)
        let peerID3 = PeerID(str: UUID().uuidString)

        service.simulateConnectedPeer(peerID1)
        service.simulateConnectedPeer(peerID2)
        service.simulateConnectedPeer(peerID3)
        
        #expect(service.getConnectedPeers().count == 3)
        #expect(service.isPeerConnected(peerID1))
        #expect(service.isPeerConnected(peerID2))
        #expect(service.isPeerConnected(peerID3))
        
        service.simulateDisconnectedPeer(peerID2)
        #expect(service.getConnectedPeers().count == 2)
        #expect(!service.isPeerConnected(peerID2))
    }
    
    // MARK: - Message Sending Tests
    
    @Test func sendPublicMessage() async throws {
        try await confirmation { receivedPublicMessage in
            let delegate = MockBitchatDelegate { message in
                #expect(message.content == "Hello, world!")
                #expect(message.sender == "TestUser")
                #expect(!message.isPrivate)
                receivedPublicMessage()
            }
            service.delegate = delegate
            service.sendMessage("Hello, world!")
            
            // Allow async processing
            try await sleep(1.0)
        }
        #expect(service.sentMessages.count == 1)
    }
    
    @Test func sendPrivateMessage() async throws {
        try await confirmation { receivedPrivateMessage in
            let delegate = MockBitchatDelegate { message in
                #expect(message.content == "Secret message")
                #expect(message.sender == "TestUser")
                #expect(message.senderPeerID == PeerID(str: myUUID.uuidString))
                #expect(message.isPrivate)
                #expect(message.recipientNickname == "Bob")
                receivedPrivateMessage()
            }
            service.delegate = delegate
            service.sendPrivateMessage(
                "Secret message",
                to: PeerID(str: UUID().uuidString),
                recipientNickname: "Bob",
                messageID: "MSG123"
            )
            
            // Allow async processing
            try await sleep(1.0)
        }
        #expect(service.sentMessages.count == 1)
    }
    
    @Test func sendMessageWithMentions() async throws {
        try await confirmation { receivedMessageWithMentions in
            let delegate = MockBitchatDelegate { message in
                #expect(message.content == "@alice @bob check this out")
                #expect(message.mentions == ["alice", "bob"])
                receivedMessageWithMentions()
            }
            service.delegate = delegate
            service.sendMessage("@alice @bob check this out", mentions: ["alice", "bob"])
            
            // Allow async processing
            try await sleep(1.0)
        }
    }
    
    // MARK: - Message Reception Tests
    
    @Test func simulateIncomingMessage() async throws {
        try await confirmation { receiveMessage in
            let peerID = PeerID(str: UUID().uuidString)
            
            let delegate = MockBitchatDelegate { message in
                #expect(message.content == "Incoming message")
                #expect(message.sender == "RemoteUser")
                #expect(message.senderPeerID == peerID)
                receiveMessage()
            }
            service.delegate = delegate
            
            let incomingMessage = BitchatMessage(
                id: "MSG456",
                sender: "RemoteUser",
                content: "Incoming message",
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: peerID,
                mentions: nil
            )
            service.simulateIncomingMessage(incomingMessage)
            
            // Allow async processing
            try await sleep(1.0)
        }
    }
    
    @Test func simulateIncomingPacket() async throws {
        try await confirmation { processPacket in
            let peerID = PeerID(str: UUID().uuidString)
            
            let delegate = MockBitchatDelegate { message in
                #expect(message.content == "Packet message")
                #expect(message.senderPeerID == peerID)
                processPacket()
            }
            service.delegate = delegate
            
            let message = BitchatMessage(
                id: "MSG789",
                sender: "PacketSender",
                content: "Packet message",
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: peerID,
                mentions: nil
            )
            
            let payload = try #require(message.toBinaryPayload(), "Failed to create binary payload")
            
            let packet = BitchatPacket(
                type: 0x01,
                senderID: peerID.id.data(using: .utf8)!,
                recipientID: nil,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload,
                signature: nil,
                ttl: 3
            )
            
            service.simulateIncomingPacket(packet)
            
            // Allow async processing
            try await sleep(1.0)
        }
    }
    
    // MARK: - Peer Nickname Tests
    
    @Test func getPeerNicknames() {
        let peerID1 = PeerID(str: UUID().uuidString)
        let peerID2 = PeerID(str: UUID().uuidString)

        service.simulateConnectedPeer(peerID1)
        service.simulateConnectedPeer(peerID2)
        
        let nicknames = service.getPeerNicknames()
        #expect(nicknames.count == 2)
        #expect(nicknames[peerID1] == "MockPeer_\(peerID1)")
        #expect(nicknames[peerID2] == "MockPeer_\(peerID2)")
    }
    
    // MARK: - Service State Tests
    
    @Test func startStopServices() {
        service.startServices()
        service.stopServices()
        let somePeerID = PeerID(str: UUID().uuidString)
        service.simulateConnectedPeer(somePeerID)
        #expect(service.isPeerConnected(somePeerID))
    }
    
    // MARK: - Message Delivery Handler Tests
    
    @Test func messageDeliveryHandler() async throws {
        try await confirmation { deliveryHandler in
            service.packetDeliveryHandler = { packet in
                if let msg = BitchatMessage(packet.payload) {
                    #expect(msg.content == "Test delivery")
                    deliveryHandler()
                }
            }
            service.sendMessage("Test delivery")
            
            // Allow async processing
            try await sleep(1.0)
        }
    }
    
    @Test func packetDeliveryHandler() async throws {
        try await confirmation("Packet handler called") { packetHandler in
            let peerID = PeerID(str: UUID().uuidString)
            
            service.packetDeliveryHandler = { packet in
                #expect(packet.type == 0x01)
                #expect(packet.senderID == Data(peerID.id.utf8))
                packetHandler()
            }
            
            let message = BitchatMessage(
                id: "PKT123",
                sender: "TestSender",
                content: "Test packet",
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: peerID,
                mentions: nil
            )
            
            let payload = try #require(message.toBinaryPayload(), "Failed to create payload")
            
            let packet = BitchatPacket(
                type: 0x01,
                senderID: peerID.id.data(using: .utf8)!,
                recipientID: nil,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload,
                signature: nil,
                ttl: 3
            )
            
            service.simulateIncomingPacket(packet)
            
            // Allow async processing
            try await sleep(1.0)
        }
    }
}

// MARK: - Mock Delegate Helper

private final class MockBitchatDelegate: BitchatDelegate {
    private let messageHandler: (BitchatMessage) -> Void
    
    init(_ handler: @escaping (BitchatMessage) -> Void) {
        self.messageHandler = handler
    }
    
    func didReceiveMessage(_ message: BitchatMessage) {
        messageHandler(message)
    }
    
    func didConnectToPeer(_ peerID: PeerID) {}
    func didDisconnectFromPeer(_ peerID: PeerID) {}
    func didUpdatePeerList(_ peers: [PeerID]) {}
    func isFavorite(fingerprint: String) -> Bool { return false }
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {}
    func didReceiveNoisePayload(from peerID: PeerID, type: NoisePayloadType, payload: Data, timestamp: Date) {}
    func didUpdateBluetoothState(_ state: CBManagerState) {}
    func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?) {}
}
