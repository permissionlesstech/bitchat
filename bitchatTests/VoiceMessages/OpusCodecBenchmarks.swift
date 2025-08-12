//
// OpusCodecBenchmarks.swift
// bitchatTests
//
// Opus Codec Performance Benchmarks
// Comprehensive benchmarks for audio encoding/decoding performance
//

import XCTest
import AVFoundation
@testable import bitchat

/// Opus codec performance benchmarks
class OpusCodecBenchmarks: XCTestCase {
    
    // Performance targets (in milliseconds)
    struct PerformanceTargets {
        static let encodingMs: Double = 5.0    // 5ms per second of audio
        static let decodingMs: Double = 3.0    // 3ms per second of audio  
        static let memoryMB: Double = 2.0      // 2MB per second of audio
        static let compressionRatio: Float = 6.0 // Minimum 6:1 compression
        static let qualityScore: Float = 0.95   // Minimum quality retention
    }
    
    override func setUpWithError() throws {
        super.setUpWithError()
        
        // Ensure Opus is available for testing
        XCTAssertTrue(OpusSwiftWrapper.isOpusAvailable, "Opus should be available for benchmarks")
    }
    
    // MARK: - Encoding Benchmarks
    
    /// Test encoding performance across different audio durations
    func testEncodingPerformanceByDuration() throws {
        let durations: [TimeInterval] = [1.0, 5.0, 10.0, 30.0, 60.0]
        
        print("\n=== Opus Encoding Performance ===")
        print("Duration | Size(KB) | Time(ms) | Rate(ms/s) | Ratio")
        print("---------|----------|----------|------------|------")
        
        for duration in durations {
            autoreleasepool {
                // Create test audio
                let sampleCount = Int(48000 * duration)
                let pcmData = createTestAudio(sampleCount: sampleCount, frequency: 440)
                
                // Measure encoding
                let startTime = CFAbsoluteTimeGetCurrent()
                
                guard let encodedData = try? OpusSwiftWrapper.encode(pcmData: pcmData) else {
                    XCTFail("Encoding failed for \(duration)s")
                    return
                }
                
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                let rateMs = elapsed / duration
                let compressionRatio = Float(pcmData.count) / Float(encodedData.count)
                
                print(String(format: "%8.1fs | %7.1f | %8.1f | %10.2f | %5.1f:1",
                           duration,
                           Float(encodedData.count) / 1024.0,
                           elapsed,
                           rateMs,
                           compressionRatio))
                
                // Verify performance targets
                XCTAssertLessThan(rateMs, PerformanceTargets.encodingMs,
                                "Encoding rate for \(duration)s should be under \(PerformanceTargets.encodingMs)ms/s")
                XCTAssertGreaterThan(compressionRatio, PerformanceTargets.compressionRatio,
                                   "Compression ratio for \(duration)s should exceed \(PerformanceTargets.compressionRatio):1")
            }
        }
    }
    
    /// Test encoding performance with different audio frequencies
    func testEncodingPerformanceByFrequency() throws {
        let frequencies: [Float] = [100, 440, 1000, 2000, 4000, 8000]
        let duration: TimeInterval = 5.0
        
        print("\n=== Opus Encoding by Frequency ===")
        print("Freq(Hz) | Size(KB) | Time(ms) | Ratio")
        print("---------|----------|----------|------")
        
        for frequency in frequencies {
            autoreleasepool {
                let sampleCount = Int(48000 * duration)
                let pcmData = createTestAudio(sampleCount: sampleCount, frequency: frequency)
                
                let startTime = CFAbsoluteTimeGetCurrent()
                let encodedData = try OpusSwiftWrapper.encode(pcmData: pcmData)
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                
                let compressionRatio = Float(pcmData.count) / Float(encodedData.count)
                
                print(String(format: "%8.0f | %7.1f | %8.1f | %5.1f:1",
                           frequency,
                           Float(encodedData.count) / 1024.0,
                           elapsed,
                           compressionRatio))
                
                XCTAssertLessThan(elapsed, 100, "Encoding should complete within 100ms")
            }
        }
    }
    
    /// Test encoding with complex waveforms (music-like content)
    func testEncodingComplexWaveforms() throws {
        print("\n=== Complex Waveform Encoding ===")
        print("Waveform        | Size(KB) | Time(ms) | Ratio")
        print("----------------|----------|----------|------")
        
        let waveforms = [
            ("Sine 440Hz", { createTestAudio(sampleCount: 48000, frequency: 440) }),
            ("Multi-tone", { createMultiToneAudio(duration: 1.0) }),
            ("White Noise", { createNoiseAudio(sampleCount: 48000) }),
            ("Speech-like", { createSpeechLikeAudio(duration: 1.0) }),
            ("Music-like", { createMusicLikeAudio(duration: 1.0) })
        ]
        
        for (name, generator) in waveforms {
            autoreleasepool {
                let pcmData = generator()
                
                let startTime = CFAbsoluteTimeGetCurrent()
                let encodedData = try OpusSwiftWrapper.encode(pcmData: pcmData)
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                
                let compressionRatio = Float(pcmData.count) / Float(encodedData.count)
                
                print(String(format: "%-15s | %7.1f | %8.1f | %5.1f:1",
                           name,
                           Float(encodedData.count) / 1024.0,
                           elapsed,
                           compressionRatio))
                
                XCTAssertGreaterThan(compressionRatio, 3.0,
                                   "\(name) should achieve at least 3:1 compression")
            }
        }
    }
    
    // MARK: - Decoding Benchmarks
    
    /// Test decoding performance
    func testDecodingPerformance() throws {
        let durations: [TimeInterval] = [1.0, 5.0, 10.0, 30.0]
        
        print("\n=== Opus Decoding Performance ===")
        print("Duration | Size(KB) | Time(ms) | Rate(ms/s)")
        print("---------|----------|----------|----------")
        
        for duration in durations {
            autoreleasepool {
                // Create and encode test data
                let sampleCount = Int(48000 * duration)
                let pcmData = createTestAudio(sampleCount: sampleCount, frequency: 440)
                let encodedData = try OpusSwiftWrapper.encode(pcmData: pcmData)
                
                // Measure decoding
                let startTime = CFAbsoluteTimeGetCurrent()
                let decodedData = try OpusSwiftWrapper.decode(opusData: encodedData)
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                
                let rateMs = elapsed / duration
                
                print(String(format: "%8.1fs | %7.1f | %8.1f | %9.2f",
                           duration,
                           Float(encodedData.count) / 1024.0,
                           elapsed,
                           rateMs))
                
                // Verify performance and accuracy
                XCTAssertLessThan(rateMs, PerformanceTargets.decodingMs,
                                "Decoding rate should be under \(PerformanceTargets.decodingMs)ms/s")
                XCTAssertEqual(decodedData.count, pcmData.count,
                              "Decoded size should match original")
            }
        }
    }
    
    // MARK: - Round-trip Benchmarks
    
    /// Test encoding/decoding round-trip performance
    func testRoundTripPerformance() throws {
        let durations: [TimeInterval] = [1.0, 5.0, 10.0]
        
        print("\n=== Round-trip Performance ===")
        print("Duration | Encode(ms) | Decode(ms) | Total(ms) | Quality")
        print("---------|------------|------------|-----------|--------")
        
        for duration in durations {
            autoreleasepool {
                let sampleCount = Int(48000 * duration)
                let originalPcm = createTestAudio(sampleCount: sampleCount, frequency: 440)
                
                // Measure encoding
                let encodeStart = CFAbsoluteTimeGetCurrent()
                let encodedData = try OpusSwiftWrapper.encode(pcmData: originalPcm)
                let encodeTime = (CFAbsoluteTimeGetCurrent() - encodeStart) * 1000
                
                // Measure decoding
                let decodeStart = CFAbsoluteTimeGetCurrent()
                let decodedPcm = try OpusSwiftWrapper.decode(opusData: encodedData)
                let decodeTime = (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000
                
                let totalTime = encodeTime + decodeTime
                
                // Calculate quality score (simplified)
                let qualityScore = calculateAudioSimilarity(original: originalPcm, decoded: decodedPcm)
                
                print(String(format: "%8.1fs | %10.1f | %10.1f | %9.1f | %7.3f",
                           duration,
                           encodeTime,
                           decodeTime,
                           totalTime,
                           qualityScore))
                
                XCTAssertGreaterThan(qualityScore, PerformanceTargets.qualityScore,
                                   "Quality score should exceed \(PerformanceTargets.qualityScore)")
            }
        }
    }
    
    // MARK: - Memory Benchmarks
    
    /// Test memory usage during codec operations
    func testCodecMemoryUsage() throws {
        let durations: [TimeInterval] = [1.0, 10.0, 60.0]
        
        print("\n=== Codec Memory Usage ===")
        print("Duration | PCM(MB) | Opus(MB) | Peak(MB) | Efficiency")
        print("---------|---------|----------|----------|----------")
        
        for duration in durations {
            autoreleasepool {
                let initialMemory = getCurrentMemoryUsage()
                
                // Create test data
                let sampleCount = Int(48000 * duration)
                let pcmData = createTestAudio(sampleCount: sampleCount, frequency: 440)
                let pcmSizeMB = Float(pcmData.count) / 1024.0 / 1024.0
                
                // Encode
                let encodedData = try OpusSwiftWrapper.encode(pcmData: pcmData)
                let opusSizeMB = Float(encodedData.count) / 1024.0 / 1024.0
                
                let peakMemory = getCurrentMemoryUsage()
                let memoryUsed = peakMemory - initialMemory
                let memoryMB = Float(memoryUsed) / 1024.0 / 1024.0
                
                let efficiency = pcmSizeMB / memoryMB
                
                print(String(format: "%8.1fs | %7.2f | %8.2f | %8.2f | %10.2f",
                           duration,
                           pcmSizeMB,
                           opusSizeMB,
                           memoryMB,
                           efficiency))
                
                XCTAssertLessThan(memoryMB, Float(PerformanceTargets.memoryMB * duration),
                                "Memory usage should be under target")
            }
        }
    }
    
    // MARK: - Stress Tests
    
    /// Test codec under heavy load
    func testCodecStressTest() async throws {
        let concurrentOperations = 10
        let operationsPerThread = 20
        
        print("\n=== Codec Stress Test ===")
        print("Testing \(concurrentOperations) concurrent threads, \(operationsPerThread) operations each")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        var successCount = 0
        var errorCount = 0
        
        await withTaskGroup(of: (Int, Int).self) { group in
            for _ in 0..<concurrentOperations {
                group.addTask {
                    var threadSuccess = 0
                    var threadErrors = 0
                    
                    for _ in 0..<operationsPerThread {
                        autoreleasepool {
                            do {
                                // Create test data
                                let pcmData = createTestAudio(sampleCount: 4800, frequency: 440) // 0.1s
                                
                                // Encode/decode
                                let encoded = try OpusSwiftWrapper.encode(pcmData: pcmData)
                                let decoded = try OpusSwiftWrapper.decode(opusData: encoded)
                                
                                if decoded.count == pcmData.count {
                                    threadSuccess += 1
                                } else {
                                    threadErrors += 1
                                }
                            } catch {
                                threadErrors += 1
                            }
                        }
                    }
                    
                    return (threadSuccess, threadErrors)
                }
            }
            
            for await (success, errors) in group {
                successCount += success
                errorCount += errors
            }
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let totalOps = concurrentOperations * operationsPerThread
        let opsPerSecond = Double(totalOps) / elapsed
        let successRate = Double(successCount) / Double(totalOps)
        
        print("Results:")
        print("  Total operations: \(totalOps)")
        print("  Success: \(successCount)")
        print("  Errors: \(errorCount)")
        print("  Success rate: \(String(format: "%.1f%%", successRate * 100))")
        print("  Operations/second: \(String(format: "%.1f", opsPerSecond))")
        print("  Total time: \(String(format: "%.2f", elapsed))s")
        
        // Verify stress test results
        XCTAssertGreaterThan(successRate, 0.95, "Success rate should be > 95% under stress")
        XCTAssertGreaterThan(opsPerSecond, 100, "Should handle > 100 operations/second")
    }
    
    // MARK: - Quality Benchmarks
    
    /// Test audio quality preservation
    func testAudioQualityPreservation() throws {
        let testCases = [
            ("Pure Tone", createTestAudio(sampleCount: 48000, frequency: 440)),
            ("Multi Frequency", createMultiToneAudio(duration: 1.0)),
            ("Speech Pattern", createSpeechLikeAudio(duration: 1.0)),
            ("Complex Music", createMusicLikeAudio(duration: 1.0))
        ]
        
        print("\n=== Audio Quality Preservation ===")
        print("Test Case       | Ratio | SNR(dB) | Quality")
        print("----------------|-------|---------|--------")
        
        for (name, originalPcm) in testCases {
            autoreleasepool {
                let encodedData = try OpusSwiftWrapper.encode(pcmData: originalPcm)
                let decodedPcm = try OpusSwiftWrapper.decode(opusData: encodedData)
                
                let compressionRatio = Float(originalPcm.count) / Float(encodedData.count)
                let snr = calculateSignalToNoiseRatio(original: originalPcm, decoded: decodedPcm)
                let quality = calculateAudioSimilarity(original: originalPcm, decoded: decodedPcm)
                
                print(String(format: "%-15s | %5.1f | %7.1f | %7.3f",
                           name,
                           compressionRatio,
                           snr,
                           quality))
                
                XCTAssertGreaterThan(quality, 0.9, "\(name) quality should be > 0.9")
                XCTAssertGreaterThan(snr, 30.0, "\(name) SNR should be > 30dB")
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func createTestAudio(sampleCount: Int, frequency: Float) -> Data {
        var data = Data(capacity: sampleCount * MemoryLayout<Float32>.size)
        let sampleRate: Float32 = 48000.0
        
        for i in 0..<sampleCount {
            let sample = sin(2.0 * .pi * frequency * Float32(i) / sampleRate) * 0.7
            withUnsafeBytes(of: sample) { data.append(contentsOf: $0) }
        }
        
        return data
    }
    
    private func createMultiToneAudio(duration: TimeInterval) -> Data {
        let sampleCount = Int(48000 * duration)
        var data = Data(capacity: sampleCount * MemoryLayout<Float32>.size)
        let sampleRate: Float32 = 48000.0
        
        let frequencies: [Float32] = [220, 440, 880, 1760]
        
        for i in 0..<sampleCount {
            var sample: Float32 = 0
            for freq in frequencies {
                sample += sin(2.0 * .pi * freq * Float32(i) / sampleRate) * 0.25
            }
            sample *= 0.7
            withUnsafeBytes(of: sample) { data.append(contentsOf: $0) }
        }
        
        return data
    }
    
    private func createNoiseAudio(sampleCount: Int) -> Data {
        var data = Data(capacity: sampleCount * MemoryLayout<Float32>.size)
        
        for _ in 0..<sampleCount {
            let sample = Float32.random(in: -0.5...0.5)
            withUnsafeBytes(of: sample) { data.append(contentsOf: $0) }
        }
        
        return data
    }
    
    private func createSpeechLikeAudio(duration: TimeInterval) -> Data {
        let sampleCount = Int(48000 * duration)
        var data = Data(capacity: sampleCount * MemoryLayout<Float32>.size)
        let sampleRate: Float32 = 48000.0
        
        // Simulate speech with varying frequency and amplitude
        for i in 0..<sampleCount {
            let t = Float32(i) / sampleRate
            let freq = 150 + 100 * sin(t * 3.0) // Varying fundamental frequency
            let amplitude = 0.5 * (1.0 + sin(t * 2.0)) // Varying amplitude
            let sample = sin(2.0 * .pi * freq * t) * amplitude * 0.4
            withUnsafeBytes(of: sample) { data.append(contentsOf: $0) }
        }
        
        return data
    }
    
    private func createMusicLikeAudio(duration: TimeInterval) -> Data {
        let sampleCount = Int(48000 * duration)
        var data = Data(capacity: sampleCount * MemoryLayout<Float32>.size)
        let sampleRate: Float32 = 48000.0
        
        // Simulate music with harmonics
        let fundamentalFreq: Float32 = 220.0
        
        for i in 0..<sampleCount {
            let t = Float32(i) / sampleRate
            var sample: Float32 = 0
            
            // Add harmonics
            sample += sin(2.0 * .pi * fundamentalFreq * t) * 0.4        // Fundamental
            sample += sin(2.0 * .pi * fundamentalFreq * 2 * t) * 0.2    // 2nd harmonic
            sample += sin(2.0 * .pi * fundamentalFreq * 3 * t) * 0.1    // 3rd harmonic
            sample += sin(2.0 * .pi * fundamentalFreq * 4 * t) * 0.05   // 4th harmonic
            
            sample *= 0.6
            withUnsafeBytes(of: sample) { data.append(contentsOf: $0) }
        }
        
        return data
    }
    
    private func calculateAudioSimilarity(original: Data, decoded: Data) -> Float {
        // Simplified quality metric - correlation coefficient
        guard original.count == decoded.count else { return 0.0 }
        
        let sampleCount = original.count / MemoryLayout<Float32>.size
        guard sampleCount > 0 else { return 0.0 }
        
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
        guard sampleCount > 0 else { return 0.0 }
        
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
        
        let avgSignalPower = signalPower / Float(sampleCount)
        let avgNoisePower = noisePower / Float(sampleCount)
        
        guard avgNoisePower > 0 else { return 100.0 } // Perfect quality
        
        return 10.0 * log10(avgSignalPower / avgNoisePower)
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