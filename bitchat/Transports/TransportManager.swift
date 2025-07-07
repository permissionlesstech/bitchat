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
    @Published var currentTransportInfo: TransportInfo = TransportInfo()
    
    // Private properties
    private(set) var transports: [TransportType: TransportProtocol] = [:]
    private let peerManager = PeerManager.shared
    private let transportQueue = DispatchQueue(label: "bitchat.transportManager", attributes: .concurrent)
    private var cancellables = Set<AnyCancellable>()
    private let bridgeManager = BridgeManager.shared
    private var updateDebounceTimer: Timer?
    private var pendingUpdateInfo: TransportInfo?
    
    // Legacy peer tracking - being migrated to PeerManager
    private var peerTransports: [String: Set<TransportType>] = [:]
    private var routingTable: [String: TransportType] = [:]
    
    // Delegate
    weak var delegate: BitchatDelegate?
    
    // Settings
    var enableWiFiDirect = false {
        didSet {
            if enableWiFiDirect {
                print("TransportManager: WiFi Direct enabled, activating transport")
                activateTransport(.wifiDirect)
            } else {
                print("TransportManager: WiFi Direct disabled, deactivating transport")
                deactivateTransport(.wifiDirect)
            }
        }
    }
    
    var autoSelectTransport = true
    var preferLowPower = true
    
    // Smart activation settings
    private let minPeersForBluetooth = 2  // Activate WiFi Direct if BT has fewer peers
    private let maxPeersForWiFi = 5      // Deactivate WiFi Direct if BT has many peers
    private let wifiActivationDelay: TimeInterval = 5.0  // Wait before activating WiFi
    private var wifiActivationTimer: Timer?
    private var isSmartActivationEnabled = true
    private var wifiActivationScheduled = false
    private var lastLoggedPeerCount = -1
    private var peerCleanupTimer: Timer?
    
    private init() {
        // Start smart activation monitoring
        startSmartActivation()
        
        // Start peer cleanup timer
        peerCleanupTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.peerManager.cleanupStalePeers()
        }
    }
    
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
            guard let transport = self.transports[type] else {
                print("TransportManager: Transport \(type) not registered")
                return
            }
            
            print("TransportManager: Activating \(type) transport")
            transport.start()
            
            DispatchQueue.main.async {
                self.activeTransports.insert(type)
                self.updateTransportInfo()
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
                self.updateTransportInfo()
            }
        }
    }
    
    // MARK: - Message Routing
    
    func send(_ packet: BitchatPacket, to peerID: String?) {
        transportQueue.async {
            if let peerID = peerID {
                // Unicast: select optimal transport for specific peer
                guard let transportType = self.peerManager.selectTransport(for: peerID) else {
                    print("📡 No transport available for peer \(peerID), trying all active transports")
                    // Peer not yet visible, try all active transports
                    for transport in self.transports.values where self.activeTransports.contains(transport.transportType) {
                        try? transport.send(packet, to: peerID)
                    }
                    return
                }
                
                guard let transport = self.transports[transportType] else {
                    print("📡 Transport \(transportType) not available")
                    return
                }
                
                print("📡 Sending message to \(peerID) via \(transport.transportType)")
                
                do {
                    try transport.send(packet, to: peerID)
                    // Record successful delivery
                    self.peerManager.recordSuccessfulDelivery(to: peerID, via: transportType)
                } catch {
                    print("📡 Failed to send via \(transportType): \(error)")
                    self.peerManager.recordFailedDelivery(to: peerID, via: transportType)
                    
                    // Try fallback transport
                    if let fallback = self.getFallbackTransport(for: transport.transportType) {
                        print("📡 Trying fallback \(fallback.transportType) for \(peerID)")
                        try? fallback.send(packet, to: peerID)
                    }
                }
            } else {
                // Broadcast: use all active transports
                let activeTransportTypes = self.activeTransports.sorted(by: { $0.rawValue < $1.rawValue })
                print("📡 Broadcasting message via: \(activeTransportTypes.map { $0.rawValue }.joined(separator: ", "))")
                
                for transport in self.transports.values where self.activeTransports.contains(transport.transportType) {
                    try? transport.broadcast(packet)
                }
                
                // Check if we should bridge this broadcast
                if self.peerManager.canBridge() && packet.ttl > 1 {
                    // This device can act as a bridge
                    print("🌉 Bridge active: forwarding broadcast between transports")
                }
            }
        }
    }
    
    private func selectTransport(for packet: BitchatPacket, to peerID: String) -> TransportProtocol? {
        // Always use PeerManager for transport selection
        if let transportType = peerManager.selectTransport(for: peerID),
           let transport = transports[transportType],
           transport.isAvailable {
            return transport
        }
        
        // Peer not visible on any transport
        return nil
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
    
    // MARK: - Bridge Support
    
    private func bridgeBroadcast(_ packet: BitchatPacket, from sourceTransport: TransportType) {
        // Check if we can bridge
        guard peerManager.canBridge() && packet.ttl > 1 else { return }
        
        // Get peers on source transport
        let sourcePeers = Set(peerManager.getPeers(on: sourceTransport))
        
        // Bridge to other transports with non-overlapping peers
        for (type, transport) in transports where type != sourceTransport && transport.isAvailable {
            let targetPeers = Set(peerManager.getPeers(on: type))
            
            // Only bridge if there are peers on target that aren't on source
            if !targetPeers.isEmpty && !targetPeers.isSubset(of: sourcePeers) {
                var bridgedPacket = packet
                bridgedPacket.ttl = max(1, packet.ttl - 1)
                
                try? transport.broadcast(bridgedPacket)
                print("🌉 Bridging broadcast from \(sourceTransport) to \(type)")
            }
        }
    }
    
    private func updateBridgeManagerPeers() {
        // Get peers from PeerManager
        let bluetoothPeers = peerManager.getPeers(on: TransportType.bluetooth)
        let wifiDirectPeers = peerManager.getPeers(on: TransportType.wifiDirect)
        
        // Update BridgeManager
        bridgeManager.updateBluetoothPeers(bluetoothPeers)
        bridgeManager.updateWiFiDirectPeers(wifiDirectPeers)
        
        // Check if we're a bridge node
        let isBridge = peerManager.canBridge()
        if isBridge != bridgeManager.isBridgeNode {
            print("🌉 Bridge status changed: \(isBridge)")
        }
        
        // Update transport info for UI
        updateTransportInfo()
    }
    
    func updateTransportInfo() {
        // Collect info on background queue
        transportQueue.async { [weak self] in
            guard let self = self else { return }
            
            var info = TransportInfo()
            info.isWiFiDirectActive = self.activeTransports.contains(.wifiDirect)
            info.isBridging = self.bridgeManager.isBridgeNode
            info.bridgedClusters = self.bridgeManager.connectedClusters
            
            // Always get the actual peer count from each transport
            if let bluetoothTransport = self.transports[.bluetooth] {
                info.bluetoothPeerCount = bluetoothTransport.currentPeers.count
            }
            
            // Only show WiFi Direct peer count if it's active
            if info.isWiFiDirectActive {
                if let wifiDirectTransport = self.transports[.wifiDirect] {
                    info.wifiDirectPeerCount = wifiDirectTransport.currentPeers.count
                }
            }
            
            // Update PeerManager with current peer visibility
            for (type, transport) in self.transports {
                for peer in transport.currentPeers {
                    self.peerManager.updatePeerVisibility(peerID: peer.peerID, on: type, rssi: peer.rssi)
                }
            }
            
            // Update allPeers list with unique peers from all transports
            var uniquePeers: [String: PeerInfo] = [:]
            for transport in self.transports.values {
                for peer in transport.currentPeers {
                    if let existing = uniquePeers[peer.peerID] {
                        // Merge transport types - create new PeerInfo since it's immutable
                        let merged = PeerInfo(
                            peerID: existing.peerID,
                            nickname: existing.nickname ?? peer.nickname,
                            publicKey: existing.publicKey ?? peer.publicKey,
                            transportTypes: existing.transportTypes.union(peer.transportTypes),
                            rssi: existing.rssi ?? peer.rssi,
                            lastSeen: peer.lastSeen // Use most recent timestamp
                        )
                        uniquePeers[peer.peerID] = merged
                    } else {
                        uniquePeers[peer.peerID] = peer
                    }
                }
            }
            
            // Determine active transport
            if info.isWiFiDirectActive && info.wifiDirectPeerCount > 0 {
                info.activeTransport = .wifiDirect
            } else {
                info.activeTransport = .bluetooth
            }
            
            // Check if this is a transport state change (immediate update)
            let isTransportStateChange = self.currentTransportInfo.isWiFiDirectActive != info.isWiFiDirectActive ||
                                       self.currentTransportInfo.activeTransport != info.activeTransport
            
            DispatchQueue.main.async {
                if isTransportStateChange {
                    // Update immediately for transport state changes
                    self.currentTransportInfo = info
                    self.allPeers = Array(uniquePeers.values)
                    self.updateBridgeManagerPeers()
                } else {
                    // Apply debouncing for peer count changes
                    self.pendingUpdateInfo = info
                    self.pendingAllPeers = Array(uniquePeers.values)
                    
                    // Cancel existing timer
                    self.updateDebounceTimer?.invalidate()
                    
                    // Create new timer with short delay
                    self.updateDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                        if let pendingInfo = self.pendingUpdateInfo {
                            // Only update if values actually changed
                            if self.currentTransportInfo != pendingInfo {
                                self.currentTransportInfo = pendingInfo
                            }
                            
                            if let pendingPeers = self.pendingAllPeers {
                                self.allPeers = pendingPeers
                            }
                            
                            // Update bridge manager with current peer lists
                            self.updateBridgeManagerPeers()
                        }
                        
                        self.pendingUpdateInfo = nil
                        self.pendingAllPeers = nil
                    }
                }
            }
        }
    }
    
    private var pendingAllPeers: [PeerInfo]?
    
    // MARK: - Smart Activation
    
    private func startSmartActivation() {
        // Check peer count periodically
        Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.evaluateSmartActivation()
        }
    }
    
    private func checkSmartActivation(bluetoothPeerCount: Int) {
        // Only log when peer count changes
        let shouldLog = bluetoothPeerCount != lastLoggedPeerCount
        lastLoggedPeerCount = bluetoothPeerCount
        
        if bluetoothPeerCount < minPeersForBluetooth && !enableWiFiDirect {
            // Not enough Bluetooth peers, schedule WiFi Direct activation
            if !wifiActivationScheduled {
                wifiActivationScheduled = true
                if shouldLog {
                    print("TransportManager: Only \(bluetoothPeerCount) Bluetooth peers, will activate WiFi Direct in \(Int(wifiActivationDelay))s")
                }
                
                // Cancel any existing timer
                wifiActivationTimer?.invalidate()
                
                wifiActivationTimer = Timer.scheduledTimer(withTimeInterval: wifiActivationDelay, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.wifiActivationScheduled = false
                    if self.autoSelectTransport && !self.enableWiFiDirect {
                        print("TransportManager: Activating WiFi Direct to find more distant peers")
                        self.enableWiFiDirect = true
                    } else {
                        print("TransportManager: WiFi activation timer fired but conditions not met (auto: \(self.autoSelectTransport), enabled: \(self.enableWiFiDirect))")
                    }
                }
            }
        } else if bluetoothPeerCount >= minPeersForBluetooth && wifiActivationScheduled {
            // Cancel scheduled activation
            wifiActivationTimer?.invalidate()
            wifiActivationScheduled = false
            if shouldLog {
                print("TransportManager: \(bluetoothPeerCount) Bluetooth peers found, canceling WiFi Direct activation")
            }
        } else if bluetoothPeerCount >= maxPeersForWiFi && enableWiFiDirect {
            // Plenty of Bluetooth peers, check if we should deactivate WiFi Direct
            let wifiPeerCount = peerManager.getPeers(on: TransportType.wifiDirect).count
            
            // Only deactivate if we're not bridging important connections
            if wifiPeerCount == 0 || !peerManager.canBridge() {
                if shouldLog {
                    print("TransportManager: \(bluetoothPeerCount) Bluetooth peers found, deactivating WiFi Direct to save power")
                }
                enableWiFiDirect = false
            } else if shouldLog {
                print("TransportManager: Keeping WiFi Direct active for bridging (\(wifiPeerCount) WiFi peers)")
            }
        }
    }
    
    private func evaluateSmartActivation() {
        guard autoSelectTransport && isSmartActivationEnabled else { return }
        
        // Get current Bluetooth peer count
        let btPeerCount = transports[.bluetooth]?.currentPeers.count ?? 0
        checkSmartActivation(bluetoothPeerCount: btPeerCount)
    }
}

// MARK: - Transport Delegate

extension TransportManager: TransportDelegate {
    func transport(_ transport: TransportProtocol, didDiscoverPeer peer: PeerInfo) {
        // Update PeerManager
        peerManager.updatePeerVisibility(peerID: peer.peerID, on: transport.transportType, rssi: peer.rssi)
        
        // Update peer list
        DispatchQueue.main.async {
            if !self.allPeers.contains(where: { $0.peerID == peer.peerID }) {
                self.allPeers.append(peer)
            }
            
            // Update BridgeManager peer lists
            self.updateBridgeManagerPeers()
        }
        
        // Forward to delegate - use correct method
        if let nickname = peer.nickname {
            delegate?.didConnectToPeer(nickname)
        }
    }
    
    func transport(_ transport: TransportProtocol, didLosePeer peerID: String) {
        // PeerManager will handle stale peer cleanup automatically
        // Just update our peer list
        DispatchQueue.main.async {
            // Check if peer is still visible on other transports
            if self.peerManager.selectTransport(for: peerID) == nil {
                // No transport available, remove from list
                self.allPeers.removeAll { $0.peerID == peerID }
                
                // Update BridgeManager peer lists
                self.updateBridgeManagerPeers()
                
                self.delegate?.didDisconnectFromPeer(peerID)
            }
        }
    }
    
    func transport(_ transport: TransportProtocol, didReceivePacket packet: BitchatPacket, from peerID: String) {
        // Update peer visibility
        peerManager.updatePeerVisibility(peerID: peerID, on: transport.transportType)
        
        // Handle bridging for broadcasts
        if packet.recipientID == nil && packet.ttl > 1 {
            bridgeBroadcast(packet, from: transport.transportType)
        }
        
        // Forward packet to our delegate for processing
        // Only forward non-Bluetooth packets since BluetoothMeshService handles its own
        if transport.transportType != .bluetooth {
            // WiFi Direct and other transport packets need to be forwarded to ChatViewModel
            if let btchatMessage = decodeBitchatMessage(from: packet) {
                delegate?.didReceiveMessage(btchatMessage)
            }
        }
    }
    
    private func decodeBitchatMessage(from packet: BitchatPacket) -> BitchatMessage? {
        // Decode BitchatPacket payload into BitchatMessage
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(BitchatMessage.self, from: packet.payload)
        } catch {
            print("TransportManager: Failed to decode BitchatMessage: \(error)")
            return nil
        }
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
        if getFallbackTransport(for: transport.transportType) != nil {
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
            self.updateTransportInfo()
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

// MARK: - Transport Info for UI

struct TransportInfo: Equatable {
    var activeTransport: TransportType = .bluetooth
    var isWiFiDirectActive: Bool = false
    var isBridging: Bool = false
    var bridgedClusters: Int = 0
    var bluetoothPeerCount: Int = 0
    var wifiDirectPeerCount: Int = 0
    
    var displayText: String {
        if isBridging {
            return "Bridging \(bridgedClusters) clusters"
        } else if isWiFiDirectActive && bluetoothPeerCount > 0 {
            return "Dual mode"
        } else if isWiFiDirectActive {
            return "WiFi Direct"
        } else {
            return "Bluetooth"
        }
    }
    
    var iconName: String {
        if isBridging {
            return "network.badge.shield.half.filled"
        } else if activeTransport == .wifiDirect {
            return "wifi"
        } else {
            // Bluetooth
            return "dot.radiowaves.left.and.right"
        }
    }
    
    var secondaryIconName: String? {
        // No secondary icon - we only show one
        return nil
    }
}