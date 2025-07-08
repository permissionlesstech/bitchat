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
        case .performance: return BatteryOptimizer.Constants.performanceScanDuration
        case .balanced: return BatteryOptimizer.Constants.balancedScanDuration
        case .powerSaver: return BatteryOptimizer.Constants.powerSaverScanDuration
        case .ultraLowPower: return BatteryOptimizer.Constants.ultraLowPowerScanDuration
        }
    }
    
    var scanPauseDuration: TimeInterval {
        switch self {
        case .performance: return BatteryOptimizer.Constants.performanceScanPause
        case .balanced: return BatteryOptimizer.Constants.balancedScanPause
        case .powerSaver: return BatteryOptimizer.Constants.powerSaverScanPause
        case .ultraLowPower: return BatteryOptimizer.Constants.ultraLowPowerScanPause
        }
    }
    
    var maxConnections: Int {
        switch self {
        case .performance: return BatteryOptimizer.Constants.performanceMaxConnections
        case .balanced: return BatteryOptimizer.Constants.balancedMaxConnections
        case .powerSaver: return BatteryOptimizer.Constants.powerSaverMaxConnections
        case .ultraLowPower: return BatteryOptimizer.Constants.ultraLowPowerMaxConnections
        }
    }
    
    var advertisingInterval: TimeInterval {
        // Note: iOS doesn't let us control this directly, but we can stop/start advertising
        switch self {
        case .performance: return BatteryOptimizer.Constants.performanceAdvertisingInterval  // Continuous
        case .balanced: return BatteryOptimizer.Constants.balancedAdvertisingInterval     // Advertise every 5 seconds
        case .powerSaver: return BatteryOptimizer.Constants.powerSaverAdvertisingInterval  // Advertise every 15 seconds
        case .ultraLowPower: return BatteryOptimizer.Constants.ultraLowPowerAdvertisingInterval // Advertise every 30 seconds
        }
    }
    
    var messageAggregationWindow: TimeInterval {
        switch self {
        case .performance: return BatteryOptimizer.Constants.performanceAggregationWindow  // 50ms
        case .balanced: return BatteryOptimizer.Constants.balancedAggregationWindow      // 100ms
        case .powerSaver: return BatteryOptimizer.Constants.powerSaverAggregationWindow    // 300ms
        case .ultraLowPower: return BatteryOptimizer.Constants.ultraLowPowerAggregationWindow // 500ms
        }
    }
}

class BatteryOptimizer {
    // MARK: - Constants
    struct Constants {
        // Battery level thresholds
        static let criticalBatteryLevel: Float = 0.1
        static let lowBatteryLevel: Float = 0.3
        static let mediumBatteryLevel: Float = 0.6
        
        // Background mode thresholds
        static let backgroundLowBatteryLevel: Float = 0.2
        static let backgroundMediumBatteryLevel: Float = 0.5
        
        // Scan timing (in seconds)
        static let performanceScanDuration: TimeInterval = 3.0
        static let balancedScanDuration: TimeInterval = 2.0
        static let powerSaverScanDuration: TimeInterval = 1.0
        static let ultraLowPowerScanDuration: TimeInterval = 0.5
        
        static let performanceScanPause: TimeInterval = 2.0
        static let balancedScanPause: TimeInterval = 3.0
        static let powerSaverScanPause: TimeInterval = 8.0
        static let ultraLowPowerScanPause: TimeInterval = 20.0
        
        // Connection limits
        static let performanceMaxConnections: Int = 20
        static let balancedMaxConnections: Int = 10
        static let powerSaverMaxConnections: Int = 5
        static let ultraLowPowerMaxConnections: Int = 2
        
        // Advertising intervals (in seconds)
        static let performanceAdvertisingInterval: TimeInterval = 0.0
        static let balancedAdvertisingInterval: TimeInterval = 5.0
        static let powerSaverAdvertisingInterval: TimeInterval = 15.0
        static let ultraLowPowerAdvertisingInterval: TimeInterval = 30.0
        
        // Message aggregation windows (in seconds)
        static let performanceAggregationWindow: TimeInterval = 0.05
        static let balancedAggregationWindow: TimeInterval = 0.1
        static let powerSaverAggregationWindow: TimeInterval = 0.3
        static let ultraLowPowerAggregationWindow: TimeInterval = 0.5
    }
    
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
            currentPowerMode = batteryLevel < Constants.criticalBatteryLevel ? .balanced : .performance
        } else if isInBackground {
            // In background, always use power saving
            if batteryLevel < Constants.backgroundLowBatteryLevel {
                currentPowerMode = .ultraLowPower
            } else if batteryLevel < Constants.backgroundMediumBatteryLevel {
                currentPowerMode = .powerSaver
            } else {
                currentPowerMode = .balanced
            }
        } else {
            // Foreground, not charging
            if batteryLevel < Constants.criticalBatteryLevel {
                currentPowerMode = .ultraLowPower
            } else if batteryLevel < Constants.lowBatteryLevel {
                currentPowerMode = .powerSaver
            } else if batteryLevel < Constants.mediumBatteryLevel {
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