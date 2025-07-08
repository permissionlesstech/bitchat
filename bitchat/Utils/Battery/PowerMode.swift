//
//  PowerMode.swift
//  bitchat
//
//  Created by Siamak on 7/8/25.
//


import Foundation

enum PowerMode: Sendable {
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
