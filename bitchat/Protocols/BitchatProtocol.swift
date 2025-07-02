import Foundation
import CryptoKit

enum MessageType: UInt8 {
    case handshake = 0x01
    case message = 0x02
    case ack = 0x03
    case relay = 0x04
    case announce = 0x05
    case keyExchange = 0x06
    case leave = 0x07
    case privateMessage = 0x08
}

struct BitchatPacket: Codable {
    let version: UInt8
    let type: UInt8
    let senderID: Data
    let recipientID: Data?
    let timestamp: UInt64
    let payload: Data
    let signature: Data?
    var ttl: UInt8
    
    init(type: UInt8, senderID: Data, recipientID: Data?, timestamp: UInt64, payload: Data, signature: Data?, ttl: UInt8) {
        self.version = 1
        self.type = type
        self.senderID = senderID
        self.recipientID = recipientID
        self.timestamp = timestamp
        self.payload = payload
        self.signature = signature
        self.ttl = ttl
    }
    
    var data: Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func from(_ data: Data) -> BitchatPacket? {
        try? JSONDecoder().decode(BitchatPacket.self, from: data)
    }
}

struct BitchatMessage: Codable, Equatable {
    let id: String
    let sender: String
    let content: String
    let timestamp: Date
    let isRelay: Bool
    let originalSender: String?
    let isPrivate: Bool
    let recipientNickname: String?
    let senderPeerID: String?
    
    init(sender: String, content: String, timestamp: Date, isRelay: Bool, originalSender: String? = nil, isPrivate: Bool = false, recipientNickname: String? = nil, senderPeerID: String? = nil) {
        self.id = UUID().uuidString
        self.sender = sender
        self.content = content
        self.timestamp = timestamp
        self.isRelay = isRelay
        self.originalSender = originalSender
        self.isPrivate = isPrivate
        self.recipientNickname = recipientNickname
        self.senderPeerID = senderPeerID
    }
}

protocol BitchatDelegate: AnyObject {
    func didReceiveMessage(_ message: BitchatMessage)
    func didConnectToPeer(_ peerID: String)
    func didDisconnectFromPeer(_ peerID: String)
    func didUpdatePeerList(_ peers: [String])
}