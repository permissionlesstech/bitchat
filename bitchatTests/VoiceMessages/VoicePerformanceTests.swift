//
// VoicePerformanceTests.swift
// bitchatTests
//
// Performance & Memory Testing for Voice Messages
// Comprehensive benchmarks and stress tests
//

import XCTest
import AVFoundation
@testable import bitchat

/// Performance test suite for Voice Messages
class VoicePerformanceTests: XCTestCase {
    
    var voiceService: VoiceMessageService!
    var audioPlayer: AudioPlayer!
    var opusService: OpusAudioService!
    
    // Performance baselines (milliseconds)
    let recordingStartBaseline: Double = 100  // Should start recording within 100ms
    let encodingBaseline: Double = 50         // Encode 1 second of audio within 50ms
    let decodingBaseline: Double = 30         // Decode 1 second of audio within 30ms
    let playbackStartBaseline: Double = 150   // Start playback within 150ms
    
    override func setUpWithError() throws {
        super.setUpWithError()
        
        voiceService = VoiceMessageService.shared
        audioPlayer = AudioPlayer.shared
        opusService = OpusAudioService.shared
    }
    
    override func tearDownWithError() throws {
        voiceService = nil
        audioPlayer = nil
        opusService = nil
        super.tearDownWithError()
    }
    
    // MARK: - Recording Performance Tests
    
    /// Test recording startup performance
    func testRecordingStartupPerformance() {
        let expectation = XCTestExpectation(description: "Recording startup")
        
        measure {
            let startTime = CFAbsoluteTimeGetCurrent()
            
            let started = voiceService.startRecording()
            
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            
            XCTAssertTrue(started, "Recording should start")
            XCTAssertLessThan(elapsed, recordingStartBaseline, 
                            "Recording should start within \(recordingStartBaseline)ms")
            
            voiceService.cancelRecording()
        }
        
        expectation.fulfill()
        wait(for: [expectation], timeout: 1.0)
    }
    
    /// Test recording buffer processing performance
    func testRecordingBufferProcessing() async throws {
        // Start recording
        XCTAssertTrue(voiceService.startRecording())
        
        // Record for 3 seconds
        try await Task.sleep(nanoseconds: 3_000_000_000)
        
        // Measure stop and processing time
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let expectation = XCTestExpectation(description: "Processing complete")
        var messageID: String?
        
        voiceService.stopRecording { id in
            messageID = id
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
        
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        
        XCTAssertNotNil(messageID, "Should receive message ID")
        XCTAssertLessThan(elapsed, 500, "Processing should complete within 500ms for 3 second recording")
        
        // Verify voice data exists
        if let id = messageID {
            let state = voiceService.getVoiceMessageState(id)
            XCTAssertNotNil(state?.message.voiceMessageData, "Voice data should be processed")
        }
    }
    
    /// Test rapid start/stop cycles
    func testRapidRecordingCycles() async throws {
        let cycles = 10
        var totalTime: Double = 0
        
        for i in 0..<cycles {
            let startTime = CFAbsoluteTimeGetCurrent()
            
            // Start recording
            let started = voiceService.startRecording()
            XCTAssertTrue(started, "Cycle \(i): Recording should start")
            
            // Brief recording
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            
            // Stop recording
            let expectation = XCTestExpectation(description: "Cycle \(i)")
            voiceService.stopRecording { _ in
                expectation.fulfill()
            }
            
            await fulfillment(of: [expectation], timeout: 2.0)
            
            let cycleTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            totalTime += cycleTime
            
            // Brief pause between cycles
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        
        let averageTime = totalTime / Double(cycles)
        XCTAssertLessThan(averageTime, 300, "Average cycle time should be under 300ms")
    }
    
    // MARK: - Opus Codec Performance Tests
    
    /// Test Opus encoding performance
    func testOpusEncodingPerformance() throws {
        // Create 1 second of 48kHz Float32 PCM audio
        let sampleRate = 48000
        let duration = 1.0
        let sampleCount = Int(Double(sampleRate) * duration)
        let pcmData = createPCMData(sampleCount: sampleCount)
        
        measure {
            do {
                let startTime = CFAbsoluteTimeGetCurrent()
                
                let encodedData = try OpusSwiftWrapper.encode(pcmData: pcmData)
                
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                
                XCTAssertGreaterThan(encodedData.count, 0, "Should produce encoded data")
                XCTAssertLessThan(elapsed, encodingBaseline,
                                "Encoding 1 second should take less than \(encodingBaseline)ms")
                
                // Verify compression ratio
                let compressionRatio = Float(pcmData.count) / Float(encodedData.count)
                XCTAssertGreaterThan(compressionRatio, 5.0, "Should achieve at least 5:1 compression")
                
            } catch {
                XCTFail("Encoding failed: \(error)")
            }
        }
    }
    
    /// Test Opus decoding performance
    func testOpusDecodingPerformance() throws {
        // Create and encode test data
        let pcmData = createPCMData(sampleCount: 48000)
        let encodedData = try OpusSwiftWrapper.encode(pcmData: pcmData)
        
        measure {
            do {
                let startTime = CFAbsoluteTimeGetCurrent()
                
                let decodedData = try OpusSwiftWrapper.decode(opusData: encodedData)
                
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                
                XCTAssertGreaterThan(decodedData.count, 0, "Should produce decoded data")
                XCTAssertLessThan(elapsed, decodingBaseline,
                                "Decoding should take less than \(decodingBaseline)ms")
                
            } catch {
                XCTFail("Decoding failed: \(error)")
            }
        }
    }
    
    /// Test codec round-trip performance
    func testCodecRoundTripPerformance() throws {
        let pcmData = createPCMData(sampleCount: 48000 * 3) // 3 seconds
        
        measure {
            do {
                // Encode
                let encoded = try OpusSwiftWrapper.encode(pcmData: pcmData)
                
                // Decode
                let decoded = try OpusSwiftWrapper.decode(opusData: encoded)
                
                // Verify data integrity
                XCTAssertEqual(decoded.count, pcmData.count, "Round-trip should preserve size")
                
            } catch {
                XCTFail("Round-trip failed: \(error)")
            }
        }
    }
    
    // MARK: - Playback Performance Tests
    
    /// Test playback startup performance
    func testPlaybackStartupPerformance() async throws {
        // Create test voice message
        let voiceData = VoiceMessageData(
            duration: 2.0,
            waveformData: [],
            filePath: nil,
            audioData: try createEncodedOpusData(duration: 2.0),
            format: .opus
        )
        
        let message = BitchatMessage(
            id: "perf-test-001",
            sender: "Test",
            content: "Voice message",
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
        
        measure {
            let expectation = XCTestExpectation(description: "Playback started")
            
            Task {
                let startTime = CFAbsoluteTimeGetCurrent()
                
                do {
                    try await audioPlayer.play(message: message)
                    
                    let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                    
                    XCTAssertLessThan(elapsed, playbackStartBaseline,
                                    "Playback should start within \(playbackStartBaseline)ms")
                    
                    expectation.fulfill()
                } catch {
                    XCTFail("Playback failed: \(error)")
                    expectation.fulfill()
                }
            }
            
            wait(for: [expectation], timeout: 2.0)
            
            // Stop playback
            audioPlayer.stop()
        }
    }
    
    /// Test queue management performance
    func testQueueManagementPerformance() async throws {
        // Create multiple voice messages
        var messages: [BitchatMessage] = []
        
        for i in 0..<10 {
            let voiceData = VoiceMessageData(
                duration: 1.0,
                waveformData: [],
                filePath: nil,
                audioData: try createEncodedOpusData(duration: 1.0),
                format: .opus
            )
            
            let message = BitchatMessage(
                id: "queue-test-\(i)",
                sender: "Test",
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
        
        measure {
            let expectation = XCTestExpectation(description: "Queue operations")
            
            Task {
                // Add all messages to queue
                for message in messages {
                    audioPlayer.addToQueue(message: message)
                }
                
                // Verify queue
                let queuedCount = audioPlayer.queuedMessages.count
                XCTAssertEqual(queuedCount, messages.count, "All messages should be queued")
                
                // Clear queue
                audioPlayer.clearQueue()
                
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 1.0)
        }
    }
    
    // MARK: - Memory Performance Tests
    
    /// Test memory usage during long recording
    func testLongRecordingMemoryUsage() async throws {
        let expectation = XCTestExpectation(description: "Long recording")
        
        // Get initial memory
        let initialMemory = getMemoryUsage()
        
        // Start recording
        XCTAssertTrue(voiceService.startRecording())
        
        // Record for 30 seconds
        try await Task.sleep(nanoseconds: 30_000_000_000)
        
        // Stop recording
        voiceService.stopRecording { _ in
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
        
        // Get final memory
        let finalMemory = getMemoryUsage()
        let memoryIncrease = finalMemory - initialMemory
        
        // Memory increase should be reasonable (< 50MB for 30 second recording)
        XCTAssertLessThan(memoryIncrease, 50 * 1024 * 1024, 
                         "Memory usage should be under 50MB for 30 second recording")
    }
    
    /// Test memory cleanup after operations
    func testMemoryCleanup() async throws {
        let initialMemory = getMemoryUsage()
        
        // Perform multiple recording cycles
        for _ in 0..<5 {
            XCTAssertTrue(voiceService.startRecording())
            try await Task.sleep(nanoseconds: 2_000_000_000)
            
            let expectation = XCTestExpectation(description: "Stop")
            voiceService.stopRecording { _ in
                expectation.fulfill()
            }
            await fulfillment(of: [expectation], timeout: 3.0)
        }
        
        // Force cleanup
        voiceService.stopLifecycleManagement()
        voiceService.startLifecycleManagement()
        
        // Wait for cleanup
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        let finalMemory = getMemoryUsage()
        let memoryIncrease = finalMemory - initialMemory
        
        // Memory should return close to baseline (< 10MB increase)
        XCTAssertLessThan(memoryIncrease, 10 * 1024 * 1024,
                         "Memory should be cleaned up after operations")
    }
    
    // MARK: - Stress Tests
    
    /// Test system under high load
    func testHighLoadStress() async throws {
        let concurrentOperations = 20
        let expectation = XCTestExpectation(description: "High load")
        expectation.expectedFulfillmentCount = concurrentOperations
        
        var successCount = 0
        var failureCount = 0
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Perform concurrent operations
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<concurrentOperations {
                group.addTask {
                    // Alternate between recording and playback operations
                    if i % 2 == 0 {
                        // Recording operation
                        if self.voiceService.startRecording() {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            self.voiceService.cancelRecording()
                            return true
                        }
                    } else {
                        // Codec operation
                        let pcmData = self.createPCMData(sampleCount: 48000)
                        if let encoded = try? OpusSwiftWrapper.encode(pcmData: pcmData),
                           let _ = try? OpusSwiftWrapper.decode(opusData: encoded) {
                            return true
                        }
                    }
                    return false
                }
            }
            
            for await result in group {
                if result {
                    successCount += 1
                } else {
                    failureCount += 1
                }
                expectation.fulfill()
            }
        }
        
        await fulfillment(of: [expectation], timeout: 30.0)
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        
        // System should handle load
        XCTAssertGreaterThan(successCount, concurrentOperations / 2,
                           "At least half operations should succeed under load")
        XCTAssertLessThan(elapsed, 30.0, "Operations should complete within 30 seconds")
        
        print("High load test: \(successCount) succeeded, \(failureCount) failed in \(elapsed)s")
    }
    
    /// Test sustained operations
    func testSustainedOperations() async throws {
        let duration: TimeInterval = 10.0 // Run for 10 seconds
        let startTime = Date()
        var operationCount = 0
        var errors = 0
        
        while Date().timeIntervalSince(startTime) < duration {
            // Start recording
            if voiceService.startRecording() {
                operationCount += 1
                
                // Brief recording
                try await Task.sleep(nanoseconds: 200_000_000) // 200ms
                
                // Stop recording
                let expectation = XCTestExpectation(description: "Op \(operationCount)")
                voiceService.stopRecording { _ in
                    expectation.fulfill()
                }
                
                await fulfillment(of: [expectation], timeout: 1.0)
            } else {
                errors += 1
            }
            
            // Brief pause
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        let opsPerSecond = Double(operationCount) / duration
        
        XCTAssertGreaterThan(opsPerSecond, 2.0, "Should sustain at least 2 ops/second")
        XCTAssertLessThan(Double(errors) / Double(operationCount), 0.1,
                         "Error rate should be less than 10%")
        
        print("Sustained test: \(operationCount) operations, \(errors) errors, \(opsPerSecond) ops/sec")
    }
    
    // MARK: - Benchmarks
    
    /// Comprehensive benchmark suite
    func testComprehensiveBenchmark() async throws {
        print("\n=== Voice Messages Performance Benchmark ===\n")
        
        // Recording benchmark
        let recordingTime = measureTime {
            _ = voiceService.startRecording()
            voiceService.cancelRecording()
        }
        print("📍 Recording Start: \(recordingTime * 1000)ms")
        
        // Encoding benchmark (1 second audio)
        let pcmData = createPCMData(sampleCount: 48000)
        let encodingTime = measureTime {
            _ = try? OpusSwiftWrapper.encode(pcmData: pcmData)
        }
        print("📍 Opus Encoding (1s): \(encodingTime * 1000)ms")
        
        // Decoding benchmark
        let encodedData = try OpusSwiftWrapper.encode(pcmData: pcmData)
        let decodingTime = measureTime {
            _ = try? OpusSwiftWrapper.decode(opusData: encodedData)
        }
        print("📍 Opus Decoding (1s): \(decodingTime * 1000)ms")
        
        // Compression ratio
        let compressionRatio = Float(pcmData.count) / Float(encodedData.count)
        print("📍 Compression Ratio: \(String(format: "%.1f", compressionRatio)):1")
        
        // Memory usage
        let memoryUsage = getMemoryUsage()
        print("📍 Current Memory: \(memoryUsage / (1024 * 1024))MB")
        
        // Verify performance meets requirements
        XCTAssertLessThan(recordingTime * 1000, 100, "Recording should start < 100ms")
        XCTAssertLessThan(encodingTime * 1000, 50, "Encoding should be < 50ms/second")
        XCTAssertLessThan(decodingTime * 1000, 30, "Decoding should be < 30ms/second")
        XCTAssertGreaterThan(compressionRatio, 5.0, "Compression should be > 5:1")
        
        print("\n=== Benchmark Complete ===\n")
    }
    
    // MARK: - Helper Methods
    
    private func createPCMData(sampleCount: Int) -> Data {
        var data = Data(capacity: sampleCount * MemoryLayout<Float32>.size)
        
        // Generate sine wave at 440Hz
        let frequency: Float32 = 440.0
        let sampleRate: Float32 = 48000.0
        
        for i in 0..<sampleCount {
            let sample = sin(2.0 * .pi * frequency * Float32(i) / sampleRate) * 0.5
            withUnsafeBytes(of: sample) { data.append(contentsOf: $0) }
        }
        
        return data
    }
    
    private func createEncodedOpusData(duration: TimeInterval) throws -> Data {
        let sampleCount = Int(48000.0 * duration)
        let pcmData = createPCMData(sampleCount: sampleCount)
        return try OpusSwiftWrapper.encode(pcmData: pcmData)
    }
    
    private func getMemoryUsage() -> Int64 {
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
    
    private func measureTime(_ block: () throws -> Void) -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent()
        try? block()
        return CFAbsoluteTimeGetCurrent() - start
    }
}