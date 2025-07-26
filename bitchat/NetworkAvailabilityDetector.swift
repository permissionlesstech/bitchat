//
// NetworkAvailabilityDetector.swift
// BitChat Meshtastic Integration
//
// Detects BLE mesh availability and triggers Meshtastic fallback
//

import Foundation
import SwiftUI
import CoreBluetooth

@MainActor
class NetworkAvailabilityDetector: ObservableObject {
    @Published var bleHopsAvailable = true
    @Published var lastBleActivity = Date()
    @Published var shouldFallbackToMeshtastic = false
    @Published var networkStatus = "BLE Active"
    
    private var bleActivityTimer: Timer?
    private var fallbackThreshold: TimeInterval = 30.0
    private let meshtasticFallback = MeshtasticFallbackManager.shared
    
    init() {
        startMonitoring()
    }
    
    func startMonitoring() {
        // Monitor BLE activity every 5 seconds
        bleActivityTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkNetworkStatus()
            }
        }
    }
    
    func stopMonitoring() {
        bleActivityTimer?.invalidate()
        bleActivityTimer = nil
    }
    
    func reportBleActivity() {
        lastBleActivity = Date()
        if !bleHopsAvailable {
            bleHopsAvailable = true
            shouldFallbackToMeshtastic = false
            networkStatus = "BLE Active"
            print("BLE mesh activity detected, disabling Meshtastic fallback")
        }
    }
    
    func reportNoBleHops() {
        let timeSinceActivity = Date().timeIntervalSince(lastBleActivity)
        
        if timeSinceActivity > fallbackThreshold {
            if bleHopsAvailable {
                bleHopsAvailable = false
                networkStatus = "No BLE Hops"
                print("No BLE hops available for \(timeSinceActivity)s, checking Meshtastic")
                
                Task {
                    await checkMeshtasticFallback()
                }
            }
        }
    }
    
    private func checkNetworkStatus() {
        let timeSinceActivity = Date().timeIntervalSince(lastBleActivity)
        
        if timeSinceActivity > fallbackThreshold && bleHopsAvailable {
            reportNoBleHops()
        }
    }
    
    private func checkMeshtasticFallback() async {
        guard meshtasticFallback.isEnabled else {
            shouldFallbackToMeshtastic = false
            networkStatus = "Isolated"
            return
        }
        
        networkStatus = "Checking Meshtastic..."
        
        let available = await meshtasticFallback.checkAvailability()
        
        if available {
            shouldFallbackToMeshtastic = true
            networkStatus = "Meshtastic Fallback"
            print("Meshtastic fallback available and activated")
        } else {
            shouldFallbackToMeshtastic = false
            networkStatus = "No Network"
            print("No Meshtastic devices available")
        }
    }
    
    func updateFallbackThreshold(_ threshold: TimeInterval) {
        fallbackThreshold = threshold
    }
    
    func getNetworkStatusColor() -> Color {
        switch networkStatus {
        case "BLE Active":
            return .green
        case "Meshtastic Fallback":
            return .orange
        case "Checking Meshtastic...":
            return .yellow
        case "No BLE Hops", "Isolated", "No Network":
            return .red
        default:
            return .gray
        }
    }
    
    func getNetworkStatusIcon() -> String {
        switch networkStatus {
        case "BLE Active":
            return "antenna.radiowaves.left.and.right"
        case "Meshtastic Fallback":
            return "dot.radiowaves.left.and.right"
        case "Checking Meshtastic...":
            return "magnifyingglass"
        case "No BLE Hops":
            return "antenna.radiowaves.left.and.right.slash"
        case "Isolated", "No Network":
            return "wifi.slash"
        default:
            return "questionmark.circle"
        }
    }
    
    deinit {
        stopMonitoring()
    }
}

// Extension to integrate with existing BitChat networking
extension NetworkAvailabilityDetector {
    
    func integrateWithBitChatMesh() {
        // This would integrate with BitChat's existing mesh networking
        // to monitor actual BLE peer connections and message routing
        
        // Monitor peer connections
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("BitChatPeerConnected"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reportBleActivity()
        }
        
        // Monitor message sends/receives
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("BitChatMessageSent"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reportBleActivity()
        }
        
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("BitChatMessageReceived"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reportBleActivity()
        }
        
        // Monitor when no peers are available
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("BitChatNoPeersAvailable"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reportNoBleHops()
        }
    }
}
