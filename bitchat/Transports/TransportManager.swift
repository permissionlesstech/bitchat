//
// TransportManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Combine

// MARK: - Transport Manager

class TransportManager: ObservableObject {
    static let shared = TransportManager()
    
    // Published properties for UI binding
    @Published var availableTransports: Set<TransportType> = []
    @Published var activeTransports: Set<TransportType> = []
    @Published var allPeers: [PeerInfo] = []
    @Published var primaryTransport: TransportType = .bluetooth
    
    // Private properties
    private var transports: [TransportType: TransportProtocol] = [:]
    private var routingTable: [String: TransportType] = [:]  // peerID -> preferred transport
    private var peerTransports: [String: Set<TransportType>] = [:]  // peerID -> available transports
    private let transportQueue = DispatchQueue(label: "bitchat.transportManager", attributes: .concurrent)
    private var cancellables = Set<AnyCancellable>()
    
    // Delegate
    weak var delegate: BitchatDelegate?
    
    // Settings
    var enableWiFiDirect = false {
        didSet {
            if enableWiFiDirect {
                activateTransport(.wifiDirect)
            } else {
                deactivateTransport(.wifiDirect)
            }
        }
    }
    
    var autoSelectTransport = true
    var preferLowPower = true
    
    private init() {}
    
    // MARK: - Transport Management
    
    func register(_ transport: TransportProtocol) {
        transportQueue.async(flags: .barrier) {
            self.transports[transport.transportType] = transport
            transport.delegate = self
            
            DispatchQueue.main.async {
                self.availableTransports.insert(transport.transportType)
            }
        }
    }
    
    func unregister(_ transportType: TransportType) {
        transportQueue.async(flags: .barrier) {
            if let transport = self.transports[transportType] {
                transport.stop()
                self.transports.removeValue(forKey: transportType)
            }
            
            DispatchQueue.main.async {
                self.availableTransports.remove(transportType)
                self.activeTransports.remove(transportType)
            }
        }
    }
    
    func activateTransport(_ type: TransportType) {
        transportQueue.async {
            guard let transport = self.transports[type] else { return }
            
            transport.start()
            transport.startDiscovery()
            
            DispatchQueue.main.async {
                self.activeTransports.insert(type)
            }
        }
    }
    
    func deactivateTransport(_ type: TransportType) {
        transportQueue.async {
            guard let transport = self.transports[type] else { return }
            
            transport.stopDiscovery()
            transport.stop()
            
            DispatchQueue.main.async {
                self.activeTransports.remove(type)
            }
        }
    }
    
    // MARK: - Message Routing
    
    func send(_ packet: BitchatPacket, to peerID: String?) {
        transportQueue.async {
            if let peerID = peerID {
                // Unicast: select optimal transport for specific peer
                let transport = self.selectTransport(for: packet, to: peerID)
                do {
                    try transport.send(packet, to: peerID)
                } catch {
                    // Try fallback transport
                    if let fallback = self.getFallbackTransport(for: transport.transportType) {
                        try? fallback.send(packet, to: peerID)
                    }
                }
            } else {
                // Broadcast: use all active transports
                for transport in self.transports.values where self.activeTransports.contains(transport.transportType) {
                    try? transport.broadcast(packet)
                }
            }
        }
    }
    
    private func selectTransport(for packet: BitchatPacket, to peerID: String) -> TransportProtocol {
        // Check if we have a preferred transport for this peer
        if let preferredType = routingTable[peerID],
           let transport = transports[preferredType],
           transport.isAvailable {
            return transport
        }
        
        // Otherwise, use intelligent routing
        let messageSize = estimatePacketSize(packet)
        let batteryLevel = BatteryOptimizer.shared.batteryLevel
        
        // Get available transports for this peer
        let availableForPeer = peerTransports[peerID] ?? [.bluetooth]
        
        // Select based on criteria
        if autoSelectTransport {
            return selectOptimalTransport(
                messageSize: messageSize,
                batteryLevel: batteryLevel,
                availableTransports: availableForPeer
            )
        } else {
            // Use primary transport if available
            if availableForPeer.contains(primaryTransport),
               let transport = transports[primaryTransport] {
                return transport
            }
        }
        
        // Fallback to Bluetooth
        return transports[.bluetooth]!
    }
    
    private func selectOptimalTransport(
        messageSize: Int,
        batteryLevel: Float,
        availableTransports: Set<TransportType>
    ) -> TransportProtocol {
        // Large messages: prefer WiFi Direct if battery is good
        if messageSize > 10_000 && batteryLevel > 0.5 {
            if availableTransports.contains(.wifiDirect),
               let wifi = transports[.wifiDirect],
               wifi.isAvailable {
                return wifi
            }
        }
        
        // Small messages or low battery: prefer Bluetooth
        if messageSize < 1_000 || batteryLevel < 0.3 || preferLowPower {
            if let bluetooth = transports[.bluetooth],
               bluetooth.isAvailable {
                return bluetooth
            }
        }
        
        // Medium size, good battery: use faster transport if available
        if availableTransports.contains(.wifiDirect),
           let wifi = transports[.wifiDirect],
           wifi.isAvailable {
            return wifi
        }
        
        // Default to Bluetooth
        return transports[.bluetooth]!
    }
    
    private func estimatePacketSize(_ packet: BitchatPacket) -> Int {
        // Estimate packet size for routing decisions
        var size = 0
        
        // Base packet overhead
        size += 1  // version
        size += 1  // type
        size += packet.senderID.count
        if let recipientID = packet.recipientID {
            size += recipientID.count
        }
        size += 8  // timestamp
        size += 1  // ttl
        size += packet.payload.count
        if let signature = packet.signature {
            size += signature.count
        }
        
        // Add protocol overhead (~20%)
        return Int(Double(size) * 1.2)
    }
    
    private func getFallbackTransport(for type: TransportType) -> TransportProtocol? {
        // Define fallback chain
        switch type {
        case .wifiDirect:
            return transports[.bluetooth]
        case .bluetooth:
            return nil  // No fallback for Bluetooth
        case .ultrasonic:
            return transports[.bluetooth]
        case .lora:
            return transports[.bluetooth]
        }
    }
    
    // MARK: - Peer Management
    
    func updatePeerCapabilities(_ peerID: String, transports: Set<TransportType>) {
        transportQueue.async(flags: .barrier) {
            self.peerTransports[peerID] = transports
        }
    }
    
    func getPeerTransports(_ peerID: String) -> Set<TransportType> {
        transportQueue.sync {
            return peerTransports[peerID] ?? [.bluetooth]
        }
    }
    
    func setPreferredTransport(_ type: TransportType, for peerID: String) {
        transportQueue.async(flags: .barrier) {
            self.routingTable[peerID] = type
        }
    }
    
    // MARK: - Statistics
    
    func getTransportStatistics() -> TransportStatistics {
        var stats = TransportStatistics()
        
        transportQueue.sync {
            for (type, transport) in transports {
                stats.peerCounts[type] = transport.currentPeers.count
                stats.availability[type] = transport.isAvailable
            }
        }
        
        return stats
    }
}

// MARK: - Transport Delegate

extension TransportManager: TransportDelegate {
    func transport(_ transport: TransportProtocol, didDiscoverPeer peer: PeerInfo) {
        // Update peer transports
        transportQueue.async(flags: .barrier) {
            var transports = self.peerTransports[peer.peerID] ?? []
            transports.insert(transport.transportType)
            self.peerTransports[peer.peerID] = transports
        }
        
        // Update peer list
        DispatchQueue.main.async {
            if !self.allPeers.contains(where: { $0.peerID == peer.peerID }) {
                self.allPeers.append(peer)
            }
        }
        
        // Forward to delegate - use correct method
        if let nickname = peer.nickname {
            delegate?.didConnectToPeer(nickname)
        }
    }
    
    func transport(_ transport: TransportProtocol, didLosePeer peerID: String) {
        // Update peer transports
        transportQueue.async(flags: .barrier) {
            if var transports = self.peerTransports[peerID] {
                transports.remove(transport.transportType)
                if transports.isEmpty {
                    self.peerTransports.removeValue(forKey: peerID)
                    self.routingTable.removeValue(forKey: peerID)
                } else {
                    self.peerTransports[peerID] = transports
                }
            }
        }
        
        // Update peer list if no transports left
        if peerTransports[peerID] == nil {
            DispatchQueue.main.async {
                self.allPeers.removeAll { $0.peerID == peerID }
            }
            delegate?.didDisconnectFromPeer(peerID)
        }
    }
    
    func transport(_ transport: TransportProtocol, didReceivePacket packet: BitchatPacket, from peerID: String) {
        // Handle packet based on type - convert to appropriate delegate call
        // This would typically be handled by the BluetoothMeshService
        // For now, just log that we received it
    }
    
    func transport(_ transport: TransportProtocol, didUpdatePeer peer: PeerInfo) {
        // Update peer list
        DispatchQueue.main.async {
            if let index = self.allPeers.firstIndex(where: { $0.peerID == peer.peerID }) {
                self.allPeers[index] = peer
            }
        }
    }
    
    func transport(_ transport: TransportProtocol, didFailToSend messageID: String, to peerID: String, error: Error) {
        // Try fallback transport
        if let fallback = getFallbackTransport(for: transport.transportType) {
            // Attempt to resend with fallback
            // This would need access to the original packet, which could be cached
        }
    }
    
    func transport(_ transport: TransportProtocol, didChangeState isAvailable: Bool) {
        DispatchQueue.main.async {
            if isAvailable {
                self.availableTransports.insert(transport.transportType)
            } else {
                self.availableTransports.remove(transport.transportType)
                self.activeTransports.remove(transport.transportType)
            }
        }
    }
}

// MARK: - Transport Statistics

struct TransportStatistics {
    var peerCounts: [TransportType: Int] = [:]
    var availability: [TransportType: Bool] = [:]
    var messagesSent: [TransportType: Int] = [:]
    var messagesReceived: [TransportType: Int] = [:]
    var bytesTransferred: [TransportType: Int] = [:]
}