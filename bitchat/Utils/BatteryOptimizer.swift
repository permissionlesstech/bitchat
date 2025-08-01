//
// BatteryOptimizer.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Combine
#if os(iOS)
import UIKit
#elseif os(macOS)
import IOKit.ps
#endif

enum PowerMode {
    case performance    // Max performance, battery drain OK
    case balanced      // Default balanced mode
    case powerSaver    // Aggressive power saving
    case ultraLowPower // Emergency mode
    
    var scanDuration: TimeInterval {
        switch self {
        case .performance: return 3.0
        case .balanced: return 2.0
        case .powerSaver: return 1.0
        case .ultraLowPower: return 0.5
        }
    }
    
    var scanPauseDuration: TimeInterval {
        switch self {
        case .performance: return 2.0
        case .balanced: return 3.0
        case .powerSaver: return 8.0
        case .ultraLowPower: return 20.0
        }
    }
    
    var maxConnections: Int {
        switch self {
        case .performance: return 20
        case .balanced: return 10
        case .powerSaver: return 5
        case .ultraLowPower: return 2
        }
    }
    
    var advertisingInterval: TimeInterval {
        // Note: iOS doesn't let us control this directly, but we can stop/start advertising
        switch self {
        case .performance: return 0.0  // Continuous
        case .balanced: return 5.0     // Advertise every 5 seconds
        case .powerSaver: return 15.0  // Advertise every 15 seconds
        case .ultraLowPower: return 30.0 // Advertise every 30 seconds
        }
    }
    
    var messageAggregationWindow: TimeInterval {
        switch self {
        case .performance: return 0.05  // 50ms
        case .balanced: return 0.1      // 100ms
        case .powerSaver: return 0.3    // 300ms
        case .ultraLowPower: return 0.5 // 500ms
        }
    }
}

class BatteryOptimizer {
    static let shared = BatteryOptimizer()
    
    @Published var currentPowerMode: PowerMode = .balanced
    @Published var isInBackground: Bool = false
    @Published var batteryLevel: Float = 1.0
    @Published var isCharging: Bool = false
    
    private var observers: [NSObjectProtocol] = []
    
    private init() {
        setupObservers()
        updateBatteryStatus()
    }
    
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    
    private func setupObservers() {
        #if os(iOS)
        // Monitor app state
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isInBackground = true
                self?.updatePowerMode()
            }
        )
        
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isInBackground = false
                self?.updatePowerMode()
            }
        )
        
        // Monitor battery
        UIDevice.current.isBatteryMonitoringEnabled = true
        
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIDevice.batteryLevelDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateBatteryStatus()
            }
        )
        
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIDevice.batteryStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateBatteryStatus()
            }
        )
        #endif
    }
    
    private func updateBatteryStatus() {
        #if os(iOS)
        batteryLevel = UIDevice.current.batteryLevel
        if batteryLevel < 0 {
            batteryLevel = 1.0 // Unknown battery level
        }
        
        isCharging = UIDevice.current.batteryState == .charging || 
                     UIDevice.current.batteryState == .full
        #elseif os(macOS)
        if let info = getMacOSBatteryInfo() {
            batteryLevel = info.level
            isCharging = info.isCharging
        }
        #endif
        
        updatePowerMode()
    }
    
    #if os(macOS)
    private func getMacOSBatteryInfo() -> (level: Float, isCharging: Bool)? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] {
                if let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int,
                   let maxCapacity = description[kIOPSMaxCapacityKey] as? Int {
                    let level = Float(currentCapacity) / Float(maxCapacity)
                    let isCharging = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
                    return (level, isCharging)
                }
            }
        }
        return nil
    }
    #endif
    
    private func updatePowerMode() {
        // Determine optimal power mode based on:
        // 1. Battery level
        // 2. Charging status
        // 3. Background/foreground state
        
        if isCharging {
            // When charging, use performance mode unless battery is critical
            currentPowerMode = batteryLevel < 0.1 ? .balanced : .performance
        } else if isInBackground {
            // In background, be less aggressive with power management
            // Don't force ultra-low power mode until battery is below 10%
            // Use balanced mode in background above 30% battery
            if batteryLevel < 0.1 {
                currentPowerMode = .ultraLowPower
            } else if batteryLevel < 0.3 {
                currentPowerMode = .powerSaver
            } else {
                currentPowerMode = .balanced  // Use balanced mode above 30% in background
            }
        } else {
            // Foreground, not charging
            if batteryLevel < 0.1 {
                currentPowerMode = .ultraLowPower
            } else if batteryLevel < 0.3 {
                currentPowerMode = .powerSaver
            } else if batteryLevel < 0.6 {
                currentPowerMode = .balanced
            } else {
                currentPowerMode = .performance
            }
        }
    }
    
    // Manual power mode override
    func setPowerMode(_ mode: PowerMode) {
        currentPowerMode = mode
    }
    
    // Get current scan parameters
    var scanParameters: (duration: TimeInterval, pause: TimeInterval) {
        return (currentPowerMode.scanDuration, currentPowerMode.scanPauseDuration)
    }
    
    // Should we skip non-essential operations?
    var shouldSkipNonEssential: Bool {
        return currentPowerMode == .ultraLowPower || 
               (currentPowerMode == .powerSaver && isInBackground)
    }
    
    // Should we reduce message frequency?
    var shouldThrottleMessages: Bool {
        return currentPowerMode == .powerSaver || currentPowerMode == .ultraLowPower
    }
}