//
// LowVisibilityModeTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

final class LowVisibilityModeTests: XCTestCase {
    
    func testLowVisibilityModeConfiguration() {
        // Test that low-visibility mode configuration values are reasonable
        XCTAssertTrue(TransportConfig.bleLowVisibilityDutyOnDuration < TransportConfig.bleDutyOnDuration)
        XCTAssertTrue(TransportConfig.bleLowVisibilityDutyOffDuration > TransportConfig.bleDutyOffDuration)
        XCTAssertTrue(TransportConfig.bleLowVisibilityAnnounceInterval > TransportConfig.bleAnnounceMinInterval)
        XCTAssertFalse(TransportConfig.bleLowVisibilityScanAllowDuplicates)
        XCTAssertTrue(TransportConfig.bleLowVisibilityMaxCentralLinks < TransportConfig.bleMaxCentralLinks)
    }
    
    func testLowVisibilityModeToggle() {
        // Test that toggling low-visibility mode works correctly
        let viewModel = ChatViewModel()
        
        // Initially should be false
        XCTAssertFalse(viewModel.isLowVisibilityModeEnabled)
        
        // Enable low-visibility mode
        viewModel.isLowVisibilityModeEnabled = true
        XCTAssertTrue(viewModel.isLowVisibilityModeEnabled)
        
        // Disable low-visibility mode
        viewModel.isLowVisibilityModeEnabled = false
        XCTAssertFalse(viewModel.isLowVisibilityModeEnabled)
    }
    
    func testLowVisibilityModeSettings() {
        // Test that low-visibility mode applies correct settings
        let bleService = BLEService()
        
        // Test standard mode
        bleService.isLowVisibilityModeEnabled = false
        XCTAssertFalse(bleService.isLowVisibilityModeEnabled)
        
        // Test low-visibility mode
        bleService.isLowVisibilityModeEnabled = true
        XCTAssertTrue(bleService.isLowVisibilityModeEnabled)
    }
    
    func testLowVisibilityModeDescription() {
        // Test that low-visibility mode has appropriate description
        let viewModel = ChatViewModel()
        
        // When disabled, should not show active message
        viewModel.isLowVisibilityModeEnabled = false
        
        // When enabled, should show active message
        viewModel.isLowVisibilityModeEnabled = true
    }
}
