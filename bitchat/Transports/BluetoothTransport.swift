//
// BluetoothTransport.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CoreBluetooth

// MARK: - Bluetooth Transport Adapter

class BluetoothTransport: NSObject, TransportProtocol {
    
    // MARK: - Properties
    
    let transportType: TransportType = .bluetooth
    
    var isAvailable: Bool {
        return meshService.isBluetoothAvailable
    }
    
    var currentPeers: [PeerInfo] {
        return meshService.connectedPeerIDs.map { peerID in
            PeerInfo(
                peerID: peerID,
                nickname: meshService.peerNicknamesDict[peerID],
                publicKey: nil,  // TODO: Expose from encryption service
                transportTypes: [.bluetooth],
                rssi: meshService.peerRSSIValues[peerID]?.intValue,
                lastSeen: meshService.peerLastSeen[peerID] ?? Date()
            )
        }
    }
    
    let capabilities = TransportCapabilities(
        maxMessageSize: 512 * 1024,  // 512KB practical limit
        averageBandwidth: 125_000,    // ~1 Mbps = 125KB/s
        typicalRange: 30,             // 30 meters typical
        powerConsumption: .low
    )
    
    weak var delegate: TransportDelegate?
    
    // Private properties
    private let meshService: BluetoothMeshService
    private var isActive = false
    
    // MARK: - Initialization
    
    init(meshService: BluetoothMeshService) {
        self.meshService = meshService
        super.init()
    }
    
    // MARK: - TransportProtocol Implementation
    
    func startDiscovery() {
        meshService.startScanning()
    }
    
    func stopDiscovery() {
        // BluetoothMeshService doesn't have a stopScanning method
        // Scanning is managed internally by the service
    }
    
    func send(_ packet: BitchatPacket, to peerID: String?) throws {
        // The mesh service expects to handle higher-level operations
        // For now, we'll throw an error indicating this should be handled elsewhere
        throw TransportError.invalidState("BluetoothTransport.send not implemented - use BluetoothMeshService directly")
    }
    
    func connect(to peerID: String) throws {
        // Bluetooth doesn't have explicit connect - it's automatic
        // This is a no-op for Bluetooth
    }
    
    func disconnect(from peerID: String) {
        meshService.disconnectFromPeer(peerID)
    }
    
    func start() {
        guard !isActive else { return }
        isActive = true
        meshService.startServices()
    }
    
    func stop() {
        guard isActive else { return }
        isActive = false
        // BluetoothMeshService doesn't have a stopServices method
        // The service manages its own lifecycle
    }
    
    func getConnectionQuality(for peerID: String) -> ConnectionQuality? {
        guard let rssi = meshService.peerRSSIValues[peerID]?.intValue else { return nil }
        
        return ConnectionQuality(
            rssi: rssi,
            packetLoss: 0.0,  // TODO: Track packet loss
            averageLatency: 0.05,  // ~50ms typical for BLE
            bandwidth: 125_000  // 1 Mbps theoretical
        )
    }
}

// MARK: - BluetoothMeshService Extension

extension BluetoothMeshService {
    // Expose internal state for transport adapter
    var isBluetoothAvailable: Bool {
        // Use the centralManager and peripheralManager state
        return true  // Simplified - actual check would need access to internal state
    }
    
    var connectedPeerIDs: [String] {
        // Return active peers which is already tracked
        return Array(getActivePeers())
    }
    
    var peerNicknamesDict: [String: String] {
        return getPeerNicknames()
    }
    
    var peerRSSIValues: [String: NSNumber] {
        return getPeerRSSI()
    }
    
    var peerLastSeen: [String: Date] {
        return getPeerLastSeenTimestamps()
    }
}