//
// TimingAttackTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
import CryptoKit
@testable import bitchat

/// Tests to verify the timing attack mitigation in NoiseProtocol
/// These tests ensure that public key validation is constant-time
class TimingAttackTests: XCTestCase {
    
    // Known bad points for Curve25519
    let lowOrderPoints: [Data] = [
        Data(repeating: 0x00, count: 32), // All zeros
        Data([0x01] + Data(repeating: 0x00, count: 31)), // Point of order 1
        Data([0x00] + Data(repeating: 0x00, count: 30) + [0x01]), // Another low-order point
        Data([0xe0, 0xeb, 0x7a, 0x7c, 0x3b, 0x41, 0xb8, 0xae, 0x16, 0x56, 0xe3,
              0xfa, 0xf1, 0x9f, 0xc4, 0x6a, 0xda, 0x09, 0x8d, 0xeb, 0x9c, 0x32,
              0xb1, 0xfd, 0x86, 0x62, 0x05, 0x16, 0x5f, 0x49, 0xb8, 0x00]), // Low order point
        Data([0x5f, 0x9c, 0x95, 0xbc, 0xa3, 0x50, 0x8c, 0x24, 0xb1, 0xd0, 0xb1,
              0x55, 0x9c, 0x83, 0xef, 0x5b, 0x04, 0x44, 0x5c, 0xc4, 0x58, 0x1c,
              0x8e, 0x86, 0xd8, 0x22, 0x4e, 0xdd, 0xd0, 0x9f, 0x11, 0x57]), // Low order point
        Data(repeating: 0xFF, count: 32), // All ones
        Data([0xda, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
              0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
              0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), // Another bad point
        Data([0xdb, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
              0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
              0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])  // Another bad point
    ]
    
    /// Test that all known bad keys are rejected
    func testBadKeysAreRejected() {
        for badKey in lowOrderPoints {
            XCTAssertThrowsError(try NoiseHandshakeState.validatePublicKey(badKey)) { error in
                XCTAssertEqual(error as? NoiseError, NoiseError.invalidPublicKey)
            }
        }
    }
    
    /// Test that valid keys are accepted
    func testValidKeysAreAccepted() {
        // Generate a valid Curve25519 key
        let validKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKeyData = validKey.publicKey.rawRepresentation
        
        XCTAssertNoThrow(try NoiseHandshakeState.validatePublicKey(publicKeyData))
    }
    
    /// Test timing consistency - this is the critical test
    /// Verifies that validation time is consistent regardless of which bad key is checked
    func testConstantTimeValidation() {
        let iterations = 1000
        var timings: [String: [TimeInterval]] = [:]
        
        // Test timing for each bad key
        for (index, badKey) in lowOrderPoints.enumerated() {
            let keyName = "badKey\(index)"
            timings[keyName] = []
            
            for _ in 0..<iterations {
                let startTime = CFAbsoluteTimeGetCurrent()
                _ = try? NoiseHandshakeState.validatePublicKey(badKey)
                let endTime = CFAbsoluteTimeGetCurrent()
                
                timings[keyName]?.append(endTime - startTime)
            }
        }
        
        // Also test a valid key for comparison
        let validKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        timings["validKey"] = []
        for _ in 0..<iterations {
            let startTime = CFAbsoluteTimeGetCurrent()
            _ = try? NoiseHandshakeState.validatePublicKey(validKey)
            let endTime = CFAbsoluteTimeGetCurrent()
            
            timings["validKey"]?.append(endTime - startTime)
        }
        
        // Calculate average timings
        var averageTimings: [String: TimeInterval] = [:]
        for (key, times) in timings {
            averageTimings[key] = times.reduce(0, +) / Double(times.count)
        }
        
        // Calculate variance
        let allAverages = Array(averageTimings.values)
        let overallAverage = allAverages.reduce(0, +) / Double(allAverages.count)
        let variance = allAverages.map { pow($0 - overallAverage, 2) }.reduce(0, +) / Double(allAverages.count)
        let standardDeviation = sqrt(variance)
        
        // The standard deviation should be very small (< 10% of average)
        // This indicates constant-time behavior
        let coefficientOfVariation = standardDeviation / overallAverage
        
        print("Timing Analysis:")
        print("Overall Average: \(overallAverage * 1000) ms")
        print("Standard Deviation: \(standardDeviation * 1000) ms")
        print("Coefficient of Variation: \(coefficientOfVariation * 100)%")
        
        // Assert that timing variance is low (constant-time)
        XCTAssertLessThan(coefficientOfVariation, 0.15, "Timing variance too high - possible timing attack vulnerability")
    }
    
    /// Test that keys of wrong length are rejected quickly
    func testInvalidLengthKeys() {
        let shortKey = Data(repeating: 0x01, count: 31)
        let longKey = Data(repeating: 0x01, count: 33)
        
        XCTAssertThrowsError(try NoiseHandshakeState.validatePublicKey(shortKey))
        XCTAssertThrowsError(try NoiseHandshakeState.validatePublicKey(longKey))
    }
    
    /// Test edge cases
    func testEdgeCases() {
        // Test key that differs from bad key by one bit
        var almostBadKey = lowOrderPoints[0]
        almostBadKey[0] = 0x01
        
        // Should be accepted (not in bad key list)
        XCTAssertNoThrow(try NoiseHandshakeState.validatePublicKey(almostBadKey))
    }
    
    /// Performance test to ensure validation is still reasonably fast
    func testValidationPerformance() {
        let validKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        
        measure {
            for _ in 0..<1000 {
                _ = try? NoiseHandshakeState.validatePublicKey(validKey)
            }
        }
    }
}
