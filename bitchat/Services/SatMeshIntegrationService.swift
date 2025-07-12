//
// SatMeshIntegrationService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Combine
import CoreLocation

// SatMesh service status
enum SatMeshStatus: String, Codable {
    case offline = "offline"
    case connecting = "connecting"
    case online = "online"
    case emergency = "emergency"
    case maintenance = "maintenance"
}

// SatMesh configuration
struct SatMeshConfig: Codable {
    let enableSatellite: Bool
    let enableEmergencyBroadcast: Bool
    let enableGlobalRouting: Bool
    let maxMessageSize: Int
    let compressionEnabled: Bool
    let costLimit: Double
    let preferredSatellite: String
    
    static let `default` = SatMeshConfig(
        enableSatellite: true,
        enableEmergencyBroadcast: true,
        enableGlobalRouting: true,
        maxMessageSize: 500,
        compressionEnabled: true,
        costLimit: 10.0,
        preferredSatellite: "iridium"
    )
}

// SatMesh statistics
struct SatMeshStats: Codable {
    let status: SatMeshStatus
    let satelliteConnection: Bool
    let messagesSent: Int
    let messagesReceived: Int
    let bytesTransmitted: Int
    let totalCost: Double
    let activeEmergencies: Int
    let routingEfficiency: Double
    let lastActivity: Date?
    let uptime: TimeInterval
}

protocol SatMeshIntegrationServiceDelegate: AnyObject {
    func satMeshStatusChanged(_ status: SatMeshStatus)
    func satMeshStatsUpdated(_ stats: SatMeshStats)
    func didReceiveGlobalMessage(_ message: BitchatMessage)
    func didReceiveEmergencyBroadcast(_ emergency: EmergencyMessage)
    func satelliteConnectionChanged(_ isConnected: Bool)
    func routingDecisionMade(_ decision: RoutingDecision)
}

class SatMeshIntegrationService: ObservableObject {
    static let shared = SatMeshIntegrationService()
    
    @Published var status: SatMeshStatus = .offline
    @Published var config: SatMeshConfig = .default
    @Published var stats: SatMeshStats
    @Published var isConnected: Bool = false
    
    weak var delegate: SatMeshIntegrationServiceDelegate?
    
    // Core services
    private let satelliteAdapter = SatelliteProtocolAdapter.shared
    private let routingEngine = MultiPathRoutingEngine.shared
    private let bandwidthOptimizer = BandwidthOptimizer.shared
    private let queueService = SatelliteQueueService.shared
    private let emergencySystem = EmergencyBroadcastSystem.shared
    
    // State management
    private var cancellables = Set<AnyCancellable>()
    private var startupTime = Date()
    private var lastActivityTime = Date()
    
    // Message tracking
    private var sentMessages: Int = 0
    private var receivedMessages: Int = 0
    private var bytesTransmitted: Int = 0
    private var totalCost: Double = 0
    
    init() {
        self.stats = SatMeshStats(
            status: .offline,
            satelliteConnection: false,
            messagesSent: 0,
            messagesReceived: 0,
            bytesTransmitted: 0,
            totalCost: 0,
            activeEmergencies: 0,
            routingEfficiency: 0,
            lastActivity: nil,
            uptime: 0
        )
        
        setupServiceIntegration()
        loadConfiguration()
    }
    
    // MARK: - Service Integration
    
    private func setupServiceIntegration() {
        // Set up satellite adapter delegate
        satelliteAdapter.delegate = self
        
        // Set up emergency system delegate
        emergencySystem.delegate = self
        
        // Set up queue service delegate
        queueService.delegate = self
        
        // Subscribe to service updates
        setupServiceSubscriptions()
        
        // Start services
        startSatMeshServices()
    }
    
    private func setupServiceSubscriptions() {
        // Monitor satellite connection
        satelliteAdapter.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                self?.handleSatelliteConnectionChange(isConnected)
            }
            .store(in: &cancellables)
        
        // Monitor emergency system status
        emergencySystem.$isEmergencyMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEmergencyMode in
                self?.handleEmergencyModeChange(isEmergencyMode)
            }
            .store(in: &cancellables)
        
        // Monitor queue statistics
        queueService.$queueStatistics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] queueStats in
                self?.handleQueueStatisticsUpdate(queueStats)
            }
            .store(in: &cancellables)
        
        // Monitor routing statistics
        routingEngine.$routingStats
            .receive(on: DispatchQueue.main)
            .sink { [weak self] routingStats in
                self?.handleRoutingStatisticsUpdate(routingStats)
            }
            .store(in: &cancellables)
    }
    
    private func startSatMeshServices() {
        // Start satellite adapter
        // (Already started in its init)
        
        // Start queue service transmission
        queueService.startTransmission()
        
        // Set up transmission window (simulated for now)
        let transmissionWindow = TransmissionWindow(
            startTime: Date(),
            endTime: Date().addingTimeInterval(300), // 5 minutes
            duration: 300,
            bandwidth: 2400, // Iridium SBD rate
            costPerByte: 0.000001,
            isEmergency: false
        )
        
        queueService.setTransmissionWindow(transmissionWindow)
        
        // Update status
        updateStatus(.connecting)
    }
    
    // MARK: - Message Handling
    
    func sendGlobalMessage(_ message: BitchatMessage, priority: UInt8 = 1) {
        guard config.enableSatellite else {
            print("Satellite messaging is disabled")
            return
        }
        
        // Optimize message for satellite transmission
        let messageData = (try? JSONEncoder().encode(message)) ?? Data()
        
        if let optimizedMessage = bandwidthOptimizer.optimizeForSatellite(messageData, priority: priority) {
            // Create routing request
            let routingRequest = RoutingRequest(
                messageID: message.id,
                senderID: message.senderPeerID ?? "unknown",
                recipientID: nil,
                messageType: .global,
                priority: priority,
                size: optimizedMessage.compressedMessage.count,
                maxLatency: nil,
                minReliability: 0.8,
                maxCost: config.costLimit,
                timestamp: Date()
            )
            
            // Get routing decision
            let routingDecision = routingEngine.routeMessage(routingRequest)
            
            // Notify delegate
            delegate?.routingDecisionMade(routingDecision)
            
            if let path = routingDecision.selectedPath {
                // Send via satellite
                let satellitePacket = SatellitePacket(
                    type: SatelliteMessageType.globalMessage.rawValue,
                    senderID: message.senderPeerID?.data(using: .utf8) ?? Data(),
                    recipientID: nil,
                    payload: optimizedMessage.compressedMessage,
                    priority: priority,
                    satelliteID: config.preferredSatellite
                )
                
                satelliteAdapter.sendSatelliteMessage(satellitePacket)
                
                // Update statistics
                sentMessages += 1
                bytesTransmitted += optimizedMessage.compressedMessage.count
                totalCost += optimizedMessage.estimatedCost
                lastActivityTime = Date()
                
                updateStats()
            } else {
                print("No suitable route found for global message")
            }
        }
    }
    
    func sendEmergencyMessage(_ emergency: EmergencyMessage) {
        guard config.enableEmergencyBroadcast else {
            print("Emergency broadcasting is disabled")
            return
        }
        
        // Use emergency system
        emergencySystem.broadcastEmergency(emergency)
        
        // Update statistics
        lastActivityTime = Date()
        updateStats()
    }
    
    func sendSOS(from location: CLLocationCoordinate2D? = nil) {
        emergencySystem.sendSOS(from: location)
    }
    
    // MARK: - Configuration Management
    
    func updateConfiguration(_ newConfig: SatMeshConfig) {
        config = newConfig
        saveConfiguration()
        
        // Apply configuration changes
        applyConfiguration()
    }
    
    private func applyConfiguration() {
        // Update bandwidth optimizer strategy based on cost limit
        if config.costLimit < 1.0 {
            bandwidthOptimizer.setOptimizationStrategy(.costOptimized)
        } else {
            bandwidthOptimizer.setOptimizationStrategy(.balancedCompression)
        }
        
        // Update queue service based on configuration
        if !config.enableSatellite {
            queueService.stopTransmission()
        } else {
            queueService.startTransmission()
        }
    }
    
    private func loadConfiguration() {
        // Load configuration from UserDefaults
        if let data = UserDefaults.standard.data(forKey: "satmesh.config"),
           let savedConfig = try? JSONDecoder().decode(SatMeshConfig.self, from: data) {
            config = savedConfig
        }
    }
    
    private func saveConfiguration() {
        // Save configuration to UserDefaults
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "satmesh.config")
        }
    }
    
    // MARK: - Status Management
    
    private func updateStatus(_ newStatus: SatMeshStatus) {
        status = newStatus
        updateStats()
        delegate?.satMeshStatusChanged(newStatus)
    }
    
    private func handleSatelliteConnectionChange(_ isConnected: Bool) {
        self.isConnected = isConnected
        
        if isConnected {
            updateStatus(.online)
        } else {
            updateStatus(.offline)
        }
        
        delegate?.satelliteConnectionChanged(isConnected)
    }
    
    private func handleEmergencyModeChange(_ isEmergencyMode: Bool) {
        if isEmergencyMode {
            updateStatus(.emergency)
        } else if isConnected {
            updateStatus(.online)
        } else {
            updateStatus(.offline)
        }
    }
    
    private func handleQueueStatisticsUpdate(_ queueStats: QueueStatistics) {
        // Update statistics based on queue service
        updateStats()
    }
    
    private func handleRoutingStatisticsUpdate(_ routingStats: MultiPathRoutingEngine.RoutingStatistics) {
        // Update routing efficiency
        let efficiency = routingStats.totalMessagesRouted > 0 ? 
            Double(routingStats.successfulDeliveries) / Double(routingStats.totalMessagesRouted) : 0
        
        stats.routingEfficiency = efficiency
        updateStats()
    }
    
    private func updateStats() {
        let uptime = Date().timeIntervalSince(startupTime)
        
        stats = SatMeshStats(
            status: status,
            satelliteConnection: isConnected,
            messagesSent: sentMessages,
            messagesReceived: receivedMessages,
            bytesTransmitted: bytesTransmitted,
            totalCost: totalCost,
            activeEmergencies: emergencySystem.activeEmergencies.count,
            routingEfficiency: stats.routingEfficiency,
            lastActivity: lastActivityTime,
            uptime: uptime
        )
        
        delegate?.satMeshStatsUpdated(stats)
    }
    
    // MARK: - Network Topology Management
    
    func addNetworkNode(_ node: NetworkNode) {
        routingEngine.currentTopology.addNode(node)
    }
    
    func removeNetworkNode(_ nodeID: String) {
        routingEngine.currentTopology.removeNode(nodeID)
    }
    
    func getNetworkTopology() -> [NetworkNode] {
        return Array(routingEngine.currentTopology.nodes.values)
    }
    
    // MARK: - Emergency Contact Management
    
    func addEmergencyContact(_ contact: EmergencyContact) {
        emergencySystem.addEmergencyContact(contact)
    }
    
    func removeEmergencyContact(_ contactID: String) {
        emergencySystem.removeEmergencyContact(contactID)
    }
    
    func getEmergencyContacts() -> [EmergencyContact] {
        return emergencySystem.emergencyContacts
    }
    
    func syncEmergencyContacts() {
        emergencySystem.syncEmergencyContacts()
    }
    
    // MARK: - Public Interface
    
    func getSatMeshStatus() -> SatMeshStatus {
        return status
    }
    
    func getSatMeshStats() -> SatMeshStats {
        return stats
    }
    
    func getActiveEmergencies() -> [EmergencyMessage] {
        return emergencySystem.activeEmergencies
    }
    
    func getEmergencyHistory() -> [EmergencyMessage] {
        return emergencySystem.emergencyHistory
    }
    
    func getQueueStatus() -> (emergency: Int, high: Int, normal: Int, low: Int, background: Int) {
        return queueService.getQueueStatus()
    }
    
    func getBandwidthStats() -> (totalBytesSaved: Int, averageCompressionRatio: Double, totalCost: Double) {
        return bandwidthOptimizer.getOptimizationStatistics()
    }
    
    func getRoutingStats() -> MultiPathRoutingEngine.RoutingStatistics {
        return routingEngine.getRoutingStatistics()
    }
    
    func clearAllData() {
        // Clear all service data
        bandwidthOptimizer.clearCache()
        queueService.clearQueue()
        emergencySystem.clearEmergencyHistory()
        routingEngine.resetStatistics()
        
        // Reset statistics
        sentMessages = 0
        receivedMessages = 0
        bytesTransmitted = 0
        totalCost = 0
        
        updateStats()
    }
    
    func restartServices() {
        // Stop all services
        queueService.stopTransmission()
        
        // Restart services
        startSatMeshServices()
    }
    
    func enterMaintenanceMode() {
        updateStatus(.maintenance)
        queueService.stopTransmission()
    }
    
    func exitMaintenanceMode() {
        startSatMeshServices()
    }
}

// MARK: - Satellite Protocol Adapter Delegate

extension SatMeshIntegrationService: SatelliteProtocolAdapterDelegate {
    func didReceiveSatelliteMessage(_ message: SatellitePacket) {
        // Handle incoming satellite messages
        receivedMessages += 1
        lastActivityTime = Date()
        
        // Process based on message type
        switch message.type {
        case SatelliteMessageType.globalMessage.rawValue:
            if let bitchatMessage = try? JSONDecoder().decode(BitchatMessage.self, from: message.payload) {
                delegate?.didReceiveGlobalMessage(bitchatMessage)
            }
        case SatelliteMessageType.emergencySOS.rawValue:
            if let emergency = try? JSONDecoder().decode(EmergencyMessage.self, from: message.payload) {
                delegate?.didReceiveEmergencyBroadcast(emergency)
            }
        default:
            print("Received unknown satellite message type: \(message.type)")
        }
        
        updateStats()
    }
    
    func didUpdateGatewayStatus(_ status: SatelliteGatewayStatus) {
        // Handle gateway status updates
        print("Gateway status updated: \(status.gatewayID) - \(status.isOnline ? "Online" : "Offline")")
    }
    
    func didReceiveEmergencyBroadcast(_ emergency: EmergencyMessage) {
        // Handle emergency broadcasts
        delegate?.didReceiveEmergencyBroadcast(emergency)
    }
    
    func didUpdateGlobalAddresses(_ addresses: [GlobalAddress]) {
        // Handle global address updates
        print("Updated \(addresses.count) global addresses")
    }
    
    func satelliteConnectionChanged(_ isConnected: Bool) {
        // Handle satellite connection changes
        handleSatelliteConnectionChange(isConnected)
    }
}

// MARK: - Emergency Broadcast System Delegate

extension SatMeshIntegrationService: EmergencyBroadcastSystemDelegate {
    func didReceiveEmergency(_ emergency: EmergencyMessage) {
        // Handle emergency messages
        delegate?.didReceiveEmergencyBroadcast(emergency)
    }
    
    func didUpdateEmergencyStatus(_ emergency: EmergencyMessage) {
        // Handle emergency status updates
        updateStats()
    }
    
    func didReceiveEmergencyAcknowledgment(_ emergency: EmergencyMessage, responder: EmergencyResponder) {
        // Handle emergency acknowledgments
        print("Emergency acknowledged by: \(responder.responderNickname)")
    }
    
    func didReceiveEmergencyResponse(_ emergency: EmergencyMessage, responder: EmergencyResponder) {
        // Handle emergency responses
        print("Emergency response from: \(responder.responderNickname)")
    }
    
    func emergencyContactStatusChanged(_ contact: EmergencyContact) {
        // Handle emergency contact status changes
        print("Emergency contact status changed: \(contact.name) - \(contact.status.rawValue)")
    }
    
    func emergencyBroadcastStatsUpdated(_ stats: EmergencyBroadcastStats) {
        // Handle emergency broadcast statistics updates
        updateStats()
    }
}

// MARK: - Satellite Queue Service Delegate

extension SatMeshIntegrationService: SatelliteQueueServiceDelegate {
    func didQueueMessage(_ message: QueuedMessage) {
        // Handle queued messages
        print("Message queued: \(message.id) with priority: \(message.priority.displayName)")
    }
    
    func didTransmitMessage(_ message: QueuedMessage) {
        // Handle transmitted messages
        print("Message transmitted: \(message.id)")
    }
    
    func didFailToTransmitMessage(_ message: QueuedMessage, error: Error) {
        // Handle transmission failures
        print("Message transmission failed: \(message.id) - \(error.localizedDescription)")
    }
    
    func queueStatisticsUpdated(_ stats: QueueStatistics) {
        // Handle queue statistics updates
        handleQueueStatisticsUpdate(stats)
    }
    
    func transmissionWindowOpened(_ window: TransmissionWindow) {
        // Handle transmission window opening
        print("Transmission window opened: \(window.duration)s")
    }
    
    func transmissionWindowClosed(_ window: TransmissionWindow) {
        // Handle transmission window closing
        print("Transmission window closed")
    }
} 