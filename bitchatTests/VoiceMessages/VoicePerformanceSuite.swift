//
// VoicePerformanceSuite.swift
// bitchatTests
//
// Complete Performance & Memory Test Suite for Voice Messages
// Consolidated benchmarks and performance validation
//

import XCTest
@testable import bitchat

/// Complete performance test suite for Voice Messages
class VoicePerformanceSuite: XCTestCase {
    
    // Performance baselines and targets
    struct PerformanceBaseline {
        // Recording performance (milliseconds)
        static let recordingStartup: Double = 100
        static let recordingProcessing: Double = 50
        
        // Codec performance (milliseconds per second of audio)
        static let opusEncoding: Double = 5
        static let opusDecoding: Double = 3
        
        // Playback performance (milliseconds)
        static let playbackStartup: Double = 150
        
        // Memory limits (MB)
        static let maxMemoryPerMessage: Double = 5
        static let maxTotalMemory: Double = 100
        static let maxMemoryGrowth: Double = 50
        
        // Quality metrics
        static let minCompressionRatio: Float = 6.0
        static let minAudioQuality: Float = 0.95
        static let minSNR: Float = 30.0
        
        // Throughput requirements
        static let minOperationsPerSecond: Double = 10
        static let minConcurrentOperations: Int = 5
        static let maxErrorRate: Double = 0.05
    }
    
    override func setUpWithError() throws {
        super.setUpWithError()
        continueAfterFailure = false
    }
    
    // MARK: - Complete Performance Validation
    
    /// Master performance validation test
    func testCompletePerformanceValidation() async throws {
        print("\n" + "="*60)
        print("🚀 VOICE MESSAGES PERFORMANCE VALIDATION SUITE")
        print("="*60)
        
        let validationResults = PerformanceValidationResults()
        
        // 1. Recording Performance
        try await validateRecordingPerformance(results: validationResults)
        
        // 2. Codec Performance
        try await validateCodecPerformance(results: validationResults)
        
        // 3. Playback Performance
        try await validatePlaybackPerformance(results: validationResults)
        
        // 4. Memory Management
        try await validateMemoryManagement(results: validationResults)
        
        // 5. Concurrent Operations
        try await validateConcurrentOperations(results: validationResults)
        
        // 6. Quality Metrics
        try await validateQualityMetrics(results: validationResults)
        
        // 7. Stress Testing
        try await validateStressTestResults(results: validationResults)
        
        // Final Validation Report
        printValidationReport(results: validationResults)
        
        // Assert overall performance
        XCTAssertTrue(validationResults.allTestsPassed, "All performance tests must pass")
        XCTAssertGreaterThanOrEqual(validationResults.overallScore, 0.9, "Overall score must be ≥ 90%")
    }
    
    // MARK: - Individual Performance Validations
    
    private func validateRecordingPerformance(results: PerformanceValidationResults) async throws {
        print("\n📱 Recording Performance Validation")
        print("-" * 40)
        
        let voiceService = VoiceMessageService.shared
        
        // Test 1: Recording startup time
        let startupTime = measureTime {
            let success = voiceService.startRecording()
            voiceService.cancelRecording()
            return success
        }
        
        let startupMs = startupTime * 1000
        let startupPassed = startupMs < PerformanceBaseline.recordingStartup
        
        print("Recording startup: \(String(format: "%.1f", startupMs))ms (target: <\(PerformanceBaseline.recordingStartup)ms) [\(startupPassed ? "✅" : "❌")]")
        
        // Test 2: Recording processing time
        var processingTime: Double = 0
        if voiceService.startRecording() {
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            
            let expectation = XCTestExpectation(description: "Processing")
            let processStart = CFAbsoluteTimeGetCurrent()
            
            voiceService.stopRecording { _ in
                processingTime = CFAbsoluteTimeGetCurrent() - processStart
                expectation.fulfill()
            }
            
            await fulfillment(of: [expectation], timeout: 3.0)
        }
        
        let processingMs = processingTime * 1000
        let processingPassed = processingMs < PerformanceBaseline.recordingProcessing * 1.0 // Per second
        
        print("Processing time: \(String(format: "%.1f", processingMs))ms for 1s audio [\(processingPassed ? "✅" : "❌")]")
        
        results.recordingResults = RecordingResults(
            startupTime: startupMs,
            processingTime: processingMs,
            passed: startupPassed && processingPassed
        )
    }
    
    private func validateCodecPerformance(results: PerformanceValidationResults) async throws {
        print("\n🎵 Codec Performance Validation")
        print("-" * 40)
        
        // Create 1 second test audio
        let pcmData = createTestAudio(duration: 1.0)
        
        // Test encoding
        let encodingTime = measureTime {
            _ = try? OpusSwiftWrapper.encode(pcmData: pcmData)
        }
        let encodingMs = encodingTime * 1000
        let encodingPassed = encodingMs < PerformanceBaseline.opusEncoding
        
        print("Opus encoding: \(String(format: "%.1f", encodingMs))ms/sec (target: <\(PerformanceBaseline.opusEncoding)ms/sec) [\(encodingPassed ? "✅" : "❌")]")
        
        // Test decoding
        let encodedData = try OpusSwiftWrapper.encode(pcmData: pcmData)
        let decodingTime = measureTime {
            _ = try? OpusSwiftWrapper.decode(opusData: encodedData)
        }
        let decodingMs = decodingTime * 1000
        let decodingPassed = decodingMs < PerformanceBaseline.opusDecoding
        
        print("Opus decoding: \(String(format: "%.1f", decodingMs))ms/sec (target: <\(PerformanceBaseline.opusDecoding)ms/sec) [\(decodingPassed ? "✅" : "❌")]")
        
        // Test compression
        let compressionRatio = Float(pcmData.count) / Float(encodedData.count)
        let compressionPassed = compressionRatio >= PerformanceBaseline.minCompressionRatio
        
        print("Compression: \(String(format: "%.1f", compressionRatio)):1 (target: ≥\(PerformanceBaseline.minCompressionRatio):1) [\(compressionPassed ? "✅" : "❌")]")
        
        results.codecResults = CodecResults(
            encodingTime: encodingMs,
            decodingTime: decodingMs,
            compressionRatio: compressionRatio,
            passed: encodingPassed && decodingPassed && compressionPassed
        )
    }
    
    private func validatePlaybackPerformance(results: PerformanceValidationResults) async throws {
        print("\n🔊 Playback Performance Validation")
        print("-" * 40)
        
        // Create test message
        let voiceData = VoiceMessageData(
            duration: 2.0,
            waveformData: [],
            filePath: nil,
            audioData: try OpusSwiftWrapper.encode(pcmData: createTestAudio(duration: 2.0)),
            format: .opus
        )
        
        let message = BitchatMessage(
            id: "perf-test",
            sender: "Test",
            content: "Test message",
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
        
        // Test playback startup
        let audioPlayer = AudioPlayer.shared
        var startupTime: Double = 0
        
        let expectation = XCTestExpectation(description: "Playback")
        
        Task {
            let startTime = CFAbsoluteTimeGetCurrent()
            
            do {
                try await audioPlayer.play(message: message)
                startupTime = CFAbsoluteTimeGetCurrent() - startTime
            } catch {
                startupTime = CFAbsoluteTimeGetCurrent() - startTime
            }
            
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
        audioPlayer.stop()
        
        let startupMs = startupTime * 1000
        let startupPassed = startupMs < PerformanceBaseline.playbackStartup
        
        print("Playback startup: \(String(format: "%.1f", startupMs))ms (target: <\(PerformanceBaseline.playbackStartup)ms) [\(startupPassed ? "✅" : "❌")]")
        
        results.playbackResults = PlaybackResults(
            startupTime: startupMs,
            passed: startupPassed
        )
    }
    
    private func validateMemoryManagement(results: PerformanceValidationResults) async throws {
        print("\n💾 Memory Management Validation")
        print("-" * 40)
        
        let voiceService = VoiceMessageService.shared
        let initialMemory = getCurrentMemoryUsage()
        
        // Create multiple recordings to test memory usage
        for _ in 0..<10 {
            autoreleasepool {
                if voiceService.startRecording() {
                    Thread.sleep(forTimeInterval: 0.5)
                    
                    let expectation = XCTestExpectation(description: "Recording")
                    voiceService.stopRecording { _ in
                        expectation.fulfill()
                    }
                    _ = XCTWaiter().wait(for: [expectation], timeout: 2.0)
                }
            }
        }
        
        let peakMemory = getCurrentMemoryUsage()
        let memoryIncrease = Double(peakMemory - initialMemory) / 1024.0 / 1024.0
        let memoryPassed = memoryIncrease < PerformanceBaseline.maxMemoryGrowth
        
        print("Memory usage: \(String(format: "%.1f", memoryIncrease))MB increase (target: <\(PerformanceBaseline.maxMemoryGrowth)MB) [\(memoryPassed ? "✅" : "❌")]")
        
        results.memoryResults = MemoryResults(
            memoryIncrease: memoryIncrease,
            passed: memoryPassed
        )
    }
    
    private func validateConcurrentOperations(results: PerformanceValidationResults) async throws {
        print("\n⚡ Concurrent Operations Validation")
        print("-" * 40)
        
        let concurrentTasks = 10
        let operationsPerTask = 5
        let startTime = CFAbsoluteTimeGetCurrent()
        
        var totalSuccess = 0
        var totalErrors = 0
        
        await withTaskGroup(of: (Int, Int).self) { group in
            for _ in 0..<concurrentTasks {
                group.addTask {
                    var success = 0
                    var errors = 0
                    
                    for _ in 0..<operationsPerTask {
                        autoreleasepool {
                            do {
                                let pcmData = self.createTestAudio(duration: 0.1)
                                let encoded = try OpusSwiftWrapper.encode(pcmData: pcmData)
                                let _ = try OpusSwiftWrapper.decode(opusData: encoded)
                                success += 1
                            } catch {
                                errors += 1
                            }
                        }
                    }
                    
                    return (success, errors)
                }
            }
            
            for await (success, errors) in group {
                totalSuccess += success
                totalErrors += errors
            }
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let opsPerSecond = Double(totalSuccess) / elapsed
        let errorRate = Double(totalErrors) / Double(totalSuccess + totalErrors)
        
        let throughputPassed = opsPerSecond >= PerformanceBaseline.minOperationsPerSecond
        let errorPassed = errorRate <= PerformanceBaseline.maxErrorRate
        let concurrentPassed = throughputPassed && errorPassed
        
        print("Throughput: \(String(format: "%.1f", opsPerSecond)) ops/sec (target: ≥\(PerformanceBaseline.minOperationsPerSecond)) [\(throughputPassed ? "✅" : "❌")]")
        print("Error rate: \(String(format: "%.1f%%", errorRate * 100)) (target: ≤\(PerformanceBaseline.maxErrorRate * 100)%) [\(errorPassed ? "✅" : "❌")]")
        
        results.concurrentResults = ConcurrentResults(
            throughput: opsPerSecond,
            errorRate: errorRate,
            passed: concurrentPassed
        )
    }
    
    private func validateQualityMetrics(results: PerformanceValidationResults) async throws {
        print("\n🎯 Quality Metrics Validation")
        print("-" * 40)
        
        let originalPcm = createTestAudio(duration: 1.0)
        let encodedData = try OpusSwiftWrapper.encode(pcmData: originalPcm)
        let decodedPcm = try OpusSwiftWrapper.decode(opusData: encodedData)
        
        let quality = calculateAudioSimilarity(original: originalPcm, decoded: decodedPcm)
        let snr = calculateSignalToNoiseRatio(original: originalPcm, decoded: decodedPcm)
        
        let qualityPassed = quality >= PerformanceBaseline.minAudioQuality
        let snrPassed = snr >= PerformanceBaseline.minSNR
        
        print("Audio quality: \(String(format: "%.3f", quality)) (target: ≥\(PerformanceBaseline.minAudioQuality)) [\(qualityPassed ? "✅" : "❌")]")
        print("Signal-to-Noise: \(String(format: "%.1f", snr))dB (target: ≥\(PerformanceBaseline.minSNR)dB) [\(snrPassed ? "✅" : "❌")]")
        
        results.qualityResults = QualityResults(
            audioQuality: quality,
            snr: snr,
            passed: qualityPassed && snrPassed
        )
    }
    
    private func validateStressTestResults(results: PerformanceValidationResults) async throws {
        print("\n🔥 Stress Test Validation")
        print("-" * 40)
        
        // Quick stress test - 50 rapid operations
        let operationCount = 50
        let startTime = CFAbsoluteTimeGetCurrent()
        var successCount = 0
        
        for _ in 0..<operationCount {
            autoreleasepool {
                do {
                    let pcmData = createTestAudio(duration: 0.05) // 50ms
                    let encoded = try OpusSwiftWrapper.encode(pcmData: pcmData)
                    let _ = try OpusSwiftWrapper.decode(opusData: encoded)
                    successCount += 1
                } catch {
                    // Count failures
                }
            }
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let successRate = Double(successCount) / Double(operationCount)
        let opsPerSecond = Double(operationCount) / elapsed
        
        let stressPassed = successRate > 0.95 && opsPerSecond > 20
        
        print("Stress test: \(successCount)/\(operationCount) success (\(String(format: "%.1f%%", successRate * 100))) [\(stressPassed ? "✅" : "❌")]")
        print("Stress throughput: \(String(format: "%.1f", opsPerSecond)) ops/sec [\(opsPerSecond > 20 ? "✅" : "❌")]")
        
        results.stressResults = StressResults(
            successRate: successRate,
            throughput: opsPerSecond,
            passed: stressPassed
        )
    }
    
    // MARK: - Report Generation
    
    private func printValidationReport(results: PerformanceValidationResults) {
        print("\n" + "="*60)
        print("📊 PERFORMANCE VALIDATION SUMMARY")
        print("="*60)
        
        let categories = [
            ("Recording", results.recordingResults.passed),
            ("Codec", results.codecResults.passed),
            ("Playback", results.playbackResults.passed),
            ("Memory", results.memoryResults.passed),
            ("Concurrent", results.concurrentResults.passed),
            ("Quality", results.qualityResults.passed),
            ("Stress", results.stressResults.passed)
        ]
        
        for (category, passed) in categories {
            print("\(category): [\(passed ? "✅ PASS" : "❌ FAIL")]")
        }
        
        let passedCount = categories.filter { $0.1 }.count
        results.overallScore = Double(passedCount) / Double(categories.count)
        
        print("\nOverall Score: \(String(format: "%.1f%%", results.overallScore * 100))")
        print("Status: [\(results.allTestsPassed ? "✅ ALL TESTS PASSED" : "❌ SOME TESTS FAILED")]")
        print("="*60 + "\n")
    }
    
    // MARK: - Helper Methods
    
    private func createTestAudio(duration: TimeInterval) -> Data {
        let sampleRate: Float32 = 48000.0
        let sampleCount = Int(Double(sampleRate) * duration)
        var data = Data(capacity: sampleCount * MemoryLayout<Float32>.size)
        
        for i in 0..<sampleCount {
            let sample = sin(2.0 * .pi * 440.0 * Float32(i) / sampleRate) * 0.7
            withUnsafeBytes(of: sample) { data.append(contentsOf: $0) }
        }
        
        return data
    }
    
    private func measureTime(_ block: () throws -> Bool) -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent()
        _ = try? block()
        return CFAbsoluteTimeGetCurrent() - start
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
    
    private func calculateAudioSimilarity(original: Data, decoded: Data) -> Float {
        guard original.count == decoded.count else { return 0.0 }
        
        let sampleCount = original.count / MemoryLayout<Float32>.size
        let originalSamples = original.withUnsafeBytes { $0.bindMemory(to: Float32.self) }
        let decodedSamples = decoded.withUnsafeBytes { $0.bindMemory(to: Float32.self) }
        
        var correlation: Float = 0.0
        var originalSum: Float = 0.0
        var decodedSum: Float = 0.0
        
        for i in 0..<sampleCount {
            correlation += originalSamples[i] * decodedSamples[i]
            originalSum += originalSamples[i] * originalSamples[i]
            decodedSum += decodedSamples[i] * decodedSamples[i]
        }
        
        let magnitude = sqrt(originalSum * decodedSum)
        return magnitude > 0 ? abs(correlation / magnitude) : 0.0
    }
    
    private func calculateSignalToNoiseRatio(original: Data, decoded: Data) -> Float {
        guard original.count == decoded.count else { return 0.0 }
        
        let sampleCount = original.count / MemoryLayout<Float32>.size
        let originalSamples = original.withUnsafeBytes { $0.bindMemory(to: Float32.self) }
        let decodedSamples = decoded.withUnsafeBytes { $0.bindMemory(to: Float32.self) }
        
        var signalPower: Float = 0.0
        var noisePower: Float = 0.0
        
        for i in 0..<sampleCount {
            let signal = originalSamples[i]
            let noise = originalSamples[i] - decodedSamples[i]
            
            signalPower += signal * signal
            noisePower += noise * noise
        }
        
        guard noisePower > 0 else { return 100.0 }
        
        return 10.0 * log10(signalPower / noisePower)
    }
}

// MARK: - Performance Results Structures

class PerformanceValidationResults {
    var recordingResults = RecordingResults()
    var codecResults = CodecResults()
    var playbackResults = PlaybackResults()
    var memoryResults = MemoryResults()
    var concurrentResults = ConcurrentResults()
    var qualityResults = QualityResults()
    var stressResults = StressResults()
    
    var overallScore: Double = 0.0
    
    var allTestsPassed: Bool {
        return recordingResults.passed &&
               codecResults.passed &&
               playbackResults.passed &&
               memoryResults.passed &&
               concurrentResults.passed &&
               qualityResults.passed &&
               stressResults.passed
    }
}

struct RecordingResults {
    var startupTime: Double = 0
    var processingTime: Double = 0
    var passed: Bool = false
}

struct CodecResults {
    var encodingTime: Double = 0
    var decodingTime: Double = 0
    var compressionRatio: Float = 0
    var passed: Bool = false
}

struct PlaybackResults {
    var startupTime: Double = 0
    var passed: Bool = false
}

struct MemoryResults {
    var memoryIncrease: Double = 0
    var passed: Bool = false
}

struct ConcurrentResults {
    var throughput: Double = 0
    var errorRate: Double = 0
    var passed: Bool = false
}

struct QualityResults {
    var audioQuality: Float = 0
    var snr: Float = 0
    var passed: Bool = false
}

struct StressResults {
    var successRate: Double = 0
    var throughput: Double = 0
    var passed: Bool = false
}