//
// MeshtasticFallbackManager.swift
// BitChat Meshtastic Integration
//
// Manages the fallback chain: BLE → Meshtastic antenna → Meshtastic tower → broadcast
//

import Foundation
import SwiftUI

@MainActor
class MeshtasticFallbackManager: ObservableObject {
    @Published var isEnabled = false
    @Published var autoFallbackEnabled = true
    @Published var userConsented = false
    @Published var currentStatus: MeshtasticStatus = .disabled
    @Published var fallbackThreshold: TimeInterval = 30.0
    @Published var preferredDeviceId: String?
    @Published var lastFallbackAttempt: Date?
    @Published var fallbackSuccessRate: Double = 0.0
    
    private let bridge = MeshtasticBridge.shared
    private let userDefaults = UserDefaults.standard
    private var fallbackQueue: [PendingMessage] = []
    private var successfulFallbacks = 0
    private var totalFallbackAttempts = 0
    
    static let shared = MeshtasticFallbackManager()
    
    private struct PendingMessage {
        let content: String
        let messageType: Int
        let channel: String?
        let priority: Int
        let timestamp: Date
        let retryCount: Int
        let maxRetries: Int
        
        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > 300 // 5 minutes
        }
    }
    
    private init() {
        loadSettings()
        setupBridgeMonitoring()
    }
    
    func requestUserConsent() async -> Bool {
        // This would show a user consent dialog
        // For now, we'll simulate user consent
        await showConsentDialog()
    }
    
    @MainActor
    private func showConsentDialog() async -> Bool {
        return await withCheckedContinuation { continuation in
            // In a real implementation, this would show a SwiftUI alert
            // For now, we'll return true to simulate consent
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.userConsented = true
                self.isEnabled = true
                self.saveSettings()
                continuation.resume(returning: true)
            }
        }
    }
    
    func enableMeshtasticIntegration() async -> Bool {
        guard !isEnabled else { return true }
        
        // Request user consent first
        let consented = await requestUserConsent()
        guard consented else { return false }
        
        // Start the bridge service
        let bridgeStarted = await bridge.startBridge()
        
        if bridgeStarted {
            isEnabled = true
            currentStatus = .checkingMeshtastic
            saveSettings()
            
            // Scan for devices
            await scanForDevices()
            
            return true
        } else {
            isEnabled = false
            currentStatus = .fallbackFailed
            return false
        }
    }
    
    func disableMeshtasticIntegration() {
        isEnabled = false
        userConsented = false
        bridge.stopBridge()
        currentStatus = .disabled
        saveSettings()
    }
    
    func scanForDevices() async {
        guard isEnabled else { return }
        
        currentStatus = .checkingMeshtastic
        let devices = await bridge.scanDevices()
        
        if devices.isEmpty {
            currentStatus = .fallbackFailed
        } else {
            // Auto-connect to preferred device or first available
            let deviceToConnect = preferredDeviceId.flatMap { prefId in
                devices.first { $0.deviceId == prefId }
            } ?? devices.first
            
            if let device = deviceToConnect {
                let connected = await bridge.connectToDevice(device.deviceId)
                currentStatus = connected ? .meshtasticActive : .fallbackFailed
            }
        }
    }
    
    func checkAvailability() async -> Bool {
        guard isEnabled && userConsented else { return false }
        
        // Check if bridge is running
        if !bridge.isConnected {
            let started = await bridge.startBridge()
            if !started { return false }
        }
        
        // Check if we have devices
        if bridge.availableDevices.isEmpty {
            await scanForDevices()
        }
        
        // Try to connect if not already connected
        if currentStatus != .meshtasticActive {
            let connected = await bridge.connectToDevice(preferredDeviceId)
            return connected
        }
        
        return currentStatus == .meshtasticActive
    }
    
    func sendMessageViaFallback(
        content: String,
        messageType: Int = 0,
        channel: String? = nil,
        priority: Int = 1
    ) async -> Bool {
        guard isEnabled && currentStatus == .meshtasticActive else {
            return false
        }
        
        let message = MeshtasticMessage(
            messageId: UUID().uuidString,
            senderId: getUserId(),
            senderName: getUserName(),
            content: content,
            messageType: messageType,
            channel: channel,
            timestamp: Int(Date().timeIntervalSince1970),
            ttl: 7,
            encrypted: false
        )
        
        lastFallbackAttempt = Date()
        totalFallbackAttempts += 1
        
        let success = await bridge.sendMessage(message)
        
        if success {
            successfulFallbacks += 1
            updateSuccessRate()
            
            // Post notification for UI updates
            NotificationCenter.default.post(
                name: NSNotification.Name("MeshtasticMessageSent"),
                object: nil,
                userInfo: [
                    "content": content,
                    "channel": channel as Any,
                    "success": true
                ]
            )
        } else {
            // Queue for retry
            queueMessageForRetry(content: content, messageType: messageType, channel: channel, priority: priority)
        }
        
        return success
    }
    
    func handleBitChatMessageFallback(
        binaryMessage: Data,
        channel: String? = nil
    ) async -> Bool {
        // Convert BitChat binary message to text for Meshtastic
        // This is a simplified conversion - in practice, you'd need to parse
        // the actual BitChat binary protocol
        
        let content = String(data: binaryMessage, encoding: .utf8) ?? "Binary message"
        return await sendMessageViaFallback(content: content, channel: channel)
    }
    
    private func queueMessageForRetry(
        content: String,
        messageType: Int,
        channel: String?,
        priority: Int,
        retryCount: Int = 0
    ) {
        let pendingMessage = PendingMessage(
            content: content,
            messageType: messageType,
            channel: channel,
            priority: priority,
            timestamp: Date(),
            retryCount: retryCount,
            maxRetries: 3
        )
        
        fallbackQueue.append(pendingMessage)
        
        // Start retry timer if needed
        scheduleRetryProcessing()
    }
    
    private func scheduleRetryProcessing() {
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            await processRetryQueue()
        }
    }
    
    private func processRetryQueue() async {
        guard !fallbackQueue.isEmpty else { return }
        
        // Remove expired messages
        fallbackQueue.removeAll { $0.isExpired }
        
        // Process pending messages by priority
        fallbackQueue.sort { $0.priority > $1.priority }
        
        var toRemove: [Int] = []
        
        for (index, message) in fallbackQueue.enumerated() {
            if message.retryCount >= message.maxRetries {
                toRemove.append(index)
                continue
            }
            
            let success = await sendMessageViaFallback(
                content: message.content,
                messageType: message.messageType,
                channel: message.channel,
                priority: message.priority
            )
            
            if success {
                toRemove.append(index)
            } else {
                // Update retry count
                fallbackQueue[index] = PendingMessage(
                    content: message.content,
                    messageType: message.messageType,
                    channel: message.channel,
                    priority: message.priority,
                    timestamp: message.timestamp,
                    retryCount: message.retryCount + 1,
                    maxRetries: message.maxRetries
                )
            }
        }
        
        // Remove processed messages (in reverse order to maintain indices)
        for index in toRemove.reversed() {
            fallbackQueue.remove(at: index)
        }
        
        // Schedule next retry if queue is not empty
        if !fallbackQueue.isEmpty {
            scheduleRetryProcessing()
        }
    }
    
    private func setupBridgeMonitoring() {
        // Monitor bridge status changes
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("MeshtasticStatusChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let status = notification.userInfo?["status"] as? String,
               let meshtasticStatus = MeshtasticStatus(rawValue: status) {
                self?.currentStatus = meshtasticStatus
            }
        }
    }
    
    private func updateSuccessRate() {
        fallbackSuccessRate = totalFallbackAttempts > 0 ? 
            Double(successfulFallbacks) / Double(totalFallbackAttempts) : 0.0
    }
    
    private func getUserId() -> String {
        // Get user ID from BitChat system or generate one
        return userDefaults.string(forKey: "BitChatUserId") ?? "meshtastic_user"
    }
    
    private func getUserName() -> String {
        // Get user name from BitChat system
        return userDefaults.string(forKey: "BitChatUserName") ?? "MeshtasticUser"
    }
    
    // MARK: - Settings Management
    
    private func loadSettings() {
        isEnabled = userDefaults.bool(forKey: "MeshtasticEnabled")
        autoFallbackEnabled = userDefaults.bool(forKey: "MeshtasticAutoFallback")
        userConsented = userDefaults.bool(forKey: "MeshtasticUserConsented")
        fallbackThreshold = userDefaults.double(forKey: "MeshtasticFallbackThreshold")
        preferredDeviceId = userDefaults.string(forKey: "MeshtasticPreferredDevice")
        successfulFallbacks = userDefaults.integer(forKey: "MeshtasticSuccessfulFallbacks")
        totalFallbackAttempts = userDefaults.integer(forKey: "MeshtasticTotalAttempts")
        
        if fallbackThreshold == 0 {
            fallbackThreshold = 30.0 // Default 30 seconds
        }
        
        updateSuccessRate()
    }
    
    private func saveSettings() {
        userDefaults.set(isEnabled, forKey: "MeshtasticEnabled")
        userDefaults.set(autoFallbackEnabled, forKey: "MeshtasticAutoFallback")
        userDefaults.set(userConsented, forKey: "MeshtasticUserConsented")
        userDefaults.set(fallbackThreshold, forKey: "MeshtasticFallbackThreshold")
        userDefaults.set(preferredDeviceId, forKey: "MeshtasticPreferredDevice")
        userDefaults.set(successfulFallbacks, forKey: "MeshtasticSuccessfulFallbacks")
        userDefaults.set(totalFallbackAttempts, forKey: "MeshtasticTotalAttempts")
    }
    
    // MARK: - Public Configuration Methods
    
    func setAutoFallback(_ enabled: Bool) {
        autoFallbackEnabled = enabled
        saveSettings()
    }
    
    func setFallbackThreshold(_ threshold: TimeInterval) {
        fallbackThreshold = max(10.0, min(300.0, threshold)) // Between 10s and 5min
        saveSettings()
    }
    
    func setPreferredDevice(_ deviceId: String?) {
        preferredDeviceId = deviceId
        saveSettings()
    }
    
    func getStatistics() -> [String: Any] {
        return [
            "enabled": isEnabled,
            "user_consented": userConsented,
            "success_rate": fallbackSuccessRate,
            "total_attempts": totalFallbackAttempts,
            "successful_fallbacks": successfulFallbacks,
            "pending_messages": fallbackQueue.count,
            "last_attempt": lastFallbackAttempt?.timeIntervalSince1970 ?? 0,
            "current_status": currentStatus.rawValue
        ]
    }
}
