//
// EmergencyBroadcastSystem.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CoreLocation
import Combine

// Emergency types
enum EmergencyType: String, Codable, CaseIterable {
    case sos = "sos"
    case medical = "medical"
    case disaster = "disaster"
    case security = "security"
    case weather = "weather"
    case fire = "fire"
    case flood = "flood"
    case earthquake = "earthquake"
    case tsunami = "tsunami"
    case civilUnrest = "civil_unrest"
    
    var displayName: String {
        switch self {
        case .sos: return "SOS"
        case .medical: return "Medical Emergency"
        case .disaster: return "Disaster"
        case .security: return "Security Threat"
        case .weather: return "Weather Emergency"
        case .fire: return "Fire"
        case .flood: return "Flood"
        case .earthquake: return "Earthquake"
        case .tsunami: return "Tsunami"
        case .civilUnrest: return "Civil Unrest"
        }
    }
    
    var priority: Int {
        switch self {
        case .sos: return 0
        case .medical: return 1
        case .security: return 2
        case .disaster, .fire, .flood, .earthquake, .tsunami: return 3
        case .weather: return 4
        case .civilUnrest: return 5
        }
    }
    
    var icon: String {
        switch self {
        case .sos: return "🚨"
        case .medical: return "🏥"
        case .disaster: return "💥"
        case .security: return "🔒"
        case .weather: return "🌪️"
        case .fire: return "🔥"
        case .flood: return "🌊"
        case .earthquake: return "🌋"
        case .tsunami: return "🌊"
        case .civilUnrest: return "⚔️"
        }
    }
}

// Emergency message structure
struct EmergencyMessage: Codable, Identifiable {
    let id: String
    let emergencyType: EmergencyType
    let senderID: String
    let senderNickname: String
    let content: String
    let location: LocationData?
    let timestamp: Date
    let expiresAt: Date
    let priority: Int
    let isAcknowledged: Bool
    let acknowledgmentCount: Int
    let responders: [EmergencyResponder]
    let status: EmergencyStatus
    
    enum EmergencyStatus: String, Codable {
        case active = "active"
        case acknowledged = "acknowledged"
        case responding = "responding"
        case resolved = "resolved"
        case expired = "expired"
    }
    
    init(emergencyType: EmergencyType, senderID: String, senderNickname: String, content: String, location: LocationData? = nil) {
        self.id = UUID().uuidString
        self.emergencyType = emergencyType
        self.senderID = senderID
        self.senderNickname = senderNickname
        self.content = content
        self.location = location
        self.timestamp = Date()
        self.expiresAt = Date().addingTimeInterval(3600) // 1 hour default
        self.priority = emergencyType.priority
        self.isAcknowledged = false
        self.acknowledgmentCount = 0
        self.responders = []
        self.status = .active
    }
    
    var isExpired: Bool {
        return Date() > expiresAt
    }
    
    var age: TimeInterval {
        return Date().timeIntervalSince(timestamp)
    }
}

// Location data for emergencies
struct LocationData: Codable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double?
    let altitude: Double?
    let timestamp: Date
    
    var coordinate: CLLocationCoordinate2D {
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    var clLocation: CLLocation {
        return CLLocation(
            coordinate: coordinate,
            altitude: altitude ?? 0,
            horizontalAccuracy: accuracy ?? 0,
            verticalAccuracy: 0,
            timestamp: timestamp
        )
    }
}

// Emergency responder information
struct EmergencyResponder: Codable, Identifiable {
    let id: String
    let responderID: String
    let responderNickname: String
    let responderType: ResponderType
    let location: LocationData?
    let estimatedArrivalTime: TimeInterval?
    let capabilities: [ResponderCapability]
    let contactInfo: ContactInfo?
    let timestamp: Date
    
    enum ResponderType: String, Codable {
        case emergencyServices = "emergency_services"
        case medical = "medical"
        case security = "security"
        case volunteer = "volunteer"
        case satellite = "satellite"
        case local = "local"
    }
    
    enum ResponderCapability: String, Codable {
        case medicalAid = "medical_aid"
        case rescue = "rescue"
        case evacuation = "evacuation"
        case communication = "communication"
        case transportation = "transportation"
        case supplies = "supplies"
        case coordination = "coordination"
    }
    
    struct ContactInfo: Codable {
        let phone: String?
        let email: String?
        let radioFrequency: String?
        let satelliteID: String?
    }
}

// Emergency contact
struct EmergencyContact: Codable, Identifiable {
    let id: String
    let name: String
    let phone: String?
    let email: String?
    let relationship: String?
    let isPrimary: Bool
    let location: LocationData?
    let lastSeen: Date?
    let status: ContactStatus
    
    enum ContactStatus: String, Codable {
        case available = "available"
        case unavailable = "unavailable"
        case responding = "responding"
        case unknown = "unknown"
    }
}

// Emergency broadcast statistics
struct EmergencyBroadcastStats: Codable {
    let totalEmergencies: Int
    let activeEmergencies: Int
    let resolvedEmergencies: Int
    let averageResponseTime: TimeInterval
    let totalResponders: Int
    let coverageArea: Double // square kilometers
    let lastEmergency: Date?
    let emergencyTypes: [EmergencyType: Int]
}

protocol EmergencyBroadcastSystemDelegate: AnyObject {
    func didReceiveEmergency(_ emergency: EmergencyMessage)
    func didUpdateEmergencyStatus(_ emergency: EmergencyMessage)
    func didReceiveEmergencyAcknowledgment(_ emergency: EmergencyMessage, responder: EmergencyResponder)
    func didReceiveEmergencyResponse(_ emergency: EmergencyMessage, responder: EmergencyResponder)
    func emergencyContactStatusChanged(_ contact: EmergencyContact)
    func emergencyBroadcastStatsUpdated(_ stats: EmergencyBroadcastStats)
}

class EmergencyBroadcastSystem: ObservableObject {
    static let shared = EmergencyBroadcastSystem()
    
    @Published var activeEmergencies: [EmergencyMessage] = []
    @Published var emergencyContacts: [EmergencyContact] = []
    @Published var emergencyStats: EmergencyBroadcastStats
    @Published var isEmergencyMode: Bool = false
    
    weak var delegate: EmergencyBroadcastSystemDelegate?
    
    // Services
    private let satelliteAdapter = SatelliteProtocolAdapter.shared
    private let routingEngine = MultiPathRoutingEngine.shared
    private let queueService = SatelliteQueueService.shared
    
    // Location services
    private let locationManager = CLLocationManager()
    private var currentLocation: CLLocation?
    
    // Emergency tracking
    private var emergencyHistory: [EmergencyMessage] = []
    private var responderRegistry: [String: EmergencyResponder] = [:]
    private var acknowledgmentRegistry: [String: Set<String>] = [:] // emergencyID -> responderIDs
    
    // Timers
    private var emergencyCheckTimer: Timer?
    private var contactSyncTimer: Timer?
    private var statsUpdateTimer: Timer?
    
    // Configuration
    private let maxActiveEmergencies = 100
    private let emergencyExpirationTime: TimeInterval = 3600 // 1 hour
    private let contactSyncInterval: TimeInterval = 300 // 5 minutes
    
    init() {
        self.emergencyStats = EmergencyBroadcastStats(
            totalEmergencies: 0,
            activeEmergencies: 0,
            resolvedEmergencies: 0,
            averageResponseTime: 0,
            totalResponders: 0,
            coverageArea: 0,
            lastEmergency: nil,
            emergencyTypes: [:]
        )
        
        setupLocationServices()
        startEmergencyServices()
        loadEmergencyContacts()
    }
    
    // MARK: - Emergency Broadcasting
    
    func broadcastEmergency(_ emergency: EmergencyMessage) {
        // Add to active emergencies
        activeEmergencies.append(emergency)
        emergencyHistory.append(emergency)
        
        // Maintain emergency list size
        if activeEmergencies.count > maxActiveEmergencies {
            activeEmergencies.removeFirst()
        }
        
        // Update statistics
        updateEmergencyStats()
        
        // Broadcast via satellite with highest priority
        broadcastViaSatellite(emergency)
        
        // Broadcast via local mesh
        broadcastViaLocalMesh(emergency)
        
        // Notify emergency contacts
        notifyEmergencyContacts(emergency)
        
        // Notify delegate
        delegate?.didReceiveEmergency(emergency)
        
        // Set emergency mode if this is a high-priority emergency
        if emergency.priority <= 2 {
            isEmergencyMode = true
        }
    }
    
    func sendSOS(from location: CLLocationCoordinate2D? = nil) {
        let locationData = location != nil ? LocationData(
            latitude: location!.latitude,
            longitude: location!.longitude,
            accuracy: nil,
            altitude: nil,
            timestamp: Date()
        ) : nil
        
        let sosMessage = EmergencyMessage(
            emergencyType: .sos,
            senderID: getCurrentUserID(),
            senderNickname: getCurrentUserNickname(),
            content: "SOS - Need immediate assistance",
            location: locationData
        )
        
        broadcastEmergency(sosMessage)
    }
    
    func acknowledgeEmergency(_ emergency: EmergencyMessage, responder: EmergencyResponder) {
        // Add acknowledgment
        if acknowledgmentRegistry[emergency.id] == nil {
            acknowledgmentRegistry[emergency.id] = Set<String>()
        }
        acknowledgmentRegistry[emergency.id]?.insert(responder.id)
        
        // Update emergency status
        var updatedEmergency = emergency
        updatedEmergency.acknowledgmentCount += 1
        updatedEmergency.responders.append(responder)
        
        if updatedEmergency.acknowledgmentCount >= 1 {
            updatedEmergency.status = .acknowledged
        }
        
        // Update in active emergencies
        if let index = activeEmergencies.firstIndex(where: { $0.id == emergency.id }) {
            activeEmergencies[index] = updatedEmergency
        }
        
        // Notify delegate
        delegate?.didReceiveEmergencyAcknowledgment(updatedEmergency, responder: responder)
        
        // Broadcast acknowledgment
        broadcastAcknowledgment(updatedEmergency, responder: responder)
    }
    
    func respondToEmergency(_ emergency: EmergencyMessage, responder: EmergencyResponder) {
        // Update emergency status
        var updatedEmergency = emergency
        updatedEmergency.status = .responding
        updatedEmergency.responders.append(responder)
        
        // Update in active emergencies
        if let index = activeEmergencies.firstIndex(where: { $0.id == emergency.id }) {
            activeEmergencies[index] = updatedEmergency
        }
        
        // Register responder
        responderRegistry[responder.id] = responder
        
        // Notify delegate
        delegate?.didReceiveEmergencyResponse(updatedEmergency, responder: responder)
        
        // Broadcast response
        broadcastResponse(updatedEmergency, responder: responder)
    }
    
    func resolveEmergency(_ emergency: EmergencyMessage) {
        // Update emergency status
        var updatedEmergency = emergency
        updatedEmergency.status = .resolved
        
        // Move from active to history
        activeEmergencies.removeAll { $0.id == emergency.id }
        
        // Update statistics
        updateEmergencyStats()
        
        // Notify delegate
        delegate?.didUpdateEmergencyStatus(updatedEmergency)
        
        // Broadcast resolution
        broadcastResolution(updatedEmergency)
    }
    
    // MARK: - Emergency Contact Management
    
    func addEmergencyContact(_ contact: EmergencyContact) {
        emergencyContacts.append(contact)
        saveEmergencyContacts()
    }
    
    func removeEmergencyContact(_ contactID: String) {
        emergencyContacts.removeAll { $0.id == contactID }
        saveEmergencyContacts()
    }
    
    func updateContactStatus(_ contactID: String, status: EmergencyContact.ContactStatus) {
        if let index = emergencyContacts.firstIndex(where: { $0.id == contactID }) {
            var updatedContact = emergencyContacts[index]
            updatedContact.status = status
            updatedContact.lastSeen = Date()
            emergencyContacts[index] = updatedContact
            
            delegate?.emergencyContactStatusChanged(updatedContact)
        }
    }
    
    func syncEmergencyContacts() {
        // Synchronize emergency contacts across the network
        let contactData = emergencyContacts.map { contact in
            return [
                "id": contact.id,
                "name": contact.name,
                "phone": contact.phone ?? "",
                "email": contact.email ?? "",
                "relationship": contact.relationship ?? "",
                "isPrimary": contact.isPrimary,
                "status": contact.status.rawValue
            ]
        }
        
        // Send via satellite for global sync
        if let data = try? JSONEncoder().encode(contactData) {
            let message = BitchatMessage(
                sender: "emergency_system",
                content: "Emergency contact sync",
                timestamp: Date(),
                isRelay: false
            )
            
            satelliteAdapter.sendGlobalMessage(message, priority: 2) // High priority
        }
    }
    
    // MARK: - Satellite Integration
    
    private func broadcastViaSatellite(_ emergency: EmergencyMessage) {
        // Create satellite emergency packet
        let emergencyData = (try? JSONEncoder().encode(emergency)) ?? Data()
        
        let satellitePacket = SatellitePacket(
            type: SatelliteMessageType.emergencySOS.rawValue,
            senderID: emergency.senderID.data(using: .utf8)!,
            recipientID: nil,
            payload: emergencyData,
            priority: 3, // Emergency priority
            satelliteID: "iridium" // Use Iridium for emergencies
        )
        
        // Send via satellite adapter
        satelliteAdapter.sendSatelliteMessage(satellitePacket)
        
        // Also queue for store-and-forward
        let queuedMessage = QueuedMessage(
            messageData: emergencyData,
            priority: .emergency,
            senderID: emergency.senderID,
            messageType: "emergency",
            estimatedCost: 0.0, // Emergency messages are free
            compressionRatio: 1.0,
            isEmergency: true
        )
        
        queueService.enqueueMessage(queuedMessage)
    }
    
    private func broadcastViaLocalMesh(_ emergency: EmergencyMessage) {
        // Create local emergency message
        let localMessage = BitchatMessage(
            sender: "emergency_system",
            content: "\(emergency.emergencyType.icon) \(emergency.emergencyType.displayName): \(emergency.content)",
            timestamp: Date(),
            isRelay: false,
            originalSender: emergency.senderNickname
        )
        
        // This would integrate with the existing BluetoothMeshService
        // For now, we'll notify the delegate
        delegate?.didReceiveEmergency(localMessage)
    }
    
    private func broadcastAcknowledgment(_ emergency: EmergencyMessage, responder: EmergencyResponder) {
        let acknowledgmentData = [
            "emergencyID": emergency.id,
            "responderID": responder.id,
            "responderType": responder.responderType.rawValue,
            "timestamp": Date().timeIntervalSince1970
        ] as [String: Any]
        
        if let data = try? JSONSerialization.data(withJSONObject: acknowledgmentData) {
            let satellitePacket = SatellitePacket(
                type: SatelliteMessageType.satelliteAck.rawValue,
                senderID: responder.responderID.data(using: .utf8)!,
                recipientID: nil,
                payload: data,
                priority: 2
            )
            
            satelliteAdapter.sendSatelliteMessage(satellitePacket)
        }
    }
    
    private func broadcastResponse(_ emergency: EmergencyMessage, responder: EmergencyResponder) {
        let responseData = [
            "emergencyID": emergency.id,
            "responderID": responder.id,
            "estimatedArrivalTime": responder.estimatedArrivalTime ?? 0,
            "capabilities": responder.capabilities.map { $0.rawValue },
            "timestamp": Date().timeIntervalSince1970
        ] as [String: Any]
        
        if let data = try? JSONSerialization.data(withJSONObject: responseData) {
            let satellitePacket = SatellitePacket(
                type: SatelliteMessageType.disasterRelay.rawValue,
                senderID: responder.responderID.data(using: .utf8)!,
                recipientID: nil,
                payload: data,
                priority: 2
            )
            
            satelliteAdapter.sendSatelliteMessage(satellitePacket)
        }
    }
    
    private func broadcastResolution(_ emergency: EmergencyMessage) {
        let resolutionData = [
            "emergencyID": emergency.id,
            "resolutionTime": Date().timeIntervalSince1970,
            "totalResponders": emergency.responders.count
        ] as [String: Any]
        
        if let data = try? JSONSerialization.data(withJSONObject: resolutionData) {
            let satellitePacket = SatellitePacket(
                type: SatelliteMessageType.satelliteAck.rawValue,
                senderID: emergency.senderID.data(using: .utf8)!,
                recipientID: nil,
                payload: data,
                priority: 1
            )
            
            satelliteAdapter.sendSatelliteMessage(satellitePacket)
        }
    }
    
    // MARK: - Emergency Contact Notifications
    
    private func notifyEmergencyContacts(_ emergency: EmergencyMessage) {
        for contact in emergencyContacts {
            if contact.isPrimary || emergency.priority <= 2 {
                // Send notification to emergency contact
                sendEmergencyNotification(to: contact, for: emergency)
            }
        }
    }
    
    private func sendEmergencyNotification(to contact: EmergencyContact, for emergency: EmergencyMessage) {
        let notificationContent = "\(emergency.emergencyType.icon) Emergency: \(emergency.content) from \(emergency.senderNickname)"
        
        // Create notification message
        let notificationMessage = BitchatMessage(
            sender: "emergency_system",
            content: notificationContent,
            timestamp: Date(),
            isRelay: false
        )
        
        // Send via satellite if contact is not local
        if contact.status == .unavailable || contact.status == .unknown {
            satelliteAdapter.sendGlobalMessage(notificationMessage, priority: 3)
        }
    }
    
    // MARK: - Location Services
    
    private func setupLocationServices() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
        
        // Start location updates
        locationManager.startUpdatingLocation()
    }
    
    func getCurrentLocation() -> CLLocationCoordinate2D? {
        return currentLocation?.coordinate
    }
    
    // MARK: - Statistics and Monitoring
    
    private func updateEmergencyStats() {
        let totalEmergencies = emergencyHistory.count
        let activeEmergencies = self.activeEmergencies.count
        let resolvedEmergencies = emergencyHistory.filter { $0.status == .resolved }.count
        
        // Calculate average response time
        let responseTimes = emergencyHistory.compactMap { emergency -> TimeInterval? in
            guard let firstResponder = emergency.responders.first else { return nil }
            return firstResponder.timestamp.timeIntervalSince(emergency.timestamp)
        }
        
        let averageResponseTime = responseTimes.isEmpty ? 0 : responseTimes.reduce(0, +) / Double(responseTimes.count)
        
        // Calculate coverage area (simplified)
        let coverageArea = calculateCoverageArea()
        
        // Count emergency types
        var emergencyTypes: [EmergencyType: Int] = [:]
        for emergency in emergencyHistory {
            emergencyTypes[emergency.emergencyType, default: 0] += 1
        }
        
        emergencyStats = EmergencyBroadcastStats(
            totalEmergencies: totalEmergencies,
            activeEmergencies: activeEmergencies,
            resolvedEmergencies: resolvedEmergencies,
            averageResponseTime: averageResponseTime,
            totalResponders: responderRegistry.count,
            coverageArea: coverageArea,
            lastEmergency: emergencyHistory.last?.timestamp,
            emergencyTypes: emergencyTypes
        )
        
        delegate?.emergencyBroadcastStatsUpdated(emergencyStats)
    }
    
    private func calculateCoverageArea() -> Double {
        // Simplified coverage area calculation
        // In a real implementation, this would calculate the actual coverage area
        return 1000.0 // 1000 square kilometers
    }
    
    // MARK: - Service Management
    
    private func startEmergencyServices() {
        // Start emergency check timer
        emergencyCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkEmergencyStatus()
        }
        
        // Start contact sync timer
        contactSyncTimer = Timer.scheduledTimer(withTimeInterval: contactSyncInterval, repeats: true) { [weak self] _ in
            self?.syncEmergencyContacts()
        }
        
        // Start stats update timer
        statsUpdateTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.updateEmergencyStats()
        }
    }
    
    private func checkEmergencyStatus() {
        // Check for expired emergencies
        let now = Date()
        let expiredEmergencies = activeEmergencies.filter { $0.isExpired }
        
        for emergency in expiredEmergencies {
            var updatedEmergency = emergency
            updatedEmergency.status = .expired
            activeEmergencies.removeAll { $0.id == emergency.id }
            
            delegate?.didUpdateEmergencyStatus(updatedEmergency)
        }
        
        // Update emergency mode status
        isEmergencyMode = !activeEmergencies.filter { $0.priority <= 2 }.isEmpty
    }
    
    // MARK: - Data Persistence
    
    private func loadEmergencyContacts() {
        // Load emergency contacts from UserDefaults or other storage
        // This is a placeholder implementation
        let defaultContacts = [
            EmergencyContact(
                id: UUID().uuidString,
                name: "Emergency Services",
                phone: "911",
                email: nil,
                relationship: "Emergency",
                isPrimary: true,
                location: nil,
                lastSeen: nil,
                status: .available
            )
        ]
        
        emergencyContacts = defaultContacts
    }
    
    private func saveEmergencyContacts() {
        // Save emergency contacts to persistent storage
        // This is a placeholder implementation
    }
    
    // MARK: - Utility Methods
    
    private func getCurrentUserID() -> String {
        // Get current user ID from the main app
        return "user-\(UUID().uuidString.prefix(8))"
    }
    
    private func getCurrentUserNickname() -> String {
        // Get current user nickname from the main app
        return "User"
    }
    
    // MARK: - Public Interface
    
    func getActiveEmergencies() -> [EmergencyMessage] {
        return activeEmergencies
    }
    
    func getEmergencyHistory() -> [EmergencyMessage] {
        return emergencyHistory
    }
    
    func getEmergencyById(_ id: String) -> EmergencyMessage? {
        return activeEmergencies.first { $0.id == id } ?? emergencyHistory.first { $0.id == id }
    }
    
    func getRespondersForEmergency(_ emergencyID: String) -> [EmergencyResponder] {
        return responderRegistry.values.filter { responder in
            responder.id == emergencyID
        }
    }
    
    func clearEmergencyHistory() {
        emergencyHistory.removeAll()
        updateEmergencyStats()
    }
    
    func enterEmergencyMode() {
        isEmergencyMode = true
    }
    
    func exitEmergencyMode() {
        isEmergencyMode = false
    }
}

// MARK: - CLLocationManagerDelegate

extension EmergencyBroadcastSystem: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentLocation = locations.last
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager failed with error: \(error)")
    }
} 