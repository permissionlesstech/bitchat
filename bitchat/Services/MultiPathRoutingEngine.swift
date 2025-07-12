//
// MultiPathRoutingEngine.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Combine
import CoreLocation

// Routing path structure
struct RoutingPath: Codable, Equatable {
    let pathID: String
    let nodes: [String] // Array of gateway/node IDs
    let estimatedLatency: TimeInterval
    let reliability: Double // 0.0 to 1.0
    let bandwidth: Double // bits per second
    let cost: Double // Cost per message
    let lastUpdated: Date
    let isActive: Bool
    
    init(nodes: [String], estimatedLatency: TimeInterval, reliability: Double, bandwidth: Double, cost: Double) {
        self.pathID = UUID().uuidString
        self.nodes = nodes
        self.estimatedLatency = estimatedLatency
        self.reliability = reliability
        self.bandwidth = bandwidth
        self.cost = cost
        self.lastUpdated = Date()
        self.isActive = true
    }
}

// Network topology node
struct NetworkNode: Codable, Equatable {
    let nodeID: String
    let nodeType: NodeType
    let location: CLLocationCoordinate2D?
    let capabilities: [NodeCapability]
    let lastSeen: Date
    let isOnline: Bool
    let batteryLevel: Float?
    let signalStrength: Int?
    
    enum NodeType: String, Codable {
        case bluetoothMesh = "bluetooth_mesh"
        case satelliteGateway = "satellite_gateway"
        case hybridGateway = "hybrid_gateway"
        case emergencyRelay = "emergency_relay"
    }
    
    enum NodeCapability: String, Codable {
        case messageRelay = "message_relay"
        case satelliteAccess = "satellite_access"
        case emergencyBroadcast = "emergency_broadcast"
        case storeAndForward = "store_and_forward"
        case encryption = "encryption"
        case compression = "compression"
    }
}

// Message routing request
struct RoutingRequest: Codable {
    let messageID: String
    let senderID: String
    let recipientID: String?
    let messageType: MessageType
    let priority: UInt8
    let size: Int
    let maxLatency: TimeInterval?
    let minReliability: Double?
    let maxCost: Double?
    let timestamp: Date
    
    enum MessageType: String, Codable {
        case emergency = "emergency"
        case global = "global"
        case local = "local"
        case privateMessage = "private"
        case broadcast = "broadcast"
    }
}

// Routing decision
struct RoutingDecision: Codable {
    let requestID: String
    let selectedPath: RoutingPath?
    let alternativePaths: [RoutingPath]
    let routingStrategy: RoutingStrategy
    let estimatedDeliveryTime: Date
    let confidence: Double
    let reasoning: String
    
    enum RoutingStrategy: String, Codable {
        case singlePath = "single_path"
        case multiPath = "multi_path"
        case storeAndForward = "store_and_forward"
        case emergencyBypass = "emergency_bypass"
        case localOnly = "local_only"
    }
}

// Network topology manager
class NetworkTopologyManager: ObservableObject {
    @Published var nodes: [String: NetworkNode] = [:]
    @Published var paths: [String: RoutingPath] = [:]
    @Published var topologyVersion: Int = 0
    
    private let locationManager = CLLocationManager()
    private var topologyUpdateTimer: Timer?
    private var pathDiscoveryTimer: Timer?
    
    init() {
        setupLocationManager()
        startTopologyUpdates()
        startPathDiscovery()
    }
    
    private func setupLocationManager() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
    }
    
    private func startTopologyUpdates() {
        topologyUpdateTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.updateTopology()
        }
    }
    
    private func startPathDiscovery() {
        pathDiscoveryTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.discoverNewPaths()
        }
    }
    
    func addNode(_ node: NetworkNode) {
        nodes[node.nodeID] = node
        topologyVersion += 1
    }
    
    func removeNode(_ nodeID: String) {
        nodes.removeValue(forKey: nodeID)
        // Remove paths that include this node
        paths = paths.filter { !$0.value.nodes.contains(nodeID) }
        topologyVersion += 1
    }
    
    func updateNode(_ node: NetworkNode) {
        nodes[node.nodeID] = node
        topologyVersion += 1
    }
    
    func addPath(_ path: RoutingPath) {
        paths[path.pathID] = path
        topologyVersion += 1
    }
    
    private func updateTopology() {
        // Update node statuses and remove stale nodes
        let now = Date()
        let staleThreshold: TimeInterval = 300 // 5 minutes
        
        for (nodeID, node) in nodes {
            if now.timeIntervalSince(node.lastSeen) > staleThreshold {
                removeNode(nodeID)
            }
        }
    }
    
    private func discoverNewPaths() {
        // Discover new routing paths based on current topology
        let onlineNodes = nodes.values.filter { $0.isOnline }
        
        for node in onlineNodes {
            if node.nodeType == .satelliteGateway || node.nodeType == .hybridGateway {
                // Find paths to this gateway
                discoverPathsToGateway(node)
            }
        }
    }
    
    private func discoverPathsToGateway(_ gateway: NetworkNode) {
        // Find all possible paths to this gateway
        let localNodes = nodes.values.filter { $0.nodeType == .bluetoothMesh && $0.isOnline }
        
        for localNode in localNodes {
            if let path = calculatePath(from: localNode, to: gateway) {
                addPath(path)
            }
        }
    }
    
    private func calculatePath(from source: NetworkNode, to destination: NetworkNode) -> RoutingPath? {
        // Simple path calculation - in a real implementation, this would use
        // more sophisticated routing algorithms like A* or Dijkstra's
        
        guard let sourceLocation = source.location,
              let destLocation = destination.location else {
            return nil
        }
        
        let distance = CLLocation(latitude: sourceLocation.latitude, longitude: sourceLocation.longitude)
            .distance(from: CLLocation(latitude: destLocation.latitude, longitude: destLocation.longitude))
        
        // Estimate latency based on distance and network type
        let latency: TimeInterval
        let reliability: Double
        let bandwidth: Double
        let cost: Double
        
        if destination.nodeType == .satelliteGateway {
            // Satellite path
            latency = 2.0 + (distance / 1000000) // Base 2s + distance factor
            reliability = 0.85
            bandwidth = 2400 // Iridium SBD typical rate
            cost = 0.10 // Cost per message
        } else {
            // Local mesh path
            latency = 0.1 + (distance / 1000) // Base 100ms + distance factor
            reliability = 0.95
            bandwidth = 1000000 // 1 Mbps typical for BLE
            cost = 0.0 // No cost for local
        }
        
        return RoutingPath(
            nodes: [source.nodeID, destination.nodeID],
            estimatedLatency: latency,
            reliability: reliability,
            bandwidth: bandwidth,
            cost: cost
        )
    }
}

// Main routing engine
class MultiPathRoutingEngine: ObservableObject {
    static let shared = MultiPathRoutingEngine()
    
    @Published var currentTopology: NetworkTopologyManager
    @Published var routingStats: RoutingStatistics
    
    private var routingCache: [String: RoutingDecision] = [:]
    private var activeRoutes: [String: ActiveRoute] = [:]
    private var routeMonitorTimer: Timer?
    
    struct RoutingStatistics: Codable {
        var totalMessagesRouted: Int = 0
        var successfulDeliveries: Int = 0
        var failedDeliveries: Int = 0
        var averageLatency: TimeInterval = 0
        var totalCost: Double = 0
        var lastReset: Date = Date()
    }
    
    struct ActiveRoute: Codable {
        let routeID: String
        let messageID: String
        let path: RoutingPath
        let startTime: Date
        let expectedDelivery: Date
        var status: RouteStatus
        var actualLatency: TimeInterval?
        
        enum RouteStatus: String, Codable {
            case active = "active"
            case delivered = "delivered"
            case failed = "failed"
            case timeout = "timeout"
        }
    }
    
    init() {
        self.currentTopology = NetworkTopologyManager()
        self.routingStats = RoutingStatistics()
        
        startRouteMonitoring()
    }
    
    // MARK: - Main Routing Interface
    
    func routeMessage(_ request: RoutingRequest) -> RoutingDecision {
        // Check cache first
        let cacheKey = createCacheKey(for: request)
        if let cached = routingCache[cacheKey] {
            return cached
        }
        
        // Calculate optimal route
        let decision = calculateOptimalRoute(for: request)
        
        // Cache the decision
        routingCache[cacheKey] = decision
        
        // Start monitoring the route if a path was selected
        if let path = decision.selectedPath {
            startRouteMonitoring(for: request.messageID, path: path, expectedDelivery: decision.estimatedDeliveryTime)
        }
        
        // Update statistics
        updateRoutingStats(for: decision)
        
        return decision
    }
    
    // MARK: - Route Calculation
    
    private func calculateOptimalRoute(for request: RoutingRequest) -> RoutingDecision {
        let availablePaths = getAvailablePaths(for: request)
        
        guard !availablePaths.isEmpty else {
            return createNoRouteDecision(for: request)
        }
        
        // Apply routing strategy based on message type and priority
        let strategy = determineRoutingStrategy(for: request)
        
        switch strategy {
        case .emergencyBypass:
            return calculateEmergencyRoute(for: request, paths: availablePaths)
        case .multiPath:
            return calculateMultiPathRoute(for: request, paths: availablePaths)
        case .singlePath:
            return calculateSinglePathRoute(for: request, paths: availablePaths)
        case .storeAndForward:
            return calculateStoreAndForwardRoute(for: request, paths: availablePaths)
        case .localOnly:
            return calculateLocalOnlyRoute(for: request, paths: availablePaths)
        }
    }
    
    private func getAvailablePaths(for request: RoutingRequest) -> [RoutingPath] {
        let allPaths = currentTopology.paths.values.filter { $0.isActive }
        
        return allPaths.filter { path in
            // Check latency constraint
            if let maxLatency = request.maxLatency {
                guard path.estimatedLatency <= maxLatency else { return false }
            }
            
            // Check reliability constraint
            if let minReliability = request.minReliability {
                guard path.reliability >= minReliability else { return false }
            }
            
            // Check cost constraint
            if let maxCost = request.maxCost {
                guard path.cost <= maxCost else { return false }
            }
            
            return true
        }
    }
    
    private func determineRoutingStrategy(for request: RoutingRequest) -> RoutingDecision.RoutingStrategy {
        switch request.messageType {
        case .emergency:
            return .emergencyBypass
        case .global:
            return request.priority >= 2 ? .multiPath : .singlePath
        case .local:
            return .localOnly
        case .privateMessage:
            return .singlePath
        case .broadcast:
            return .multiPath
        }
    }
    
    // MARK: - Strategy Implementations
    
    private func calculateEmergencyRoute(for request: RoutingRequest, paths: [RoutingPath]) -> RoutingDecision {
        // For emergencies, prioritize reliability and speed over cost
        let sortedPaths = paths.sorted { path1, path2 in
            // Primary: reliability, Secondary: latency
            if path1.reliability != path2.reliability {
                return path1.reliability > path2.reliability
            }
            return path1.estimatedLatency < path2.estimatedLatency
        }
        
        guard let bestPath = sortedPaths.first else {
            return createNoRouteDecision(for: request)
        }
        
        return RoutingDecision(
            requestID: request.messageID,
            selectedPath: bestPath,
            alternativePaths: Array(sortedPaths.dropFirst().prefix(3)),
            routingStrategy: .emergencyBypass,
            estimatedDeliveryTime: Date().addingTimeInterval(bestPath.estimatedLatency),
            confidence: bestPath.reliability,
            reasoning: "Emergency route selected for maximum reliability"
        )
    }
    
    private func calculateMultiPathRoute(for request: RoutingRequest, paths: [RoutingPath]) -> RoutingDecision {
        // For multi-path, select multiple paths and send via all of them
        let sortedPaths = paths.sorted { path1, path2 in
            // Weighted scoring: 40% reliability, 30% latency, 20% bandwidth, 10% cost
            let score1 = (path1.reliability * 0.4) + (1.0 / (1.0 + path1.estimatedLatency) * 0.3) + (min(path1.bandwidth / 1000000, 1.0) * 0.2) + ((1.0 - path1.cost) * 0.1)
            let score2 = (path2.reliability * 0.4) + (1.0 / (1.0 + path2.estimatedLatency) * 0.3) + (min(path2.bandwidth / 1000000, 1.0) * 0.2) + ((1.0 - path2.cost) * 0.1)
            return score1 > score2
        }
        
        let selectedPaths = Array(sortedPaths.prefix(3)) // Use top 3 paths
        
        guard !selectedPaths.isEmpty else {
            return createNoRouteDecision(for: request)
        }
        
        let primaryPath = selectedPaths[0]
        let alternativePaths = Array(selectedPaths.dropFirst())
        
        return RoutingDecision(
            requestID: request.messageID,
            selectedPath: primaryPath,
            alternativePaths: alternativePaths,
            routingStrategy: .multiPath,
            estimatedDeliveryTime: Date().addingTimeInterval(primaryPath.estimatedLatency),
            confidence: calculateMultiPathConfidence(paths: selectedPaths),
            reasoning: "Multi-path route selected for redundancy"
        )
    }
    
    private func calculateSinglePathRoute(for request: RoutingRequest, paths: [RoutingPath]) -> RoutingDecision {
        // For single path, find the best balance of cost and performance
        let sortedPaths = paths.sorted { path1, path2 in
            // Weighted scoring: 50% reliability, 30% latency, 20% cost
            let score1 = (path1.reliability * 0.5) + (1.0 / (1.0 + path1.estimatedLatency) * 0.3) + ((1.0 - path1.cost) * 0.2)
            let score2 = (path2.reliability * 0.5) + (1.0 / (1.0 + path2.estimatedLatency) * 0.3) + ((1.0 - path2.cost) * 0.2)
            return score1 > score2
        }
        
        guard let bestPath = sortedPaths.first else {
            return createNoRouteDecision(for: request)
        }
        
        return RoutingDecision(
            requestID: request.messageID,
            selectedPath: bestPath,
            alternativePaths: Array(sortedPaths.dropFirst().prefix(2)),
            routingStrategy: .singlePath,
            estimatedDeliveryTime: Date().addingTimeInterval(bestPath.estimatedLatency),
            confidence: bestPath.reliability,
            reasoning: "Single optimal path selected"
        )
    }
    
    private func calculateStoreAndForwardRoute(for request: RoutingRequest, paths: [RoutingPath]) -> RoutingDecision {
        // For store-and-forward, prioritize cost over speed
        let sortedPaths = paths.sorted { path1, path2 in
            // Primary: cost, Secondary: reliability
            if path1.cost != path2.cost {
                return path1.cost < path2.cost
            }
            return path1.reliability > path2.reliability
        }
        
        guard let bestPath = sortedPaths.first else {
            return createNoRouteDecision(for: request)
        }
        
        return RoutingDecision(
            requestID: request.messageID,
            selectedPath: bestPath,
            alternativePaths: Array(sortedPaths.dropFirst().prefix(2)),
            routingStrategy: .storeAndForward,
            estimatedDeliveryTime: Date().addingTimeInterval(bestPath.estimatedLatency * 2), // Assume longer for store-and-forward
            confidence: bestPath.reliability * 0.8, // Slightly lower confidence for store-and-forward
            reasoning: "Store-and-forward route selected for cost optimization"
        )
    }
    
    private func calculateLocalOnlyRoute(for request: RoutingRequest, paths: [RoutingPath]) -> RoutingDecision {
        // For local only, filter to Bluetooth mesh paths only
        let localPaths = paths.filter { path in
            path.nodes.allSatisfy { nodeID in
                currentTopology.nodes[nodeID]?.nodeType == .bluetoothMesh
            }
        }
        
        guard let bestPath = localPaths.sorted(by: { $0.estimatedLatency < $1.estimatedLatency }).first else {
            return createNoRouteDecision(for: request)
        }
        
        return RoutingDecision(
            requestID: request.messageID,
            selectedPath: bestPath,
            alternativePaths: [],
            routingStrategy: .localOnly,
            estimatedDeliveryTime: Date().addingTimeInterval(bestPath.estimatedLatency),
            confidence: bestPath.reliability,
            reasoning: "Local-only route selected"
        )
    }
    
    private func createNoRouteDecision(for request: RoutingRequest) -> RoutingDecision {
        return RoutingDecision(
            requestID: request.messageID,
            selectedPath: nil,
            alternativePaths: [],
            routingStrategy: .singlePath,
            estimatedDeliveryTime: Date().addingTimeInterval(3600), // 1 hour default
            confidence: 0.0,
            reasoning: "No suitable route found"
        )
    }
    
    // MARK: - Route Monitoring
    
    private func startRouteMonitoring() {
        routeMonitorTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.monitorActiveRoutes()
        }
    }
    
    private func startRouteMonitoring(for messageID: String, path: RoutingPath, expectedDelivery: Date) {
        let activeRoute = ActiveRoute(
            routeID: UUID().uuidString,
            messageID: messageID,
            path: path,
            startTime: Date(),
            expectedDelivery: expectedDelivery,
            status: .active
        )
        
        activeRoutes[messageID] = activeRoute
    }
    
    private func monitorActiveRoutes() {
        let now = Date()
        
        for (messageID, route) in activeRoutes {
            switch route.status {
            case .active:
                if now > route.expectedDelivery.addingTimeInterval(30) { // 30 second grace period
                    // Route timed out
                    var updatedRoute = route
                    updatedRoute.status = .timeout
                    activeRoutes[messageID] = updatedRoute
                    
                    // Try alternative route if available
                    tryAlternativeRoute(for: messageID)
                }
            case .delivered, .failed, .timeout:
                // Remove completed routes after some time
                if now.timeIntervalSince(route.startTime) > 3600 { // 1 hour
                    activeRoutes.removeValue(forKey: messageID)
                }
            }
        }
    }
    
    private func tryAlternativeRoute(for messageID: String) {
        // Implementation for trying alternative routes when primary route fails
        print("Trying alternative route for message: \(messageID)")
    }
    
    // MARK: - Utility Methods
    
    private func createCacheKey(for request: RoutingRequest) -> String {
        return "\(request.senderID)-\(request.recipientID ?? "broadcast")-\(request.messageType.rawValue)-\(request.priority)"
    }
    
    private func calculateMultiPathConfidence(paths: [RoutingPath]) -> Double {
        // Calculate confidence for multi-path routing
        // Formula: 1 - (1 - p1) * (1 - p2) * ... * (1 - pn)
        // where p1, p2, ..., pn are the reliability of each path
        let failureProbabilities = paths.map { 1.0 - $0.reliability }
        let totalFailureProbability = failureProbabilities.reduce(1.0, *)
        return 1.0 - totalFailureProbability
    }
    
    private func updateRoutingStats(for decision: RoutingDecision) {
        routingStats.totalMessagesRouted += 1
        
        if decision.selectedPath != nil {
            routingStats.averageLatency = (routingStats.averageLatency + decision.selectedPath!.estimatedLatency) / 2
            routingStats.totalCost += decision.selectedPath!.cost
        }
    }
    
    // MARK: - Public Interface
    
    func reportDeliverySuccess(for messageID: String) {
        routingStats.successfulDeliveries += 1
        
        if var route = activeRoutes[messageID] {
            route.status = .delivered
            route.actualLatency = Date().timeIntervalSince(route.startTime)
            activeRoutes[messageID] = route
        }
    }
    
    func reportDeliveryFailure(for messageID: String, reason: String) {
        routingStats.failedDeliveries += 1
        
        if var route = activeRoutes[messageID] {
            route.status = .failed
            activeRoutes[messageID] = route
        }
    }
    
    func getRoutingStatistics() -> RoutingStatistics {
        return routingStats
    }
    
    func resetStatistics() {
        routingStats = RoutingStatistics()
    }
} 