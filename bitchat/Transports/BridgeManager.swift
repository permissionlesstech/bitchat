//
// BridgeManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Combine

// MARK: - Bridge Node Management

class BridgeManager: ObservableObject {
    static let shared = BridgeManager()
    
    // Published properties for UI
    @Published var isBridgeNode: Bool = false
    @Published var bridgeStatus: BridgeStatus = .inactive
    @Published var connectedClusters: Int = 0
    @Published var bridgedMessageCount: Int = 0
    
    // Bridge detection parameters
    #if os(macOS)
    private let minBatteryForBridge: Float = 0.3  // 30% battery minimum on macOS (more reasonable)
    #else
    private let minBatteryForBridge: Float = 0.4  // 40% battery minimum on iOS (less aggressive)
    #endif
    private let minPeersForBridge = 2  // Need connections to at least 2 peers (more realistic)
    private let bridgeScoreThreshold: Float = 0.65  // 65% score to become bridge
    
    // Private properties
    private var bluetoothPeers: Set<String> = []
    private var wifiDirectPeers: Set<String> = []
    private var peerClusters: [String: Set<String>] = [:]  // clusterID -> peer IDs
    private var peerLastSeen: [String: Date] = [:]  // peerID -> last seen timestamp
    private var bridgeScore: Float = 0.0
    private var evaluationTimer: Timer?
    private let evaluationInterval: TimeInterval = 20.0  // Re-evaluate every 20 seconds
    private var lastEvaluationState: String = ""  // For detecting changes
    
    private init() {
        startBridgeEvaluation()
    }
    
    // MARK: - Bridge Status
    
    enum BridgeStatus {
        case inactive
        case evaluating
        case active(clusters: Int)
        case lowBattery
        case insufficientConnections
        
        var displayText: String {
            switch self {
            case .inactive:
                return "Bridge Inactive"
            case .evaluating:
                return "Evaluating Network..."
            case .active(let clusters):
                return "Bridging \(clusters) Clusters"
            case .lowBattery:
                return "Low Battery"
            case .insufficientConnections:
                return "Too Few Connections"
            }
        }
        
        var iconName: String {
            switch self {
            case .inactive:
                return "network"
            case .evaluating:
                return "network.badge.shield.half.filled"
            case .active:
                return "network.fill"
            case .lowBattery:
                return "battery.25"
            case .insufficientConnections:
                return "network.slash"
            }
        }
    }
    
    // MARK: - Peer Updates
    
    func updateBluetoothPeers(_ peers: [String]) {
        bluetoothPeers = Set(peers)
        // Update last seen times
        for peer in peers {
            peerLastSeen[peer] = Date()
        }
        // Clean up stale peers
        cleanupStalePeers()
        evaluateBridgeStatus()
    }
    
    func updateWiFiDirectPeers(_ peers: [String]) {
        wifiDirectPeers = Set(peers)
        // Update last seen times
        for peer in peers {
            peerLastSeen[peer] = Date()
        }
        // Clean up stale peers
        cleanupStalePeers()
        evaluateBridgeStatus()
    }
    
    // MARK: - Bridge Evaluation
    
    private func startBridgeEvaluation() {
        evaluationTimer = Timer.scheduledTimer(withTimeInterval: evaluationInterval, repeats: true) { [weak self] _ in
            self?.evaluateBridgeStatus()
        }
    }
    
    private func cleanupStalePeers() {
        let staleThreshold: TimeInterval = 60.0  // Consider peers stale after 60 seconds
        let now = Date()
        
        // Remove stale peers from our tracking
        let stalePeers = peerLastSeen.compactMap { (peerID, lastSeen) -> String? in
            return now.timeIntervalSince(lastSeen) > staleThreshold ? peerID : nil
        }
        
        for peerID in stalePeers {
            peerLastSeen.removeValue(forKey: peerID)
            bluetoothPeers.remove(peerID)
            wifiDirectPeers.remove(peerID)
        }
    }
    
    private func evaluateBridgeStatus() {
        // Only show evaluating if we haven't determined status yet
        if case .inactive = bridgeStatus {
            bridgeStatus = .evaluating
        }
        
        // Calculate bridge score based on multiple factors
        var score: Float = 0.0
        var factors: [Float] = []
        
        // Factor 1: Battery level (0-25 points)
        let batteryLevel = BatteryOptimizer.shared.batteryLevel
        if batteryLevel < minBatteryForBridge {
            // Apply hysteresis - don't immediately drop bridge if we're already active
            if isBridgeNode && batteryLevel > (minBatteryForBridge - 0.05) {
                // Keep bridge active if battery is within 5% of threshold
                return
            }
            bridgeStatus = .lowBattery
            isBridgeNode = false
            return
        }
        factors.append(batteryLevel * 0.25)
        
        // Factor 2: Multi-transport capability (0-25 points)
        let hasMultiTransport = !bluetoothPeers.isEmpty && !wifiDirectPeers.isEmpty
        factors.append(hasMultiTransport ? 0.25 : 0.0)
        
        // Factor 3: Network position (0-25 points)
        let totalPeers = bluetoothPeers.union(wifiDirectPeers).count
        if totalPeers < minPeersForBridge {
            // Apply hysteresis
            if isBridgeNode && totalPeers >= (minPeersForBridge - 1) {
                return
            }
            bridgeStatus = .insufficientConnections
            isBridgeNode = false
            return
        }
        let positionScore = min(Float(totalPeers) / 10.0, 1.0) * 0.25
        factors.append(positionScore)
        
        // Factor 4: Cluster diversity (0-25 points)
        let clusterCount = detectClusters()
        let diversityScore = min(Float(clusterCount) / 3.0, 1.0) * 0.25
        factors.append(diversityScore)
        
        // Calculate total score
        score = factors.reduce(0, +)
        bridgeScore = score
        
        // Apply hysteresis to score threshold
        let effectiveThreshold = isBridgeNode ? (bridgeScoreThreshold - 0.1) : bridgeScoreThreshold
        
        // Determine if we should be a bridge
        // Only activate bridge in auto mode when we have peers on multiple transports
        let shouldBridge = score >= effectiveThreshold && 
                          hasMultiTransport && 
                          TransportManager.shared.autoSelectTransport
        
        if shouldBridge {
            // Check if state actually changed
            let wasActive = isBridgeNode
            isBridgeNode = true
            bridgeStatus = .active(clusters: clusterCount)
            connectedClusters = clusterCount
            
            // Enable WiFi Direct if not already enabled
            if !TransportManager.shared.enableWiFiDirect {
                TransportManager.shared.enableWiFiDirect = true
            }
            
            // Log state change
            if !wasActive {
                print("BridgeManager: Became active bridge node (score: \(score))")
            }
        } else {
            let wasActive = isBridgeNode
            isBridgeNode = false
            bridgeStatus = .inactive
            connectedClusters = 0
            
            // Log state change
            if wasActive {
                print("BridgeManager: Deactivated bridge node (score: \(score))")
            }
        }
    }
    
    // MARK: - Cluster Detection
    
    private func detectClusters() -> Int {
        // More sophisticated clustering based on transport connectivity and peer relationships
        var clusters: [String: Set<String>] = [:]
        
        // Phase 1: Identify transport-based clusters
        let btOnlyPeers = bluetoothPeers.subtracting(wifiDirectPeers)
        let wifiOnlyPeers = wifiDirectPeers.subtracting(bluetoothPeers)
        let dualTransportPeers = bluetoothPeers.intersection(wifiDirectPeers)
        
        // Phase 2: Create initial clusters
        if !btOnlyPeers.isEmpty {
            clusters["bt_cluster"] = btOnlyPeers
        }
        
        if !wifiOnlyPeers.isEmpty {
            clusters["wifi_cluster"] = wifiOnlyPeers
        }
        
        if !dualTransportPeers.isEmpty {
            clusters["dual_cluster"] = dualTransportPeers
        }
        
        // Phase 3: Analyze cluster connectivity patterns
        var clusterConnectivity: [String: Int] = [:]
        for (clusterID, peers) in clusters {
            // Count inter-cluster connections
            var connections = 0
            for otherCluster in clusters where otherCluster.key != clusterID {
                // Check if we can bridge between these clusters
                if !peers.isEmpty && !otherCluster.value.isEmpty {
                    connections += 1
                }
            }
            clusterConnectivity[clusterID] = connections
        }
        
        // Update cluster mapping
        peerClusters = clusters
        
        // Return effective cluster count (clusters that need bridging)
        let effectiveClusters = clusters.count > 0 ? max(2, clusters.count) : 0
        return effectiveClusters
    }
    
    // MARK: - Bridge Routing
    
    func shouldBridgeMessage(_ packet: BitchatPacket, from sourceTransport: TransportType) -> Set<TransportType> {
        guard isBridgeNode else { return [] }
        
        var targetTransports: Set<TransportType> = []
        
        // Extract sender from packet - not used for bridging logic
        // let senderID = String(data: packet.senderID, encoding: .utf8) ?? ""
        
        // Check if message needs bridging based on recipient
        if let recipientID = packet.recipientID,
           recipientID != SpecialRecipients.broadcast {
            // Private message - check if recipient is on different transport
            let recipientIDString = String(data: recipientID, encoding: .utf8) ?? ""
            
            if sourceTransport == .bluetooth && wifiDirectPeers.contains(recipientIDString) {
                targetTransports.insert(.wifiDirect)
            } else if sourceTransport == .wifiDirect && bluetoothPeers.contains(recipientIDString) {
                targetTransports.insert(.bluetooth)
            }
        } else {
            // Broadcast message - bridge to other transport if we haven't seen it
            if sourceTransport == .bluetooth && !wifiDirectPeers.isEmpty {
                targetTransports.insert(.wifiDirect)
            } else if sourceTransport == .wifiDirect && !bluetoothPeers.isEmpty {
                targetTransports.insert(.bluetooth)
            }
        }
        
        // Track bridged messages
        if !targetTransports.isEmpty {
            bridgedMessageCount += 1
        }
        
        return targetTransports
    }
    
    // MARK: - Enhanced Routing Information
    
    struct RouteInfo {
        let nextHop: String
        let transport: TransportType
        let estimatedHops: Int
        let bridgeRequired: Bool
    }
    
    func getBestRoute(to destination: String) -> RouteInfo? {
        // Check direct routes first
        if bluetoothPeers.contains(destination) {
            return RouteInfo(
                nextHop: destination,
                transport: .bluetooth,
                estimatedHops: 1,
                bridgeRequired: false
            )
        }
        
        if wifiDirectPeers.contains(destination) {
            return RouteInfo(
                nextHop: destination,
                transport: .wifiDirect,
                estimatedHops: 1,
                bridgeRequired: false
            )
        }
        
        // Check if we can bridge to reach destination
        if isBridgeNode {
            // This is simplified - in practice, we'd need routing tables
            // from other bridge nodes to build multi-hop routes
            for (_, peers) in peerClusters {
                if peers.contains(destination) {
                    // Found in a cluster we can bridge to
                    return RouteInfo(
                        nextHop: peers.first ?? destination,
                        transport: wifiDirectPeers.contains(destination) ? .wifiDirect : .bluetooth,
                        estimatedHops: 2,
                        bridgeRequired: true
                    )
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Statistics
    
    func resetStatistics() {
        bridgedMessageCount = 0
    }
    
    func getBridgeStatistics() -> BridgeStatistics {
        return BridgeStatistics(
            isBridge: isBridgeNode,
            score: bridgeScore,
            bluetoothPeers: bluetoothPeers.count,
            wifiDirectPeers: wifiDirectPeers.count,
            clusters: connectedClusters,
            bridgedMessages: bridgedMessageCount
        )
    }
}

// MARK: - Bridge Statistics

struct BridgeStatistics {
    let isBridge: Bool
    let score: Float
    let bluetoothPeers: Int
    let wifiDirectPeers: Int
    let clusters: Int
    let bridgedMessages: Int
}