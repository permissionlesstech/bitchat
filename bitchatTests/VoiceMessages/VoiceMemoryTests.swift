//
// VoiceMemoryTests.swift
// bitchatTests
//
// Memory Management Tests for Voice Messages
// Tests for memory leaks, retain cycles, and resource management
//

import XCTest
import AVFoundation
@testable import bitchat

/// Memory management test suite for Voice Messages
class VoiceMemoryTests: XCTestCase {
    
    var voiceService: VoiceMessageService!
    var audioPlayer: AudioPlayer!
    
    // Memory thresholds
    let maxMemoryPerMessage: Int64 = 5 * 1024 * 1024      // 5MB per message
    let maxTotalMemory: Int64 = 100 * 1024 * 1024         // 100MB total
    let acceptableLeakRate: Double = 0.01                  // 1% leak tolerance
    
    override func setUpWithError() throws {
        super.setUpWithError()
        
        voiceService = VoiceMessageService.shared
        audioPlayer = AudioPlayer.shared
        
        // Clean state
        voiceService.stopLifecycleManagement()
        voiceService.startLifecycleManagement()
    }
    
    override func tearDownWithError() throws {
        // Force cleanup
        voiceService.stopLifecycleManagement()
        audioPlayer.stop()
        audioPlayer.clearQueue()
        
        voiceService = nil
        audioPlayer = nil
        
        // Force memory cleanup
        autoreleasepool { }
        
        super.tearDownWithError()
    }
    
    // MARK: - Memory Leak Detection Tests
    
    /// Test for memory leaks in recording cycle
    func testRecordingMemoryLeaks() async throws {
        weak var weakVoiceService = voiceService
        
        let initialMemory = getCurrentMemoryUsage()
        
        // Perform multiple recording cycles
        for i in 0..<10 {
            autoreleasepool {
                // Start recording
                XCTAssertTrue(voiceService.startRecording())
                
                // Record for 1 second
                Thread.sleep(forTimeInterval: 1.0)
                
                // Stop recording
                let expectation = XCTestExpectation(description: "Stop \(i)")
                voiceService.stopRecording { _ in
                    expectation.fulfill()
                }
                
                wait(for: [expectation], timeout: 3.0)
            }
        }
        
        // Force cleanup
        voiceService = nil
        
        // Wait for deallocation
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        let finalMemory = getCurrentMemoryUsage()
        let memoryLeak = finalMemory - initialMemory
        
        // Check for leaks
        XCTAssertLessThan(memoryLeak, 10 * 1024 * 1024, 
                         "Memory leak should be less than 10MB after 10 recordings")
        
        // Verify service can be deallocated
        XCTAssertNil(weakVoiceService, "VoiceService should be deallocated")
    }
    
    /// Test for retain cycles in callbacks
    func testCallbackRetainCycles() async throws {
        let expectation = XCTestExpectation(description: "Callback retain cycle test")
        
        // Create a scope to test deallocation
        autoreleasepool {
            var strongReference: VoiceMessageService? = VoiceMessageService.shared
            weak var weakReference = strongReference
            
            let messageID = UUID().uuidString
            
            // Register callback that might create retain cycle
            strongReference?.registerDeliveryCallback(for: messageID) { [weak strongReference] status in
                // Use weak reference to avoid retain cycle
                _ = strongReference?.getVoiceMessageState(messageID)
            }
            
            // Trigger callback
            strongReference?.handleDeliveryConfirmation(
                messageID: messageID,
                deliveredTo: "test",
                at: Date()
            )
            
            // Release strong reference
            strongReference = nil
            
            // Verify weak reference is released
            XCTAssertNil(weakReference, "Should not have retain cycle in callbacks")
            
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 2.0)
    }
    
    /// Test audio buffer memory management
    func testAudioBufferMemoryManagement() async throws {
        let bufferCount = 50
        var buffers: [AVAudioPCMBuffer] = []
        
        let initialMemory = getCurrentMemoryUsage()
        
        // Create many audio buffers
        autoreleasepool {
            for _ in 0..<bufferCount {
                let format = AVAudioFormat(
                    standardFormatWithSampleRate: 48000,
                    channels: 1
                )!
                
                if let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: 48000 // 1 second
                ) {
                    buffer.frameLength = 48000
                    buffers.append(buffer)
                }
            }
        }
        
        let peakMemory = getCurrentMemoryUsage()
        
        // Clear buffers
        buffers.removeAll()
        
        // Force cleanup
        autoreleasepool { }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        let finalMemory = getCurrentMemoryUsage()
        
        // Verify memory is released
        let memoryRecovered = peakMemory - finalMemory
        let expectedRecovery = Double(bufferCount * 48000 * 4) * 0.9 // 90% should be recovered
        
        XCTAssertGreaterThan(Double(memoryRecovered), expectedRecovery,
                           "Should recover most buffer memory")
    }
    
    // MARK: - Resource Management Tests
    
    /// Test proper cleanup of audio resources
    func testAudioResourceCleanup() async throws {
        // Track audio engine state
        var engineReferences = 0
        
        for _ in 0..<5 {
            autoreleasepool {
                // Start recording (creates audio engine)
                if voiceService.startRecording() {
                    engineReferences += 1
                }
                
                // Cancel (should cleanup)
                voiceService.cancelRecording()
            }
        }
        
        // All engines should be cleaned up
        XCTAssertEqual(engineReferences, 5, "Should have created 5 engines")
        
        // Verify no lingering audio sessions
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Session should be inactive after cleanup
        XCTAssertFalse(audioSession.isOtherAudioPlaying,
                      "No audio should be playing after cleanup")
        #endif
    }
    
    /// Test temporary file cleanup
    func testTemporaryFileCleanup() async throws {
        let documentsPath = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        
        // Count initial voice files
        let initialFiles = try FileManager.default.contentsOfDirectory(
            at: documentsPath,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("voice_") }
        
        // Create recordings
        for _ in 0..<3 {
            XCTAssertTrue(voiceService.startRecording())
            try await Task.sleep(nanoseconds: 500_000_000)
            
            let expectation = XCTestExpectation(description: "Stop")
            voiceService.stopRecording { _ in
                expectation.fulfill()
            }
            await fulfillment(of: [expectation], timeout: 2.0)
        }
        
        // Cancel one recording (should cleanup immediately)
        XCTAssertTrue(voiceService.startRecording())
        try await Task.sleep(nanoseconds: 200_000_000)
        voiceService.cancelRecording()
        
        // Count final files
        let finalFiles = try FileManager.default.contentsOfDirectory(
            at: documentsPath,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("voice_") }
        
        // Should have cleaned up cancelled recording
        XCTAssertLessThanOrEqual(
            finalFiles.count - initialFiles.count,
            3,
            "Should not accumulate temporary files"
        )
    }
    
    // MARK: - Memory Pressure Tests
    
    /// Test behavior under memory pressure
    func testMemoryPressureHandling() async throws {
        // Simulate memory pressure by allocating large buffers
        var pressureBuffers: [Data] = []
        
        // Allocate 50MB to create pressure
        for _ in 0..<50 {
            pressureBuffers.append(Data(repeating: 0, count: 1024 * 1024))
        }
        
        // Try voice operations under pressure
        var successCount = 0
        var failureCount = 0
        
        for _ in 0..<5 {
            if voiceService.startRecording() {
                successCount += 1
                voiceService.cancelRecording()
            } else {
                failureCount += 1
            }
        }
        
        // System should handle pressure gracefully
        XCTAssertGreaterThan(successCount, 0, "Should handle some operations under pressure")
        
        // Release pressure
        pressureBuffers.removeAll()
        
        // Operations should work normally after pressure released
        XCTAssertTrue(voiceService.startRecording(), "Should work after pressure released")
        voiceService.cancelRecording()
    }
    
    /// Test memory growth with many messages
    func testMemoryGrowthWithManyMessages() async throws {
        let messageCount = 50
        let initialMemory = getCurrentMemoryUsage()
        
        var messageIDs: [String] = []
        
        // Create many voice messages
        for i in 0..<messageCount {
            if voiceService.startRecording() {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms each
                
                let expectation = XCTestExpectation(description: "Message \(i)")
                voiceService.stopRecording { id in
                    messageIDs.append(id)
                    expectation.fulfill()
                }
                await fulfillment(of: [expectation], timeout: 2.0)
            }
        }
        
        let peakMemory = getCurrentMemoryUsage()
        let memoryGrowth = peakMemory - initialMemory
        let averagePerMessage = memoryGrowth / Int64(messageCount)
        
        // Check memory usage is reasonable
        XCTAssertLessThan(averagePerMessage, maxMemoryPerMessage,
                         "Average memory per message should be under \(maxMemoryPerMessage / 1024 / 1024)MB")
        XCTAssertLessThan(memoryGrowth, maxTotalMemory,
                         "Total memory growth should be under \(maxTotalMemory / 1024 / 1024)MB")
        
        // Trigger cleanup
        voiceService.stopLifecycleManagement()
        voiceService.startLifecycleManagement()
        
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        let finalMemory = getCurrentMemoryUsage()
        let memoryRecovered = peakMemory - finalMemory
        
        // Should recover significant memory after cleanup
        XCTAssertGreaterThan(memoryRecovered, memoryGrowth / 2,
                           "Should recover at least 50% of memory after cleanup")
    }
    
    // MARK: - Concurrent Access Tests
    
    /// Test thread safety and memory consistency
    func testConcurrentMemoryAccess() async throws {
        let concurrentTasks = 20
        let expectation = XCTestExpectation(description: "Concurrent access")
        expectation.expectedFulfillmentCount = concurrentTasks
        
        let initialMemory = getCurrentMemoryUsage()
        
        // Perform concurrent operations
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<concurrentTasks {
                group.addTask {
                    if i % 3 == 0 {
                        // Recording operation
                        if self.voiceService.startRecording() {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            self.voiceService.cancelRecording()
                        }
                    } else if i % 3 == 1 {
                        // State query operation
                        let messageID = UUID().uuidString
                        _ = self.voiceService.getVoiceMessageState(messageID)
                        
                        // Register and trigger callback
                        self.voiceService.registerDeliveryCallback(for: messageID) { _ in }
                        self.voiceService.handleDeliveryConfirmation(
                            messageID: messageID,
                            deliveredTo: "test",
                            at: Date()
                        )
                    } else {
                        // Statistics operation
                        _ = self.voiceService.getVoiceMessageStatistics()
                    }
                    
                    expectation.fulfill()
                }
            }
        }
        
        await fulfillment(of: [expectation], timeout: 10.0)
        
        let finalMemory = getCurrentMemoryUsage()
        let memoryIncrease = finalMemory - initialMemory
        
        // Memory should be stable under concurrent access
        XCTAssertLessThan(memoryIncrease, 20 * 1024 * 1024,
                         "Memory should remain stable under concurrent access")
    }
    
    // MARK: - Lifecycle Tests
    
    /// Test memory behavior through app lifecycle
    func testAppLifecycleMemoryManagement() async throws {
        // Simulate app going to background
        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        // Memory should be reduced in background
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        let backgroundMemory = getCurrentMemoryUsage()
        
        // Simulate app coming to foreground
        NotificationCenter.default.post(
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        // Test operations after foreground
        XCTAssertTrue(voiceService.startRecording(), "Should work after foreground")
        voiceService.cancelRecording()
        
        let foregroundMemory = getCurrentMemoryUsage()
        
        // Memory usage should be reasonable
        let memoryDiff = abs(foregroundMemory - backgroundMemory)
        XCTAssertLessThan(memoryDiff, 10 * 1024 * 1024,
                         "Memory transition should be smooth")
    }
    
    // MARK: - Helper Methods
    
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
    
    private func getDetailedMemoryInfo() -> String {
        let memory = getCurrentMemoryUsage()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: memory)
    }
    
    private func simulateMemoryWarning() {
        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
}