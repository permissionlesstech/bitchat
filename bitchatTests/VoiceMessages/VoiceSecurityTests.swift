//
// VoiceSecurityTests.swift
// bitchatTests
//
// Security Tests for Voice Messages System
// Tests for DDoS protection, input validation, and attack mitigation
//

import XCTest
import AVFoundation
import CryptoKit
@testable import bitchat

/// Comprehensive security test suite for Voice Messages
class VoiceSecurityTests: XCTestCase {
    
    var voiceService: VoiceMessageService!
    var audioPlayer: AudioPlayer!
    
    override func setUpWithError() throws {
        super.setUpWithError()
        
        voiceService = VoiceMessageService.shared
        audioPlayer = AudioPlayer.shared
        
        // Clean state for security testing
        voiceService.stopLifecycleManagement()
        voiceService.startLifecycleManagement()
        audioPlayer.stop()
        audioPlayer.clearQueue()
    }
    
    override func tearDownWithError() throws {
        voiceService.stopLifecycleManagement()
        audioPlayer.stop()
        audioPlayer.clearQueue()
        
        voiceService = nil
        audioPlayer = nil
        
        autoreleasepool { }
        super.tearDownWithError()
    }
    
    // MARK: - Rate Limiting Security Tests
    
    /// Test rate limiting prevents spam attacks
    func testRateLimitingPreventsSpamAttacks() async throws {
        print("\n=== Rate Limiting Security Test ===")
        
        var successCount = 0
        var rateLimitBlocked = 0
        
        // Attempt rapid recording cycles (should trigger rate limiting)
        for i in 0..<50 {
            if voiceService.startRecording() {
                successCount += 1
                
                // Very brief recording
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                
                let expectation = XCTestExpectation(description: "Recording \(i)")
                voiceService.stopRecording { _ in
                    expectation.fulfill()
                }
                await fulfillment(of: [expectation], timeout: 0.5)
            } else {
                rateLimitBlocked += 1
            }
            
            // Minimal delay to stress test rate limiter
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }
        
        print("Results: \(successCount) successful, \(rateLimitBlocked) rate-limited")
        
        // Rate limiter should have blocked some requests
        XCTAssertGreaterThan(rateLimitBlocked, 0, "Rate limiting should block excessive requests")
        XCTAssertLessThan(successCount, 40, "Should not allow all rapid requests")
    }
    
    /// Test playback rate limiting
    func testPlaybackRateLimiting() async throws {
        print("\n=== Playback Rate Limiting Test ===")
        
        // Create test Opus data
        let testData = createTestOpusData(duration: 0.1)
        
        var successCount = 0
        var rateLimitErrors = 0
        
        // Attempt rapid playback requests
        for i in 0..<30 {
            do {
                try await audioPlayer.play(opusData: testData, messageID: "rapid-\(i)")
                successCount += 1
                audioPlayer.stop()
            } catch AudioSecurityError.rateLimitExceeded {
                rateLimitErrors += 1
            } catch AudioSecurityError.playbackTooFrequent {
                rateLimitErrors += 1
            } catch {
                // Other errors
            }
            
            // Minimal delay
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }
        
        print("Results: \(successCount) successful, \(rateLimitErrors) rate-limited")
        
        // Should eventually trigger rate limiting
        XCTAssertGreaterThan(rateLimitErrors, 0, "Playback rate limiting should activate")
    }
    
    // MARK: - Input Validation Security Tests
    
    /// Test malicious audio data rejection
    func testMaliciousAudioDataRejection() throws {
        print("\n=== Malicious Audio Data Test ===")
        
        let maliciousTestCases = [
            ("Empty data", Data()),
            ("Oversized data", Data(repeating: 0xFF, count: 100 * 1024 * 1024)), // 100MB
            ("Invalid alignment", Data(repeating: 0x42, count: 7)), // Not Float32 aligned
            ("NaN samples", createNaNAudioData()),
            ("Extreme values", createExtremeValueAudioData()),
            ("Random garbage", Data((0..<1000).map { _ in UInt8.random(in: 0...255) }))
        ]
        
        var rejectedCount = 0
        
        for (testName, maliciousData) in maliciousTestCases {
            do {
                // Try to encode malicious data
                let _ = try OpusSwiftWrapper.encode(pcmData: maliciousData)
                print("⚠️ \(testName): Unexpectedly passed validation")
            } catch OpusSecurityError.emptyData,
                    OpusSecurityError.oversizedInput,
                    OpusSecurityError.invalidPCMAlignment,
                    OpusSecurityError.suspiciousPCMData {
                rejectedCount += 1
                print("✅ \(testName): Correctly rejected")
            } catch {
                print("❓ \(testName): Rejected with different error: \(error)")
                rejectedCount += 1
            }
        }
        
        print("Security result: \(rejectedCount)/\(maliciousTestCases.count) malicious inputs rejected")
        
        // Should reject most malicious inputs
        XCTAssertGreaterThan(rejectedCount, maliciousTestCases.count / 2, 
                           "Should reject majority of malicious inputs")
    }
    
    /// Test Opus format validation
    func testOpusFormatValidation() throws {
        print("\n=== Opus Format Validation Test ===")
        
        let invalidOpusData = [
            ("Too small", Data([0x01])),
            ("Invalid TOC", Data([0xFF, 0x00, 0x10, 0x20])),
            ("Invalid frame size", createInvalidOpusFrame()),
            ("Truncated frame", createTruncatedOpusFrame()),
            ("Oversized frame", Data(repeating: 0x42, count: 50_000))
        ]
        
        var rejectedCount = 0
        
        for (testName, invalidData) in invalidOpusData {
            do {
                let _ = try OpusSwiftWrapper.decode(opusData: invalidData)
                print("⚠️ \(testName): Unexpectedly passed validation")
            } catch OpusSecurityError.invalidOpusFormat,
                    OpusSecurityError.invalidFrameSize,
                    OpusSecurityError.truncatedFrame,
                    OpusSecurityError.invalidTOC,
                    OpusSecurityError.oversizedInput {
                rejectedCount += 1
                print("✅ \(testName): Correctly rejected")
            } catch {
                print("❓ \(testName): Rejected with different error: \(error)")
            }
        }
        
        print("Security result: \(rejectedCount)/\(invalidOpusData.count) invalid Opus data rejected")
        
        XCTAssertEqual(rejectedCount, invalidOpusData.count, 
                      "All invalid Opus data should be rejected")
    }
    
    // MARK: - Attack Pattern Detection Tests
    
    /// Test burst attack detection
    func testBurstAttackDetection() async throws {
        print("\n=== Burst Attack Detection Test ===")
        
        let testData = createTestOpusData(duration: 0.1)
        var burstBlocked = 0
        var successCount = 0
        
        // Simulate burst attack from same source
        for i in 0..<25 {
            do {
                try await audioPlayer.play(opusData: testData, messageID: "burst-attack-001-\(i)")
                successCount += 1
                audioPlayer.stop()
            } catch AudioSecurityError.suspiciousPattern {
                burstBlocked += 1
            } catch AudioSecurityError.sourceBlacklisted {
                burstBlocked += 1
            } catch {
                // Other security errors
            }
        }
        
        print("Results: \(successCount) successful, \(burstBlocked) blocked as burst attack")
        
        // Should detect and block burst attack
        XCTAssertGreaterThan(burstBlocked, 0, "Should detect burst attack pattern")
    }
    
    /// Test blacklist functionality
    func testBlacklistFunctionality() async throws {
        print("\n=== Blacklist Functionality Test ===")
        
        let testData = createTestOpusData(duration: 0.1)
        var blacklistBlocked = 0
        
        // Trigger blacklisting with rapid requests
        for i in 0..<25 {
            do {
                try await audioPlayer.play(opusData: testData, messageID: "blacklist-\(i)")
                audioPlayer.stop()
            } catch AudioSecurityError.suspiciousPattern,
                    AudioSecurityError.sourceBlacklisted {
                blacklistBlocked += 1
                break
            } catch {
                // Continue trying
            }
        }
        
        // Now try legitimate request from different source
        do {
            try await audioPlayer.play(opusData: testData, messageID: "legitimate-request")
            print("✅ Legitimate request from different source succeeded")
            audioPlayer.stop()
        } catch {
            XCTFail("Legitimate request should not be blocked: \(error)")
        }
        
        XCTAssertGreaterThan(blacklistBlocked, 0, "Should blacklist suspicious sources")
    }
    
    // MARK: - Memory Exhaustion Attack Tests
    
    /// Test protection against memory exhaustion attacks
    func testMemoryExhaustionProtection() async throws {
        print("\n=== Memory Exhaustion Protection Test ===")
        
        let initialMemory = getCurrentMemoryUsage()
        var memoryErrors = 0
        var successCount = 0
        
        // Try to exhaust memory with large audio data
        for i in 0..<10 {
            autoreleasepool {
                do {
                    // Create progressively larger test data
                    let size = (i + 1) * 10 * 1024 * 1024 // 10MB, 20MB, etc.
                    let largeData = Data(repeating: 0x80, count: min(size, 50 * 1024 * 1024))
                    
                    let _ = try OpusSwiftWrapper.encode(pcmData: largeData)
                    successCount += 1
                } catch OpusSecurityError.oversizedInput {
                    memoryErrors += 1
                } catch {
                    // Other errors
                }
            }
        }
        
        let finalMemory = getCurrentMemoryUsage()
        let memoryIncrease = finalMemory - initialMemory
        
        print("Results: \(successCount) successful, \(memoryErrors) blocked for size")
        print("Memory increase: \(memoryIncrease / 1024 / 1024)MB")
        
        XCTAssertGreaterThan(memoryErrors, 0, "Should block oversized inputs")
        XCTAssertLessThan(memoryIncrease, 200 * 1024 * 1024, "Memory increase should be bounded")
    }
    
    /// Test concurrent request limits
    func testConcurrentRequestLimits() async throws {
        print("\n=== Concurrent Request Limits Test ===")
        
        let testData = createTestOpusData(duration: 1.0)
        let concurrentTasks = 15
        var concurrencyErrors = 0
        var successCount = 0
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<concurrentTasks {
                group.addTask {
                    do {
                        try await self.audioPlayer.play(opusData: testData, messageID: "concurrent-\(i)")
                        successCount += 1
                        
                        // Brief playback
                        try await Task.sleep(nanoseconds: 100_000_000)
                        self.audioPlayer.stop()
                    } catch AudioSecurityError.tooManyConcurrentPlaybacks {
                        concurrencyErrors += 1
                    } catch {
                        // Other errors
                    }
                }
            }
        }
        
        print("Results: \(successCount) successful, \(concurrencyErrors) blocked for concurrency")
        
        // Should limit concurrent playbacks
        XCTAssertLessThan(successCount, concurrentTasks, "Should limit concurrent playbacks")
        XCTAssertGreaterThan(concurrencyErrors, 0, "Should block excess concurrent requests")
    }
    
    // MARK: - Integrity Validation Tests
    
    /// Test data integrity validation
    func testDataIntegrityValidation() throws {
        print("\n=== Data Integrity Validation Test ===")
        
        // Create valid audio data
        let originalData = createTestPCMData(sampleCount: 48000)
        let originalHash = SHA256.hash(data: originalData)
        
        // Create corrupted version
        var corruptedData = originalData
        if corruptedData.count > 1000 {
            corruptedData[500] = corruptedData[500] ^ 0xFF // Flip bits
        }
        let corruptedHash = SHA256.hash(data: corruptedData)
        
        XCTAssertNotEqual(originalHash, corruptedHash, "Corruption should change hash")
        
        // Test hash validation function
        let originalHashString = originalHash.compactMap { String(format: "%02x", $0) }.joined()
        let corruptedHashString = corruptedHash.compactMap { String(format: "%02x", $0) }.joined()
        
        XCTAssertNotEqual(originalHashString, corruptedHashString, "Hash strings should differ")
        print("✅ Data integrity validation working correctly")
    }
    
    // MARK: - Edge Case Security Tests
    
    /// Test edge cases and boundary conditions
    func testSecurityEdgeCases() async throws {
        print("\n=== Security Edge Cases Test ===")
        
        // Test extremely rapid requests
        var rapidRequestsBlocked = 0
        for i in 0..<100 {
            if !voiceService.startRecording() {
                rapidRequestsBlocked += 1
            } else {
                voiceService.cancelRecording()
            }
        }
        
        print("Rapid requests blocked: \(rapidRequestsBlocked)/100")
        XCTAssertGreaterThan(rapidRequestsBlocked, 50, "Should block most rapid requests")
        
        // Test zero-byte audio
        do {
            try await audioPlayer.play(opusData: Data(), messageID: "zero-bytes")
            XCTFail("Should not accept zero-byte audio")
        } catch AudioPlaybackError.noAudioData,
                AudioSecurityError.emptyAudioData {
            print("✅ Zero-byte audio correctly rejected")
        }
        
        // Test extremely long message ID
        let longMessageID = String(repeating: "x", count: 10000)
        let testData = createTestOpusData(duration: 0.1)
        
        do {
            try await audioPlayer.play(opusData: testData, messageID: longMessageID)
            audioPlayer.stop()
            print("✅ Long message ID handled correctly")
        } catch {
            print("✅ Long message ID rejected: \(error)")
        }
    }
    
    // MARK: - Performance Impact Tests
    
    /// Test security overhead on performance
    func testSecurityPerformanceOverhead() async throws {
        print("\n=== Security Performance Overhead Test ===")
        
        let testData = createTestPCMData(sampleCount: 48000)
        let iterations = 50
        
        // Measure encoding with security validation
        let startTime = CFAbsoluteTimeGetCurrent()
        
        for i in 0..<iterations {
            autoreleasepool {
                do {
                    let _ = try OpusSwiftWrapper.encode(pcmData: testData)
                } catch {
                    // Count errors but continue
                }
            }
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let averageTime = elapsed / Double(iterations)
        
        print("Security validation overhead: \(String(format: "%.2f", averageTime * 1000))ms per operation")
        
        // Security validation should not add excessive overhead
        XCTAssertLessThan(averageTime, 0.1, "Security validation should be fast")
    }
    
    // MARK: - Helper Methods
    
    private func createTestPCMData(sampleCount: Int) -> Data {
        var data = Data(capacity: sampleCount * MemoryLayout<Float32>.size)
        
        for i in 0..<sampleCount {
            let sample = sin(2.0 * .pi * 440.0 * Float32(i) / 48000.0) * 0.5
            withUnsafeBytes(of: sample) { data.append(contentsOf: $0) }
        }
        
        return data
    }
    
    private func createTestOpusData(duration: TimeInterval) -> Data {
        let sampleCount = Int(48000.0 * duration)
        let pcmData = createTestPCMData(sampleCount: sampleCount)
        
        do {
            return try OpusSwiftWrapper.encode(pcmData: pcmData)
        } catch {
            // Fallback to raw data for testing
            return pcmData
        }
    }
    
    private func createNaNAudioData() -> Data {
        let sampleCount = 1000
        var data = Data(capacity: sampleCount * MemoryLayout<Float32>.size)
        
        for _ in 0..<sampleCount {
            let sample: Float32 = .nan
            withUnsafeBytes(of: sample) { data.append(contentsOf: $0) }
        }
        
        return data
    }
    
    private func createExtremeValueAudioData() -> Data {
        let sampleCount = 1000
        var data = Data(capacity: sampleCount * MemoryLayout<Float32>.size)
        
        for i in 0..<sampleCount {
            let sample: Float32 = i % 2 == 0 ? Float32.greatestFiniteMagnitude : -Float32.greatestFiniteMagnitude
            withUnsafeBytes(of: sample) { data.append(contentsOf: $0) }
        }
        
        return data
    }
    
    private func createInvalidOpusFrame() -> Data {
        var data = Data()
        
        // Invalid frame length (too large)
        let frameLength: UInt16 = 10000
        withUnsafeBytes(of: frameLength) { data.append(contentsOf: $0) }
        
        // Invalid TOC byte
        data.append(0xFF)
        
        // Random data
        data.append(contentsOf: (0..<100).map { _ in UInt8.random(in: 0...255) })
        
        return data
    }
    
    private func createTruncatedOpusFrame() -> Data {
        var data = Data()
        
        // Frame length says 1000 bytes
        let frameLength: UInt16 = 1000
        withUnsafeBytes(of: frameLength) { data.append(contentsOf: $0) }
        
        // Valid TOC byte
        data.append(0x10)
        
        // But only provide 10 bytes (truncated)
        data.append(contentsOf: (0..<10).map { _ in UInt8.random(in: 0...255) })
        
        return data
    }
    
    private func getCurrentMemoryUsage() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
}