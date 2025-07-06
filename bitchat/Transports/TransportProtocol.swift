//
// TransportProtocol.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

// MARK: - Transport Types

enum TransportType: String, CaseIterable {
    case bluetooth
    case wifiDirect
    case ultrasonic  // future
    case lora        // future
    
    var displayName: String {
        switch self {
        case .bluetooth: return "Bluetooth"
        case .wifiDirect: return "WiFi Direct"
        case .ultrasonic: return "Ultrasonic"
        case .lora: return "LoRa"
        }
    }
    
    var iconName: String {
        switch self {
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .wifiDirect: return "wifi"
        case .ultrasonic: return "waveform"
        case .lora: return "antenna.radiowaves.left.and.right"
        }
    }
}

// MARK: - Peer Information

struct PeerInfo {
    let peerID: String
    let nickname: String?
    let publicKey: Data?
    let transportTypes: Set<TransportType>
    let rssi: Int?
    let lastSeen: Date
    
    var displayName: String {
        return nickname ?? peerID
    }
}

// MARK: - Transport Capabilities

struct TransportCapabilities {
    let maxMessageSize: Int
    let averageBandwidth: Int  // bytes per second
    let typicalRange: Int      // meters
    let powerConsumption: PowerLevel
    
    enum PowerLevel: Int {
        case ultraLow = 1
        case low = 2
        case medium = 3
        case high = 4
        case veryHigh = 5
    }
}

// MARK: - Transport Delegate

protocol TransportDelegate: AnyObject {
    func transport(_ transport: TransportProtocol, didDiscoverPeer peer: PeerInfo)
    func transport(_ transport: TransportProtocol, didLosePeer peerID: String)
    func transport(_ transport: TransportProtocol, didReceivePacket packet: BitchatPacket, from peerID: String)
    func transport(_ transport: TransportProtocol, didUpdatePeer peer: PeerInfo)
    func transport(_ transport: TransportProtocol, didFailToSend messageID: String, to peerID: String, error: Error)
    func transport(_ transport: TransportProtocol, didChangeState isAvailable: Bool)
}

// MARK: - Transport Protocol

protocol TransportProtocol: AnyObject {
    // Properties
    var transportType: TransportType { get }
    var isAvailable: Bool { get }
    var currentPeers: [PeerInfo] { get }
    var capabilities: TransportCapabilities { get }
    var delegate: TransportDelegate? { get set }
    
    // Discovery
    func startDiscovery()
    func stopDiscovery()
    
    // Communication
    func send(_ packet: BitchatPacket, to peerID: String?) throws
    func broadcast(_ packet: BitchatPacket) throws
    
    // Connection Management
    func connect(to peerID: String) throws
    func disconnect(from peerID: String)
    
    // Lifecycle
    func start()
    func stop()
    
    // Optional: Transport-specific features
    func requestHighBandwidth(for peerID: String) -> Bool
    func getConnectionQuality(for peerID: String) -> ConnectionQuality?
}

// Default implementations
extension TransportProtocol {
    func requestHighBandwidth(for peerID: String) -> Bool {
        return false  // Most transports don't support this
    }
    
    func getConnectionQuality(for peerID: String) -> ConnectionQuality? {
        return nil  // Optional feature
    }
    
    func broadcast(_ packet: BitchatPacket) throws {
        // Default implementation: send to all peers
        for peer in currentPeers {
            try send(packet, to: peer.peerID)
        }
    }
}

// MARK: - Connection Quality

struct ConnectionQuality {
    let rssi: Int?
    let packetLoss: Double  // 0.0 to 1.0
    let averageLatency: TimeInterval  // seconds
    let bandwidth: Int  // bytes per second
    
    var qualityLevel: QualityLevel {
        if let rssi = rssi {
            switch rssi {
            case -50...0: return .excellent
            case -70..<(-50): return .good
            case -80..<(-70): return .fair
            default: return .poor
            }
        }
        return .unknown
    }
    
    enum QualityLevel {
        case excellent
        case good
        case fair
        case poor
        case unknown
    }
}

// MARK: - Transport Errors

enum TransportError: LocalizedError {
    case notAvailable
    case connectionFailed(String)
    case sendFailed(String)
    case messageTooLarge(maxSize: Int)
    case peerNotFound(String)
    case timeout
    case invalidState(String)
    
    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Transport is not available"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .sendFailed(let reason):
            return "Send failed: \(reason)"
        case .messageTooLarge(let maxSize):
            return "Message too large (max: \(maxSize) bytes)"
        case .peerNotFound(let peerID):
            return "Peer not found: \(peerID)"
        case .timeout:
            return "Operation timed out"
        case .invalidState(let state):
            return "Invalid state: \(state)"
        }
    }
}