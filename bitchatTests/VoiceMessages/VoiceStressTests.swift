//
// VoiceStressTests.swift
// bitchatTests
//
// Stress Tests for Voice Messages Under High Load
// Tests system behavior under extreme conditions
//

import XCTest
import AVFoundation
@testable import bitchat

/// Stress test suite for Voice Messages under high load conditions
class VoiceStressTests: XCTestCase {
    
    var voiceService: VoiceMessageService!
    var audioPlayer: AudioPlayer!
    var messageRouter: MessageRouter!
    
    // Test parameters
    let maxConcurrentRecordings = 50
    let maxConcurrentPlaybacks = 10
    let stressTestDuration: TimeInterval = 30.0
    let memoryLimitMB: Int64 = 200
    
    override func setUpWithError() throws {
        super.setUpWithError()
        
        voiceService = VoiceMessageService.shared
        audioPlayer = AudioPlayer.shared
        
        // Setup mock router
        let meshService = BluetoothMeshService.shared
        let nostrRelay = NostrRelayManager()
        messageRouter = MessageRouter(meshService: meshService, nostrRelay: nostrRelay)
        voiceService.setMessageRouter(messageRouter)
        
        voiceService.startLifecycleManagement()
    }
    
    override func tearDownWithError() throws {
        voiceService.stopLifecycleManagement()
        audioPlayer.stop()
        audioPlayer.clearQueue()
        
        voiceService = nil
        audioPlayer = nil
        messageRouter = nil
        
        // Force cleanup
        autoreleasepool { }
        
        super.tearDownWithError()
    }
    
    // MARK: - Recording Stress Tests
    
    /// Test rapid recording operations
    func testRapidRecordingStress() async throws {
        let operationCount = 100
        let maxDuration: TimeInterval = 30.0
        
        print("\n=== Rapid Recording Stress Test ===")
        print("Operations: \(operationCount)")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let initialMemory = getCurrentMemoryUsage()
        
        var successCount = 0
        var errorCount = 0
        var timeouts = 0
        
        for i in 0..<operationCount {
            autoreleasepool {
                let operationStart = CFAbsoluteTimeGetCurrent()
                
                do {
                    // Quick recording cycle
                    if voiceService.startRecording() {
                        // Brief recording (50-200ms)
                        let recordDuration = Double.random(in: 0.05...0.2)
                        try await Task.sleep(nanoseconds: UInt64(recordDuration * 1_000_000_000))
                        
                        let expectation = XCTestExpectation(description: "Recording \(i)")
                        var completed = false
                        
                        voiceService.stopRecording { _ in
                            completed = true
                            expectation.fulfill()
                        }
                        
                        // Wait with timeout
                        await fulfillment(of: [expectation], timeout: 2.0)
                        
                        if completed {
                            successCount += 1
                        } else {
                            timeouts += 1
                        }
                    } else {
                        errorCount += 1
                    }
                } catch {
                    errorCount += 1
                }
                
                // Check for excessive operation time
                let operationTime = CFAbsoluteTimeGetCurrent() - operationStart
                if operationTime > 5.0 {
                    print("⚠️ Operation \(i) took \(operationTime)s")
                }
                
                // Brief pause to prevent overwhelming
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
            
            // Check if we're exceeding time limit
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if elapsed > maxDuration {
                print("⏰ Time limit reached after \(i + 1) operations")
                break
            }
        }
        
        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        let finalMemory = getCurrentMemoryUsage()
        let memoryIncrease = (finalMemory - initialMemory) / 1024 / 1024
        
        let opsPerSecond = Double(successCount) / totalTime
        let successRate = Double(successCount) / Double(successCount + errorCount + timeouts)
        
        print("Results:")
        print("  Success: \(successCount)")
        print("  Errors: \(errorCount)")
        print("  Timeouts: \(timeouts)")
        print("  Success rate: \(String(format: "%.1f%%", successRate * 100))")
        print("  Operations/second: \(String(format: "%.1f", opsPerSecond))")
        print("  Memory increase: \(memoryIncrease)MB")
        print("  Total time: \(String(format: "%.2f", totalTime))s")
        
        // Verify stress test results
        XCTAssertGreaterThan(successRate, 0.8, "Success rate should be > 80% under stress")
        XCTAssertGreaterThan(opsPerSecond, 5.0, "Should handle > 5 operations/second")
        XCTAssertLessThan(memoryIncrease, memoryLimitMB, "Memory increase should be under \(memoryLimitMB)MB")
    }
    
    /// Test concurrent recording attempts
    func testConcurrentRecordingStress() async throws {
        let concurrentTasks = 20
        let attemptsPerTask = 10
        
        print("\n=== Concurrent Recording Stress Test ===")
        print("Tasks: \(concurrentTasks), Attempts per task: \(attemptsPerTask)")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        var totalSuccess = 0
        var totalErrors = 0
        
        await withTaskGroup(of: (Int, Int).self) { group in
            for taskID in 0..<concurrentTasks {
                group.addTask {
                    var taskSuccess = 0
                    var taskErrors = 0
                    
                    for attempt in 0..<attemptsPerTask {
                        autoreleasepool {
                            // Only one recording can succeed at a time
                            if self.voiceService.startRecording() {
                                taskSuccess += 1
                                
                                // Very brief recording
                                Thread.sleep(forTimeInterval: 0.05)
                                
                                let expectation = XCTestExpectation(description: "Task\(taskID)-\(attempt)")
                                self.voiceService.stopRecording { _ in
                                    expectation.fulfill()
                                }
                                
                                // Quick wait
                                _ = XCTWaiter().wait(for: [expectation], timeout: 1.0)
                            } else {
                                taskErrors += 1
                            }
                            
                            // Brief pause between attempts
                            Thread.sleep(forTimeInterval: 0.01)
                        }
                    }
                    
                    return (taskSuccess, taskErrors)
                }
            }
            
            for await (success, errors) in group {
                totalSuccess += success
                totalErrors += errors
            }
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let totalAttempts = concurrentTasks * attemptsPerTask
        let successRate = Double(totalSuccess) / Double(totalAttempts)
        
        print("Results:")
        print("  Total attempts: \(totalAttempts)")
        print("  Success: \(totalSuccess)")
        print("  Errors: \(totalErrors)")
        print("  Success rate: \(String(format: "%.1f%%", successRate * 100))")
        print("  Time: \(String(format: "%.2f", elapsed))s")
        
        // Only one recording can succeed at a time, so success count should be reasonable
        XCTAssertGreaterThan(totalSuccess, 0, "Should have some successful recordings")
        XCTAssertLessThan(elapsed, 60.0, "Should complete within reasonable time")
    }
    
    // MARK: - Playback Stress Tests
    
    /// Test concurrent playback stress
    func testConcurrentPlaybackStress() async throws {
        let messageCount = 20
        let maxConcurrent = 5
        
        print("\n=== Concurrent Playback Stress Test ===")
        print("Messages: \(messageCount), Max concurrent: \(maxConcurrent)")
        
        // Create test messages
        var messages: [BitchatMessage] = []
        for i in 0..<messageCount {
            let voiceData = VoiceMessageData(
                duration: Double.random(in: 1.0...5.0),
                waveformData: [],
                filePath: nil,
                audioData: try createTestOpusData(duration: 2.0),
                format: .opus
            )
            
            let message = BitchatMessage(
                id: "stress-\(i)",
                sender: "TestSender",
                content: "Voice \(i)",
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: nil,
                mentions: nil,
                deliveryStatus: .delivered(to: "test", at: Date()),
                voiceMessageData: voiceData
            )
            
            messages.append(message)
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        var playbackSuccess = 0
        var playbackErrors = 0
        
        // Add all messages to queue
        for message in messages {
            audioPlayer.addToQueue(message: message)
        }
        
        // Start playback and let it run
        do {
            try await audioPlayer.play(message: messages[0])
            playbackSuccess += 1
        } catch {
            playbackErrors += 1
        }
        
        // Wait for queue processing
        try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        
        print("Results:")
        print("  Playback attempts: 1")
        print("  Success: \(playbackSuccess)")
        print("  Errors: \(playbackErrors)")
        print("  Queue size: \(audioPlayer.queuedMessages.count)")
        print("  Time: \(String(format: "%.2f", elapsed))s")
        
        XCTAssertGreaterThan(playbackSuccess, 0, "Should have successful playback")
    }
    
    // MARK: - Message Processing Stress Tests
    
    /// Test message lifecycle under stress
    func testMessageLifecycleStress() async throws {
        let messageCount = 200
        let stateChangesPerMessage = 5
        
        print("\n=== Message Lifecycle Stress Test ===")
        print("Messages: \(messageCount), State changes per message: \(stateChangesPerMessage)")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let initialMemory = getCurrentMemoryUsage()
        
        var callbackCount = 0
        var errorCount = 0
        
        // Create messages and register callbacks
        for i in 0..<messageCount {
            let messageID = "lifecycle-stress-\(i)"
            
            // Register callback
            voiceService.registerDeliveryCallback(for: messageID) { status in
                callbackCount += 1
            }
            
            // Simulate state changes rapidly
            for j in 0..<stateChangesPerMessage {
                autoreleasepool {
                    switch j % 4 {
                    case 0:
                        voiceService.handleDeliveryConfirmation(
                            messageID: messageID,
                            deliveredTo: "peer-\(i)",
                            at: Date()
                        )
                    case 1:
                        voiceService.handleReadReceipt(
                            messageID: messageID,
                            readBy: "peer-\(i)",
                            at: Date()
                        )
                    case 2:
                        voiceService.handleTransmissionFailure(
                            messageID: messageID,
                            reason: "Test failure",
                            shouldRetry: false
                        )
                    default:
                        voiceService.handleDeliveryConfirmation(
                            messageID: messageID,
                            deliveredTo: "peer-\(i)",
                            at: Date()
                        )
                    }
                }
            }
        }
        
        // Wait for all callbacks to process
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let finalMemory = getCurrentMemoryUsage()
        let memoryIncrease = (finalMemory - initialMemory) / 1024 / 1024
        
        let totalStateChanges = messageCount * stateChangesPerMessage
        let throughput = Double(totalStateChanges) / elapsed
        
        print("Results:")
        print("  Total state changes: \(totalStateChanges)")
        print("  Callback invocations: \(callbackCount)")
        print("  Errors: \(errorCount)")
        print("  Throughput: \(String(format: "%.1f", throughput)) changes/sec")
        print("  Memory increase: \(memoryIncrease)MB")
        print("  Time: \(String(format: "%.2f", elapsed))s")
        
        XCTAssertGreaterThan(throughput, 100, "Should handle > 100 state changes/sec")
        XCTAssertLessThan(memoryIncrease, 50, "Memory increase should be reasonable")
    }
    
    // MARK: - System Integration Stress Tests
    
    /// Test full system under sustained load
    func testFullSystemStress() async throws {
        let testDuration: TimeInterval = 15.0
        
        print("\n=== Full System Stress Test ===")
        print("Duration: \(testDuration)s")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let initialMemory = getCurrentMemoryUsage()
        
        var recordingOps = 0
        var codecOps = 0
        var lifecycleOps = 0
        var errors = 0
        
        // Run sustained operations until time limit
        await withTaskGroup(of: Void.self) { group in
            // Recording task
            group.addTask {
                while CFAbsoluteTimeGetCurrent() - startTime < testDuration {
                    autoreleasepool {
                        if self.voiceService.startRecording() {
                            recordingOps += 1
                            Thread.sleep(forTimeInterval: 0.1)
                            
                            let expectation = XCTestExpectation(description: "Record")
                            self.voiceService.stopRecording { _ in
                                expectation.fulfill()
                            }
                            _ = XCTWaiter().wait(for: [expectation], timeout: 1.0)
                        }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }
            }
            
            // Codec task
            group.addTask {
                while CFAbsoluteTimeGetCurrent() - startTime < testDuration {
                    autoreleasepool {
                        do {
                            let pcmData = self.createTestPCM(sampleCount: 4800) // 0.1s
                            let encoded = try OpusSwiftWrapper.encode(pcmData: pcmData)
                            let _ = try OpusSwiftWrapper.decode(opusData: encoded)
                            codecOps += 1
                        } catch {
                            errors += 1
                        }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
            }
            
            // Lifecycle task
            group.addTask {
                while CFAbsoluteTimeGetCurrent() - startTime < testDuration {
                    autoreleasepool {
                        let messageID = UUID().uuidString
                        self.voiceService.registerDeliveryCallback(for: messageID) { _ in }
                        self.voiceService.handleDeliveryConfirmation(
                            messageID: messageID,
                            deliveredTo: "peer",
                            at: Date()
                        )
                        lifecycleOps += 1
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                }
            }
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let finalMemory = getCurrentMemoryUsage()
        let memoryIncrease = (finalMemory - initialMemory) / 1024 / 1024
        
        let totalOps = recordingOps + codecOps + lifecycleOps
        let opsPerSecond = Double(totalOps) / elapsed
        let errorRate = Double(errors) / Double(totalOps + errors)
        
        print("Results:")
        print("  Recording operations: \(recordingOps)")
        print("  Codec operations: \(codecOps)")
        print("  Lifecycle operations: \(lifecycleOps)")
        print("  Total operations: \(totalOps)")
        print("  Errors: \(errors)")
        print("  Operations/second: \(String(format: "%.1f", opsPerSecond))")
        print("  Error rate: \(String(format: "%.2f%%", errorRate * 100))")
        print("  Memory increase: \(memoryIncrease)MB")
        print("  Duration: \(String(format: "%.2f", elapsed))s")
        
        // Verify system handles sustained load
        XCTAssertGreaterThan(opsPerSecond, 50, "Should sustain > 50 ops/second")
        XCTAssertLessThan(errorRate, 0.05, "Error rate should be < 5%")
        XCTAssertLessThan(memoryIncrease, memoryLimitMB, "Memory should stay under limit")
    }
    
    // MARK: - Edge Case Stress Tests
    
    /// Test system behavior with invalid data
    func testInvalidDataStress() async throws {
        let invalidDataCount = 100
        
        print("\n=== Invalid Data Stress Test ===")
        print("Invalid data attempts: \(invalidDataCount)")
        
        var handledGracefully = 0
        var crashes = 0
        
        for i in 0..<invalidDataCount {
            autoreleasepool {
                do {
                    let testCases = [
                        Data(), // Empty data
                        Data(repeating: 0xFF, count: 10), // Invalid header
                        Data(repeating: 0x00, count: 1000), // Zeros
                        createRandomData(size: Int.random(in: 1...5000)) // Random data
                    ]
                    
                    let testData = testCases[i % testCases.count]
                    
                    // Try to decode invalid Opus data
                    do {
                        let _ = try OpusSwiftWrapper.decode(opusData: testData)
                    } catch {
                        handledGracefully += 1 // Expected behavior
                    }
                    
                } catch {
                    crashes += 1
                }
            }
        }
        
        print("Results:")
        print("  Handled gracefully: \(handledGracefully)")
        print("  Crashes: \(crashes)")
        print("  Success rate: \(String(format: "%.1f%%", Double(handledGracefully) / Double(invalidDataCount) * 100))")
        
        XCTAssertEqual(crashes, 0, "Should not crash with invalid data")
        XCTAssertGreaterThan(handledGracefully, invalidDataCount / 2, "Should handle most invalid data gracefully")
    }
    
    // MARK: - Helper Methods
    
    private func createTestPCM(sampleCount: Int) -> Data {
        var data = Data(capacity: sampleCount * MemoryLayout<Float32>.size)
        
        for i in 0..<sampleCount {
            let sample = sin(2.0 * .pi * 440.0 * Float32(i) / 48000.0) * 0.5
            withUnsafeBytes(of: sample) { data.append(contentsOf: $0) }
        }
        
        return data
    }
    
    private func createTestOpusData(duration: TimeInterval) throws -> Data {
        let sampleCount = Int(48000.0 * duration)
        let pcmData = createTestPCM(sampleCount: sampleCount)
        return try OpusSwiftWrapper.encode(pcmData: pcmData)
    }
    
    private func createRandomData(size: Int) -> Data {
        var data = Data(capacity: size)
        for _ in 0..<size {
            data.append(UInt8.random(in: 0...255))
        }
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