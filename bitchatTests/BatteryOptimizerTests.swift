//
// BatteryOptimizerTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

class BatteryOptimizerTests: XCTestCase {
    
    func testConstantsAreAccessible() {
        // Verify constants can be accessed (compilation test)
        
        // Test that power modes return expected values using constants
        XCTAssertEqual(PowerMode.performance.scanDuration, BatteryOptimizer.Constants.performanceScanDuration)
        XCTAssertEqual(PowerMode.balanced.scanDuration, BatteryOptimizer.Constants.balancedScanDuration)
        XCTAssertEqual(PowerMode.powerSaver.scanDuration, BatteryOptimizer.Constants.powerSaverScanDuration)
        XCTAssertEqual(PowerMode.ultraLowPower.scanDuration, BatteryOptimizer.Constants.ultraLowPowerScanDuration)
        
        // Test specific expected values
        XCTAssertEqual(PowerMode.performance.scanDuration, 3.0)
        XCTAssertEqual(PowerMode.balanced.maxConnections, 10)
        XCTAssertEqual(PowerMode.powerSaver.advertisingInterval, 15.0)
        XCTAssertEqual(PowerMode.ultraLowPower.messageAggregationWindow, 0.5)
    }
    
    func testConstantsConsistency() {
        // Verify thresholds are in logical order
        XCTAssertLessThan(BatteryOptimizer.Constants.criticalBatteryLevel, BatteryOptimizer.Constants.lowBatteryLevel)
        XCTAssertLessThan(BatteryOptimizer.Constants.lowBatteryLevel, BatteryOptimizer.Constants.mediumBatteryLevel)
        
        // Background thresholds should be reasonable
        XCTAssertLessThan(BatteryOptimizer.Constants.backgroundLowBatteryLevel, BatteryOptimizer.Constants.backgroundMediumBatteryLevel)
        
        // Verify scan durations decrease with power saving
        XCTAssertGreaterThan(BatteryOptimizer.Constants.performanceScanDuration, BatteryOptimizer.Constants.balancedScanDuration)
        XCTAssertGreaterThan(BatteryOptimizer.Constants.balancedScanDuration, BatteryOptimizer.Constants.powerSaverScanDuration)
        XCTAssertGreaterThan(BatteryOptimizer.Constants.powerSaverScanDuration, BatteryOptimizer.Constants.ultraLowPowerScanDuration)
        
        // Verify scan pauses increase with power saving
        XCTAssertLessThan(BatteryOptimizer.Constants.performanceScanPause, BatteryOptimizer.Constants.balancedScanPause)
        XCTAssertLessThan(BatteryOptimizer.Constants.balancedScanPause, BatteryOptimizer.Constants.powerSaverScanPause)
        XCTAssertLessThan(BatteryOptimizer.Constants.powerSaverScanPause, BatteryOptimizer.Constants.ultraLowPowerScanPause)
        
        // Verify connection limits decrease with power saving
        XCTAssertGreaterThan(BatteryOptimizer.Constants.performanceMaxConnections, BatteryOptimizer.Constants.balancedMaxConnections)
        XCTAssertGreaterThan(BatteryOptimizer.Constants.balancedMaxConnections, BatteryOptimizer.Constants.powerSaverMaxConnections)
        XCTAssertGreaterThan(BatteryOptimizer.Constants.powerSaverMaxConnections, BatteryOptimizer.Constants.ultraLowPowerMaxConnections)
        
        // Verify advertising intervals increase with power saving (except performance which is 0)
        XCTAssertEqual(BatteryOptimizer.Constants.performanceAdvertisingInterval, 0.0)
        XCTAssertLessThan(BatteryOptimizer.Constants.balancedAdvertisingInterval, BatteryOptimizer.Constants.powerSaverAdvertisingInterval)
        XCTAssertLessThan(BatteryOptimizer.Constants.powerSaverAdvertisingInterval, BatteryOptimizer.Constants.ultraLowPowerAdvertisingInterval)
        
        // Verify aggregation windows increase with power saving
        XCTAssertLessThan(BatteryOptimizer.Constants.performanceAggregationWindow, BatteryOptimizer.Constants.balancedAggregationWindow)
        XCTAssertLessThan(BatteryOptimizer.Constants.balancedAggregationWindow, BatteryOptimizer.Constants.powerSaverAggregationWindow)
        XCTAssertLessThan(BatteryOptimizer.Constants.powerSaverAggregationWindow, BatteryOptimizer.Constants.ultraLowPowerAggregationWindow)
    }
    
    func testPowerModeValues() {
        // Test that all PowerMode computed properties return the expected constant values
        
        // Scan durations
        XCTAssertEqual(PowerMode.performance.scanDuration, 3.0)
        XCTAssertEqual(PowerMode.balanced.scanDuration, 2.0)
        XCTAssertEqual(PowerMode.powerSaver.scanDuration, 1.0)
        XCTAssertEqual(PowerMode.ultraLowPower.scanDuration, 0.5)
        
        // Scan pause durations
        XCTAssertEqual(PowerMode.performance.scanPauseDuration, 2.0)
        XCTAssertEqual(PowerMode.balanced.scanPauseDuration, 3.0)
        XCTAssertEqual(PowerMode.powerSaver.scanPauseDuration, 8.0)
        XCTAssertEqual(PowerMode.ultraLowPower.scanPauseDuration, 20.0)
        
        // Max connections
        XCTAssertEqual(PowerMode.performance.maxConnections, 20)
        XCTAssertEqual(PowerMode.balanced.maxConnections, 10)
        XCTAssertEqual(PowerMode.powerSaver.maxConnections, 5)
        XCTAssertEqual(PowerMode.ultraLowPower.maxConnections, 2)
        
        // Advertising intervals
        XCTAssertEqual(PowerMode.performance.advertisingInterval, 0.0)
        XCTAssertEqual(PowerMode.balanced.advertisingInterval, 5.0)
        XCTAssertEqual(PowerMode.powerSaver.advertisingInterval, 15.0)
        XCTAssertEqual(PowerMode.ultraLowPower.advertisingInterval, 30.0)
        
        // Message aggregation windows
        XCTAssertEqual(PowerMode.performance.messageAggregationWindow, 0.05)
        XCTAssertEqual(PowerMode.balanced.messageAggregationWindow, 0.1)
        XCTAssertEqual(PowerMode.powerSaver.messageAggregationWindow, 0.3)
        XCTAssertEqual(PowerMode.ultraLowPower.messageAggregationWindow, 0.5)
    }
    
    func testBatteryThresholdConstants() {
        // Test that battery threshold constants have expected values
        XCTAssertEqual(BatteryOptimizer.Constants.criticalBatteryLevel, 0.1)
        XCTAssertEqual(BatteryOptimizer.Constants.lowBatteryLevel, 0.3)
        XCTAssertEqual(BatteryOptimizer.Constants.mediumBatteryLevel, 0.6)
        XCTAssertEqual(BatteryOptimizer.Constants.backgroundLowBatteryLevel, 0.2)
        XCTAssertEqual(BatteryOptimizer.Constants.backgroundMediumBatteryLevel, 0.5)
    }
    
    func testScanParametersIntegration() {
        // Test that scan parameters work correctly with the constants
        let optimizer = BatteryOptimizer.shared
        
        // Set to performance mode
        optimizer.setPowerMode(.performance)
        let performanceParams = optimizer.scanParameters
        XCTAssertEqual(performanceParams.duration, BatteryOptimizer.Constants.performanceScanDuration)
        XCTAssertEqual(performanceParams.pause, BatteryOptimizer.Constants.performanceScanPause)
        
        // Set to balanced mode
        optimizer.setPowerMode(.balanced)
        let balancedParams = optimizer.scanParameters
        XCTAssertEqual(balancedParams.duration, BatteryOptimizer.Constants.balancedScanDuration)
        XCTAssertEqual(balancedParams.pause, BatteryOptimizer.Constants.balancedScanPause)
        
        // Set to power saver mode
        optimizer.setPowerMode(.powerSaver)
        let powerSaverParams = optimizer.scanParameters
        XCTAssertEqual(powerSaverParams.duration, BatteryOptimizer.Constants.powerSaverScanDuration)
        XCTAssertEqual(powerSaverParams.pause, BatteryOptimizer.Constants.powerSaverScanPause)
        
        // Set to ultra low power mode
        optimizer.setPowerMode(.ultraLowPower)
        let ultraLowPowerParams = optimizer.scanParameters
        XCTAssertEqual(ultraLowPowerParams.duration, BatteryOptimizer.Constants.ultraLowPowerScanDuration)
        XCTAssertEqual(ultraLowPowerParams.pause, BatteryOptimizer.Constants.ultraLowPowerScanPause)
    }
    
    func testConstantsAreReasonable() {
        // Test that constants have reasonable values for a mesh network app
        
        // Battery thresholds should be between 0 and 1
        XCTAssertGreaterThan(BatteryOptimizer.Constants.criticalBatteryLevel, 0.0)
        XCTAssertLessThan(BatteryOptimizer.Constants.criticalBatteryLevel, 1.0)
        XCTAssertGreaterThan(BatteryOptimizer.Constants.mediumBatteryLevel, 0.0)
        XCTAssertLessThan(BatteryOptimizer.Constants.mediumBatteryLevel, 1.0)
        
        // Scan durations should be positive and reasonable (not too long)
        XCTAssertGreaterThan(BatteryOptimizer.Constants.performanceScanDuration, 0.0)
        XCTAssertLessThan(BatteryOptimizer.Constants.performanceScanDuration, 10.0)
        XCTAssertGreaterThan(BatteryOptimizer.Constants.ultraLowPowerScanDuration, 0.0)
        
        // Connection limits should be positive
        XCTAssertGreaterThan(BatteryOptimizer.Constants.performanceMaxConnections, 0)
        XCTAssertGreaterThan(BatteryOptimizer.Constants.ultraLowPowerMaxConnections, 0)
        
        // Advertising intervals should be non-negative
        XCTAssertGreaterThanOrEqual(BatteryOptimizer.Constants.performanceAdvertisingInterval, 0.0)
        XCTAssertGreaterThan(BatteryOptimizer.Constants.ultraLowPowerAdvertisingInterval, 0.0)
        
        // Aggregation windows should be positive and reasonable
        XCTAssertGreaterThan(BatteryOptimizer.Constants.performanceAggregationWindow, 0.0)
        XCTAssertLessThan(BatteryOptimizer.Constants.performanceAggregationWindow, 1.0)
        XCTAssertGreaterThan(BatteryOptimizer.Constants.ultraLowPowerAggregationWindow, 0.0)
        XCTAssertLessThan(BatteryOptimizer.Constants.ultraLowPowerAggregationWindow, 2.0)
    }
}
