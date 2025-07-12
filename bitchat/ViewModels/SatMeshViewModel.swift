//
// SatMeshViewModel.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import SwiftUI
import Combine
import CoreLocation

class SatMeshViewModel: ObservableObject {
    @Published var isSatMeshEnabled: Bool = false
    @Published var satelliteStatus: SatMeshStatus = .offline
    @Published var isConnected: Bool = false
    @Published var activeEmergencies: [EmergencyMessage] = []
    @Published var emergencyContacts: [EmergencyContact] = []
    @Published var globalMessages: [BitchatMessage] = []
    @Published var queueStatus: (emergency: Int, high: Int, normal: Int, low: Int, background: Int) = (0, 0, 0, 0, 0)
    @Published var bandwidthStats: (totalBytesSaved: Int, averageCompressionRatio: Double, totalCost: Double) = (0, 0, 0)
    @Published var routingStats: MultiPathRoutingEngine.RoutingStatistics = MultiPathRoutingEngine.RoutingStatistics()
    @Published var networkTopology: [NetworkNode] = []
    @Published var showEmergencyPanel: Bool = false
    @Published var showSatellitePanel: Bool = false
    @Published var showGlobalChat: Bool = false
    
    // Emergency UI state
    @Published var emergencyMessage: String = ""
    @Published var selectedEmergencyType: EmergencyType = .sos
    @Published var includeLocation: Bool = true
    @Published var isSendingEmergency: Bool = false
    
    // Global messaging UI state
    @Published var globalMessageText: String = ""
    @Published var globalMessagePriority: UInt8 = 1
    @Published var isSendingGlobal: Bool = false
    
    // Configuration UI state
    @Published var showConfiguration: Bool = false
    @Published var config: SatMeshConfig = .default
    
    // Services
    private let satMeshService = SatMeshIntegrationService.shared
    private let locationManager = CLLocationManager()
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupLocationManager()
        setupServiceIntegration()
        loadUserPreferences()
    }
    
    // MARK: - Service Integration
    
    private func setupServiceIntegration() {
        // Set up SatMesh service delegate
        satMeshService.delegate = self
        
        // Subscribe to service updates
        satMeshService.$status
            .receive(on: DispatchQueue.main)
            .assign(to: \.satelliteStatus, on: self)
            .store(in: &cancellables)
        
        satMeshService.$isConnected
            .receive(on: DispatchQueue.main)
            .assign(to: \.isConnected, on: self)
            .store(in: &cancellables)
        
        satMeshService.$config
            .receive(on: DispatchQueue.main)
            .assign(to: \.config, on: self)
            .store(in: &cancellables)
        
        // Update UI state based on service status
        updateUIFromService()
    }
    
    private func updateUIFromService() {
        // Update enabled state based on configuration
        isSatMeshEnabled = config.enableSatellite
        
        // Update active emergencies
        activeEmergencies = satMeshService.getActiveEmergencies()
        
        // Update emergency contacts
        emergencyContacts = satMeshService.getEmergencyContacts()
        
        // Update queue status
        queueStatus = satMeshService.getQueueStatus()
        
        // Update bandwidth stats
        bandwidthStats = satMeshService.getBandwidthStats()
        
        // Update routing stats
        routingStats = satMeshService.getRoutingStats()
        
        // Update network topology
        networkTopology = satMeshService.getNetworkTopology()
    }
    
    // MARK: - Emergency Functions
    
    func sendSOS() {
        guard isSatMeshEnabled else {
            showAlert(title: "SatMesh Disabled", message: "Please enable satellite messaging in settings.")
            return
        }
        
        isSendingEmergency = true
        
        let location = includeLocation ? getCurrentLocation() : nil
        satMeshService.sendSOS(from: location)
        
        // Reset UI after sending
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isSendingEmergency = false
            self.showAlert(title: "SOS Sent", message: "Emergency SOS message has been broadcast via satellite.")
        }
    }
    
    func sendEmergencyMessage() {
        guard !emergencyMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showAlert(title: "Empty Message", message: "Please enter an emergency message.")
            return
        }
        
        guard isSatMeshEnabled else {
            showAlert(title: "SatMesh Disabled", message: "Please enable satellite messaging in settings.")
            return
        }
        
        isSendingEmergency = true
        
        let location = includeLocation ? getCurrentLocation() : nil
        let locationData = location != nil ? LocationData(
            latitude: location!.latitude,
            longitude: location!.longitude,
            accuracy: nil,
            altitude: nil,
            timestamp: Date()
        ) : nil
        
        let emergency = EmergencyMessage(
            emergencyType: selectedEmergencyType,
            senderID: getCurrentUserID(),
            senderNickname: getCurrentUserNickname(),
            content: emergencyMessage,
            location: locationData
        )
        
        satMeshService.sendEmergencyMessage(emergency)
        
        // Reset UI after sending
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isSendingEmergency = false
            self.emergencyMessage = ""
            self.showAlert(title: "Emergency Sent", message: "Emergency message has been broadcast via satellite.")
        }
    }
    
    // MARK: - Global Messaging
    
    func sendGlobalMessage() {
        guard !globalMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showAlert(title: "Empty Message", message: "Please enter a message to send globally.")
            return
        }
        
        guard isSatMeshEnabled else {
            showAlert(title: "SatMesh Disabled", message: "Please enable satellite messaging in settings.")
            return
        }
        
        isSendingGlobal = true
        
        let globalMessage = BitchatMessage(
            sender: getCurrentUserNickname(),
            content: globalMessageText,
            timestamp: Date(),
            isRelay: false,
            senderPeerID: getCurrentUserID()
        )
        
        satMeshService.sendGlobalMessage(globalMessage, priority: globalMessagePriority)
        
        // Add to local global messages
        globalMessages.append(globalMessage)
        
        // Reset UI after sending
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isSendingGlobal = false
            self.globalMessageText = ""
            self.showAlert(title: "Message Sent", message: "Global message has been sent via satellite.")
        }
    }
    
    // MARK: - Emergency Contact Management
    
    func addEmergencyContact(name: String, phone: String?, email: String?, relationship: String?) {
        let contact = EmergencyContact(
            id: UUID().uuidString,
            name: name,
            phone: phone,
            email: email,
            relationship: relationship,
            isPrimary: false,
            location: nil,
            lastSeen: nil,
            status: .unknown
        )
        
        satMeshService.addEmergencyContact(contact)
        emergencyContacts = satMeshService.getEmergencyContacts()
    }
    
    func removeEmergencyContact(_ contactID: String) {
        satMeshService.removeEmergencyContact(contactID)
        emergencyContacts = satMeshService.getEmergencyContacts()
    }
    
    func syncEmergencyContacts() {
        satMeshService.syncEmergencyContacts()
        showAlert(title: "Contacts Synced", message: "Emergency contacts have been synchronized across the satellite network.")
    }
    
    // MARK: - Configuration Management
    
    func updateConfiguration() {
        satMeshService.updateConfiguration(config)
        saveUserPreferences()
        showAlert(title: "Configuration Updated", message: "SatMesh configuration has been updated.")
    }
    
    func resetConfiguration() {
        config = SatMeshConfig.default
        satMeshService.updateConfiguration(config)
        saveUserPreferences()
        showAlert(title: "Configuration Reset", message: "SatMesh configuration has been reset to defaults.")
    }
    
    // MARK: - Network Management
    
    func refreshNetworkTopology() {
        networkTopology = satMeshService.getNetworkTopology()
    }
    
    func clearAllData() {
        satMeshService.clearAllData()
        updateUIFromService()
        showAlert(title: "Data Cleared", message: "All SatMesh data has been cleared.")
    }
    
    func restartServices() {
        satMeshService.restartServices()
        showAlert(title: "Services Restarted", message: "SatMesh services have been restarted.")
    }
    
    // MARK: - Location Services
    
    private func setupLocationManager() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
    }
    
    private func getCurrentLocation() -> CLLocationCoordinate2D? {
        return locationManager.location?.coordinate
    }
    
    // MARK: - User Preferences
    
    private func loadUserPreferences() {
        // Load user preferences from UserDefaults
        if let data = UserDefaults.standard.data(forKey: "satmesh.preferences"),
           let preferences = try? JSONDecoder().decode([String: Any].self, from: data) {
            // Apply saved preferences
            if let enabled = preferences["enabled"] as? Bool {
                isSatMeshEnabled = enabled
            }
        }
    }
    
    private func saveUserPreferences() {
        // Save user preferences to UserDefaults
        let preferences: [String: Any] = [
            "enabled": isSatMeshEnabled
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: preferences) {
            UserDefaults.standard.set(data, forKey: "satmesh.preferences")
        }
    }
    
    // MARK: - Utility Functions
    
    private func getCurrentUserID() -> String {
        // Get current user ID from the main app
        return "user-\(UUID().uuidString.prefix(8))"
    }
    
    private func getCurrentUserNickname() -> String {
        // Get current user nickname from the main app
        return "User"
    }
    
    private func showAlert(title: String, message: String) {
        // Show alert to user
        // In a real implementation, this would use SwiftUI's alert system
        print("Alert: \(title) - \(message)")
    }
    
    // MARK: - UI State Management
    
    func toggleEmergencyPanel() {
        showEmergencyPanel.toggle()
    }
    
    func toggleSatellitePanel() {
        showSatellitePanel.toggle()
    }
    
    func toggleGlobalChat() {
        showGlobalChat.toggle()
    }
    
    func toggleConfiguration() {
        showConfiguration.toggle()
    }
    
    // MARK: - Statistics Formatting
    
    func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    func formatCost(_ cost: Double) -> String {
        return String(format: "$%.4f", cost)
    }
    
    func formatUptime(_ uptime: TimeInterval) -> String {
        let hours = Int(uptime) / 3600
        let minutes = Int(uptime) % 3600 / 60
        return String(format: "%02d:%02d", hours, minutes)
    }
    
    func formatQueueStatus() -> String {
        let total = queueStatus.emergency + queueStatus.high + queueStatus.normal + queueStatus.low + queueStatus.background
        return "\(total) messages queued"
    }
    
    func getStatusColor() -> Color {
        switch satelliteStatus {
        case .offline:
            return .red
        case .connecting:
            return .orange
        case .online:
            return .green
        case .emergency:
            return .red
        case .maintenance:
            return .yellow
        }
    }
    
    func getStatusText() -> String {
        switch satelliteStatus {
        case .offline:
            return "Offline"
        case .connecting:
            return "Connecting..."
        case .online:
            return "Online"
        case .emergency:
            return "Emergency Mode"
        case .maintenance:
            return "Maintenance"
        }
    }
}

// MARK: - SatMesh Integration Service Delegate

extension SatMeshViewModel: SatMeshIntegrationServiceDelegate {
    func satMeshStatusChanged(_ status: SatMeshStatus) {
        DispatchQueue.main.async {
            self.satelliteStatus = status
        }
    }
    
    func satMeshStatsUpdated(_ stats: SatMeshStats) {
        DispatchQueue.main.async {
            // Update bandwidth stats
            self.bandwidthStats = (
                totalBytesSaved: stats.bytesTransmitted,
                averageCompressionRatio: 0.7, // Placeholder
                totalCost: stats.totalCost
            )
        }
    }
    
    func didReceiveGlobalMessage(_ message: BitchatMessage) {
        DispatchQueue.main.async {
            self.globalMessages.append(message)
        }
    }
    
    func didReceiveEmergencyBroadcast(_ emergency: EmergencyMessage) {
        DispatchQueue.main.async {
            self.activeEmergencies = self.satMeshService.getActiveEmergencies()
        }
    }
    
    func satelliteConnectionChanged(_ isConnected: Bool) {
        DispatchQueue.main.async {
            self.isConnected = isConnected
        }
    }
    
    func routingDecisionMade(_ decision: RoutingDecision) {
        // Handle routing decisions
        print("Routing decision: \(decision.routingStrategy.rawValue) - \(decision.reasoning)")
    }
} 