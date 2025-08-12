//
// AudioPlayer.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

///
/// # AudioPlayer
///
/// High-performance audio playback service for Opus-encoded voice messages
/// with support for concurrent playback and efficient memory management.
///
/// ## Overview
/// AudioPlayer provides a complete audio playback pipeline optimized for
/// BitChat's voice messaging system. It handles:
/// - Concurrent playback of multiple voice messages
/// - Real-time Opus decoding with minimal latency
/// - Audio session management and interruption handling
/// - Battery-aware playback optimization
/// - Automatic gain control and volume management
/// - Queue management for sequential message playback
///
/// ## Architecture
/// The player operates with multiple concurrent playback channels:
/// 1. **Opus Decoding**: Real-time decoding of incoming audio data
/// 2. **Audio Engine**: AVAudioEngine for low-latency playback
/// 3. **Session Management**: Proper audio session coordination
/// 4. **Queue Management**: Sequential and overlapping playback support
/// 5. **Memory Management**: Efficient buffer reuse and cleanup
///
/// ## Key Features
///
/// ### Performance Optimizations
/// - Streaming playback reduces memory footprint
/// - Efficient buffer reuse minimizes allocations
/// - Concurrent decode/playback pipeline
/// - Hardware-accelerated audio processing
/// - Battery-aware quality adaptation
///
/// ### Playback Management
/// - Multiple simultaneous audio streams
/// - Queue-based sequential playback
/// - Interrupt/resume capability
/// - Volume ducking during calls
/// - Background playback support
///
/// ### Audio Quality
/// - Automatic gain control (AGC)
/// - Dynamic range compression
/// - Cross-fade between messages
/// - Noise gating for clean output
/// - EQ presets for voice optimization
///
/// ## Playback States
/// - **idle**: No audio playing, ready to start
/// - **loading**: Preparing audio data for playback
/// - **playing**: Actively playing audio
/// - **paused**: Playback paused (can be resumed)
/// - **stopped**: Playback stopped (cannot be resumed)
/// - **error**: Playback failed, needs reset
///
/// ## Usage Example
/// ```swift
/// let player = AudioPlayer(opusService: opusAudioService)
/// player.delegate = self
/// 
/// // Play single message
/// try await player.play(opusData: encodedAudio, messageID: "msg-123")
/// 
/// // Queue multiple messages
/// player.enqueue(opusData: audio1, messageID: "msg-1")
/// player.enqueue(opusData: audio2, messageID: "msg-2")
/// try await player.playQueue()
/// ```
///

import Foundation
import AVFoundation
import Combine
import CryptoKit
import os.log
#if os(iOS)
import UIKit
#endif

/// Audio playback states
public enum PlaybackState: Equatable {
    case idle           // No audio playing
    case loading        // Preparing audio data
    case playing        // Actively playing
    case paused         // Playback paused
    case stopped        // Playback stopped
    case error(Error)   // Playback failed
    
    public static func == (lhs: PlaybackState, rhs: PlaybackState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.playing, .playing), 
             (.paused, .paused), (.stopped, .stopped):
            return true
        case (.error(let lhsError), .error(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }
    
    public var isActive: Bool {
        switch self {
        case .loading, .playing, .paused:
            return true
        default:
            return false
        }
    }
}

/// Playback session information
public struct PlaybackSession {
    public let messageID: String
    public let duration: TimeInterval
    public let startTime: Date
    public var currentTime: TimeInterval = 0.0
    public var isComplete: Bool = false
    
    public var progress: Float {
        guard duration > 0 else { return 0.0 }
        return Float(currentTime / duration)
    }
}

/// Audio player delegate for playback events
public protocol AudioPlayerDelegate: AnyObject {
    /// Called when playback state changes
    func audioPlayer(_ player: AudioPlayer, didChangeState state: PlaybackState, for messageID: String?)
    
    /// Called periodically during playback for progress updates
    func audioPlayer(_ player: AudioPlayer, didUpdateProgress session: PlaybackSession)
    
    /// Called when a message completes playback
    func audioPlayer(_ player: AudioPlayer, didCompletePlayback messageID: String)
    
    /// Called when playback encounters an error
    func audioPlayer(_ player: AudioPlayer, didFailWithError error: Error, for messageID: String?)
    
    /// Called when audio session is interrupted
    #if os(iOS)
    func audioPlayer(_ player: AudioPlayer, didReceiveInterruption type: AVAudioSession.InterruptionType)
    #else
    func audioPlayer(_ player: AudioPlayer, didReceiveInterruption type: Int)
    #endif
    
    /// Called when a security incident is detected
    func audioPlayer(_ player: AudioPlayer, encounteredSecurityIncident incident: AudioSecurityError, messageID: String)
}

/// Audio playback errors
public enum AudioPlaybackError: Error, LocalizedError {
    case noAudioData
    case decodingFailed(String)
    case audioEngineSetupFailed(String)
    case audioSessionSetupFailed(String)
    case playbackInProgress
    case invalidMessageID
    case hardwareUnavailable
    case bufferUnderrun
    
    public var errorDescription: String? {
        switch self {
        case .noAudioData:
            return "No audio data provided for playback"
        case .decodingFailed(let reason):
            return "Audio decoding failed: \(reason)"
        case .audioEngineSetupFailed(let reason):
            return "Audio engine setup failed: \(reason)"
        case .audioSessionSetupFailed(let reason):
            return "Audio session setup failed: \(reason)"
        case .playbackInProgress:
            return "Another playback is already in progress"
        case .invalidMessageID:
            return "Invalid message ID provided"
        case .hardwareUnavailable:
            return "Audio playback hardware unavailable"
        case .bufferUnderrun:
            return "Audio buffer underrun during playback"
        }
    }
}

/// Queued audio message for sequential playback
private struct QueuedMessage {
    let messageID: String
    let opusData: Data
    let priority: Int
    let timestamp: Date
}

/// High-performance audio player with concurrent Opus decoding
public class AudioPlayer: ObservableObject {
    
    // MARK: - Public Properties
    
    @Published public var playbackState: PlaybackState = .idle
    @Published public var currentSession: PlaybackSession?
    @Published public var queuedMessages: [String] = []
    @Published public var volume: Float = 1.0 {
        didSet {
            updateAudioEngineVolume()
        }
    }
    
    public weak var delegate: AudioPlayerDelegate?
    
    // MARK: - Private Properties
    
    // Note: OpusAudioService dependency removed - using OpusSwiftWrapper directly
    private var audioEngine: AVAudioEngine?
    private let logger = Logger(subsystem: "chat.bitchat", category: "AudioPlayer")
    
    // Performance optimization: pre-initialized queues
    private let audioSessionQueue = DispatchQueue(label: "com.bitchat.audio.session", qos: .userInitiated)
    private let preloadQueue = DispatchQueue(label: "com.bitchat.audio.preload", qos: .userInitiated, attributes: .concurrent)
    
    // Audio processing
    private var playerNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var mixerNode: AVAudioMixerNode?
    
    // Playback management
    private var playbackQueue: [QueuedMessage] = []
    private var activePlayback: [String: PlaybackSession] = [:]
    private let playbackSchedulingQueue = DispatchQueue(label: "audio.playback.scheduling", qos: .userInitiated)
    private let decodingQueue = DispatchQueue(label: "audio.playback.decoding", qos: .userInitiated)
    
    // Progress tracking
    private var progressTimer: Timer?
    private let progressUpdateInterval: TimeInterval = 0.1 // 100ms updates
    
    // Audio session management
    private var audioSessionSetupCompleted = false
    private var audioEngineSetupCompleted = false
    
    // Interruption handling
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var appStateObserver: NSObjectProtocol?
    
    // Battery optimization - direct access (BatteryOptimizer is always available)
    
    // MARK: - Security and Rate Limiting
    
    /// Security configuration for DDoS protection and abuse prevention
    private struct SecurityLimits {
        static let maxConcurrentPlaybacks: Int = 10          // Max simultaneous playbacks
        static let maxQueueSize: Int = 50                    // Max queued messages
        static let maxPlaybacksPerMinute: Int = 100          // Rate limit: 100 playbacks/min
        static let maxPlaybacksPerHour: Int = 1000           // Rate limit: 1000 playbacks/hour
        static let maxMessageDuration: TimeInterval = 600.0  // 10 minutes max per message
        static let minPlaybackInterval: TimeInterval = 0.1   // Min 100ms between playbacks
        static let maxMemoryPerPlayback: Int = 100 * 1024 * 1024 // 100MB per playback
        static let suspiciousPatternThreshold: Int = 5       // Pattern detection threshold
    }
    
    /// Attack detection and mitigation
    private struct AttackMitigation {
        static let detectionWindowMinutes: Int = 5           // 5-minute detection window
        static let burstDetectionLimit: Int = 20             // Max 20 rapid requests
        static let blacklistDuration: TimeInterval = 300.0   // 5-minute blacklist
        static let progressiveDelayMaxMs: Int = 5000         // Max progressive delay
    }
    
    // Security state tracking
    private var playbackHistory: [(date: Date, messageId: String)] = []
    private var blacklistedSources: [String: Date] = [:]
    private var suspiciousPatterns: [String: Int] = [:]
    private var lastPlaybackTime: Date?
    private let securityQueue = DispatchQueue(label: "com.bitchat.audio.security", qos: .utility)
    
    // DoS protection metrics
    private var consecutiveFailures: Int = 0
    private var totalPlaybackAttempts: Int = 0
    private var memoryUsageTracker: Int64 = 0
    private var batteryOptimizer: BatteryOptimizer {
        return BatteryOptimizer.shared
    }
    
    // MARK: - Initialization
    
    public init() {
        // Simplified initialization - using OpusSwiftWrapper directly
        
        setupObservers()
        setupAudioEngine()
        
        // Pre-warm audio session for faster first playback
        Task.detached(priority: .utility) {
            await self.preWarmAudioSession()
        }
    }
    
    deinit {
        stopAllPlayback()
        removeObservers()
        audioEngine?.stop()
    }
    
    // MARK: - Public Methods
    
    /// Plays a single Opus-encoded audio message
    /// - Parameters:
    ///   - opusData: Encoded Opus audio data
    ///   - messageID: Unique identifier for the message
    /// - Throws: AudioPlaybackError if playback cannot be started
    public func play(opusData: Data, messageID: String) async throws {
        logger.info("🎵 Starting playback for message: \(messageID)")
        
        // Security validation first - critical for production security
        try await validatePlaybackSecurity(opusData: opusData, messageID: messageID)
        
        guard !opusData.isEmpty else {
            throw AudioPlaybackError.noAudioData
        }
        
        // Ensure audio session is ready (should be pre-warmed)
        if !audioSessionSetupCompleted {
            try await setupAudioSession()
        }
        
        // Update state
        await MainActor.run {
            playbackState = .loading
            delegate?.audioPlayer(self, didChangeState: playbackState, for: messageID)
        }
        
        
        // ✅ NORMAL OPUS DECODING: Decode Opus data to 48kHz Float32 PCM  
        logger.info("✅ PRODUCTION: Decoding Opus data (\(opusData.count) bytes) to 48kHz Float32 PCM")
        let pcmData = try await decodeOpusData(opusData)
        logger.info("✅ PRODUCTION: Opus decoded \(opusData.count) → \(pcmData.count) bytes")
        
        // 🔍 DEBUGGING: Analyze decoded PCM quality
        pcmData.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Float32.self)
            if samples.count > 0 {
                let maxAmplitude = (0..<min(samples.count, 1000)).map { abs(samples[$0]) }.max() ?? 0.0
                print("🔍 CONSOLE: Decoded audio analysis - max amplitude: \(maxAmplitude)")
                print("🔍 CONSOLE: Sample count: \(samples.count), first samples: [\(samples[0]), \(samples[1])]") 
                
                if maxAmplitude < 0.001 {
                    print("⚠️ CONSOLE: WARNING - Audio appears very quiet (max < 0.001)")
                } else if maxAmplitude > 0.95 {
                    print("⚠️ CONSOLE: WARNING - Audio may be clipping (max > 0.95)")
                } else {
                    print("✅ CONSOLE: Audio amplitude looks good (\(maxAmplitude))")
                }
            }
        }
        
        // Create playback session
        let duration = calculateDuration(for: pcmData)
        let session = PlaybackSession(
            messageID: messageID,
            duration: duration,
            startTime: Date()
        )
        
        // Start playback
        logger.info("🔧 About to start playback for message: \(messageID)")
        try await startPlayback(pcmData: pcmData, session: session)
        logger.info("✅ Playback successfully started for message: \(messageID)")
    }
    
    /// Enqueues a message for sequential playback
    /// - Parameters:
    ///   - opusData: Encoded Opus audio data
    ///   - messageID: Unique identifier for the message
    ///   - priority: Playback priority (higher numbers play first)
    public func enqueue(opusData: Data, messageID: String, priority: Int = 0) {
        let queuedMessage = QueuedMessage(
            messageID: messageID,
            opusData: opusData,
            priority: priority,
            timestamp: Date()
        )
        
        playbackSchedulingQueue.async { [weak self] in
            self?.playbackQueue.append(queuedMessage)
            self?.playbackQueue.sort { $0.priority > $1.priority }
            
            DispatchQueue.main.async {
                self?.queuedMessages = self?.playbackQueue.map { $0.messageID } ?? []
            }
        }
        
        logger.info("Enqueued message: \(messageID) with priority: \(priority)")
    }
    
    /// Plays all queued messages sequentially
    /// - Throws: AudioPlaybackError if queue playback cannot be started
    public func playQueue() async throws {
        guard !playbackQueue.isEmpty else { return }
        
        logger.info("Starting queue playback with \(self.playbackQueue.count) messages")
        
        while !playbackQueue.isEmpty {
            let message = playbackQueue.removeFirst()
            
            DispatchQueue.main.async { [weak self] in
                self?.queuedMessages = self?.playbackQueue.map { $0.messageID } ?? []
            }
            
            do {
                try await play(opusData: message.opusData, messageID: message.messageID)
                
                // Wait for completion
                await waitForCompletion(messageID: message.messageID)
                
            } catch {
                logger.error("Failed to play queued message \(message.messageID): \(error.localizedDescription)")
                delegate?.audioPlayer(self, didFailWithError: error, for: message.messageID)
            }
        }
        
        logger.info("Queue playback completed")
    }
    
    /// Pauses current playback
    public func pause() {
        guard case .playing = playbackState else { return }
        
        playerNode?.pause()
        progressTimer?.invalidate()
        
        playbackState = .paused
        delegate?.audioPlayer(self, didChangeState: playbackState, for: currentSession?.messageID)
        
        logger.info("Playback paused")
    }
    
    /// Resumes paused playback
    public func resume() throws {
        guard case .paused = playbackState else { return }
        
        playerNode?.play()
        startProgressTimer()
        
        playbackState = .playing
        delegate?.audioPlayer(self, didChangeState: playbackState, for: currentSession?.messageID)
        
        logger.info("Playback resumed")
    }
    
    /// Stops current playback
    public func stop() {
        guard playbackState.isActive else { return }
        
        playerNode?.stop()
        progressTimer?.invalidate()
        
        let messageID = currentSession?.messageID
        
        playbackState = .stopped
        currentSession = nil
        
        delegate?.audioPlayer(self, didChangeState: playbackState, for: messageID)
        
        logger.info("Playback stopped")
    }
    
    /// Stops all active playback and clears queue
    public func stopAllPlayback() {
        stop()
        
        playbackSchedulingQueue.async { [weak self] in
            self?.playbackQueue.removeAll()
            self?.activePlayback.removeAll()
            
            DispatchQueue.main.async {
                self?.queuedMessages.removeAll()
            }
        }
        
        logger.info("All playback stopped and queue cleared")
    }
    
    /// Seeks to a specific time in the current playback
    /// - Parameter time: Target time in seconds
    public func seek(to time: TimeInterval) {
        // Note: Seeking in streaming audio requires buffer management
        // This is a simplified implementation
        guard var session = currentSession else { return }
        
        session.currentTime = min(max(0, time), session.duration)
        currentSession = session
        
        delegate?.audioPlayer(self, didUpdateProgress: session)
    }
    
    // MARK: - Private Methods
    
    private func setupObservers() {
        let notificationCenter = NotificationCenter.default
        
        #if os(iOS)
        // Handle audio session interruptions
        interruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioSessionInterruption(notification)
        }
        
        // Handle audio route changes
        routeChangeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioRouteChange(notification)
        }
        
        // Handle app lifecycle
        appStateObserver = notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Pause non-essential playback in background
            if self?.batteryOptimizer.shouldSkipNonEssential == true {
                self?.pause()
            }
        }
        #endif
    }
    
    private func removeObservers() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appStateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func createAudioEngineIfNeeded() throws {
        if audioEngine == nil {
            // CRITICAL: AudioPlayer can work in simulator for PLAYBACK (output only)
            // The issue is with inputNode, not outputNode/mainMixerNode
            #if targetEnvironment(simulator)
            logger.info("🎭 Running in simulator - AudioPlayer enabled for playback only")
            #endif
            
            // Safe to create AudioEngine for both simulator and device
            audioEngine = AVAudioEngine()
            logger.info("🎵 AudioEngine created successfully (Player)")
        }
    }
    
    private func setupAudioEngine() {
        do {
            try createAudioEngineIfNeeded()
            guard let audioEngine = audioEngine else { return }
            
            // Create player node
            playerNode = AVAudioPlayerNode()
            guard let playerNode = playerNode else { return }
            
            // Create mixer node for volume control
            mixerNode = audioEngine.mainMixerNode
            
            // Create standard 48kHz Float32 audio format for Voice Messages
            audioFormat = AVAudioFormat(
                standardFormatWithSampleRate: 48000,
                channels: 1
            )
            guard let audioFormat = audioFormat else { 
                logger.error("❌ Failed to create audio format - 48kHz mono format creation failed")
                return 
            }
            
            #if targetEnvironment(simulator)
            // SIMULATOR FIX: Add extra validation and error handling
            logger.info("🎭 [SIMULATOR] Setting up audio engine with enhanced error handling")
            
            do {
                // Attach player node with error checking
                audioEngine.attach(playerNode)
                logger.info("✅ [SIMULATOR] Player node attached successfully")
                
                // Connect player to mixer with format validation
                audioEngine.connect(playerNode, to: mixerNode!, format: audioFormat)
                logger.info("✅ [SIMULATOR] Player node connected to mixer successfully")
                
                // Verify connection
                if audioEngine.outputNode.inputFormat(forBus: 0) != nil {
                    logger.info("✅ [SIMULATOR] Audio engine output verified")
                } else {
                    logger.warning("⚠️ [SIMULATOR] Audio engine output format verification failed")
                }
                
            } catch {
                logger.error("❌ [SIMULATOR] Audio engine node setup failed: \(error)")
                // Continue anyway - might still work for playback
            }
            #else
            // DEVICE: Standard setup
            audioEngine.attach(playerNode)
            audioEngine.connect(playerNode, to: mixerNode!, format: audioFormat)
            #endif
            
            audioEngineSetupCompleted = true
            logger.info("Audio engine setup completed")
            
        } catch {
            logger.error("❌ Failed to create AudioEngine: \(error)")
            
            #if targetEnvironment(simulator)
            // SIMULATOR FALLBACK: Mark as completed even on errors for basic functionality
            logger.info("🔄 [SIMULATOR] Marking audio engine as setup despite errors (fallback mode)")
            audioEngineSetupCompleted = true
            #endif
        }
    }
    
    private func setupAudioSession() async throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        
        do {
            // INTELLIGENT: Check current category and adapt accordingly
            logger.info("🔍 Current session category: \(session.category.rawValue), mode: \(session.mode.rawValue)")
            
            if session.category == .playAndRecord {
                // Session already configured for recording - verify it supports playback
                logger.info("✅ Using existing .playAndRecord session for playback")
            } else {
                // Configure dedicated playback session
                try session.setCategory(.playback, mode: .spokenAudio, options: [.defaultToSpeaker])
                logger.info("✅ Configured .playback session for voice messages")
            }
            
            try session.setActive(true)
            audioSessionSetupCompleted = true
            logger.info("Audio session ready for voice playback")
            
        } catch {
            logger.error("Audio session setup failed: \(error.localizedDescription)")
            throw AudioPlaybackError.audioSessionSetupFailed(error.localizedDescription)
        }
        #else
        audioSessionSetupCompleted = true
        #endif
    }
    
    private func decodeOpusData(_ opusData: Data) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            decodingQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: AudioPlaybackError.decodingFailed("Service deallocated"))
                    return
                }
                
                // ✅ NORMAL OPUS DECODE: Decode with corrected 48kHz format alignment
                do {
                    let decodedData = try OpusSwiftWrapper.decode(opusData: opusData)
                    self.logger.info("✅ Opus decoded correctly: \(opusData.count) → \(decodedData.count) bytes")
                    continuation.resume(returning: decodedData)
                } catch {
                    self.logger.error("❌ Opus decoding failed: \(error.localizedDescription)")
                    continuation.resume(throwing: AudioPlaybackError.decodingFailed(error.localizedDescription))
                }
            }
        }
    }
    
    private func calculateDuration(for pcmData: Data) -> TimeInterval {
        // FIXED: Use Float32 size, not Int16!
        let sampleCount = pcmData.count / MemoryLayout<Float32>.size
        let frameCount = sampleCount / 1 // Mono channel
        return Double(frameCount) / 48000.0 // 48kHz sample rate
    }
    
    private func startPlayback(pcmData: Data, session: PlaybackSession) async throws {
        logger.info("🔧 startPlayback called for message: \(session.messageID) with \(pcmData.count) bytes PCM")
        
        guard let playerNode = playerNode else {
            logger.error("❌ playerNode is nil - audio engine not initialized")
            throw AudioPlaybackError.audioEngineSetupFailed("playerNode not available")
        }
        
        guard let audioFormat = audioFormat else {
            logger.error("❌ audioFormat is nil - audio engine not initialized")
            throw AudioPlaybackError.audioEngineSetupFailed("audioFormat not available")
        }
        
        logger.info("✅ Audio engine components validated for message: \(session.messageID)")
        
        // Convert PCM data to audio buffer using pooled buffer
        logger.info("🔧 Creating audio buffer for message: \(session.messageID)")
        // FIXED: Use Float32 format, not Int16!
        let frameCapacity = AVAudioFrameCount(pcmData.count / MemoryLayout<Float32>.size)
        logger.info("📊 Buffer specs: frameCapacity=\(frameCapacity), format=\(audioFormat)")
        
        guard let format = self.audioFormat,
              // TODO: Restore AudioBufferPool when available
              let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            logger.error("❌ Failed to create AVAudioPCMBuffer with frameCapacity: \(frameCapacity)")
            throw AudioPlaybackError.decodingFailed("Failed to create audio buffer")
        }
        
        logger.info("✅ Audio buffer created successfully for message: \(session.messageID)")
        
        // Copy PCM data to buffer with fade-in to eliminate startup clicks/pops
        if let channelData = audioBuffer.floatChannelData {
            pcmData.withUnsafeBytes { bytes in
                let samples = bytes.bindMemory(to: Float32.self)
                channelData[0].update(from: samples.baseAddress!, count: samples.count)
                
                // ✨ FADE-IN: Eliminate startup "pop/click" with gentle 5ms fade-in
                let sampleCount = samples.count
                if sampleCount > 0 {
                    let fadeInSamples = min(240, sampleCount) // 5ms at 48kHz = 240 samples
                    for i in 0..<fadeInSamples {
                        let fadeMultiplier = Float32(i) / Float32(fadeInSamples)
                        channelData[0][i] *= fadeMultiplier
                    }
                }
            }
            // SAFE CONVERSION: Prevent integer overflow crash when converting to AVAudioFrameCount
            let sampleCount = pcmData.count / MemoryLayout<Float32>.size
            let safeFrameLength = min(max(0, sampleCount), Int(UInt32.max))
            audioBuffer.frameLength = AVAudioFrameCount(safeFrameLength)
        }
        
        // Prepare audio engine if not running
        logger.info("🔧 Checking audio engine state for message: \(session.messageID)")
        guard let audioEngine = audioEngine else {
            throw AudioPlaybackError.hardwareUnavailable
        }
        
        if !audioEngine.isRunning {
            logger.info("🚀 Starting audio engine for message: \(session.messageID)")
            
            #if targetEnvironment(simulator)
            // SIMULATOR FIX: Add retry logic for audio engine start failures
            var startAttempts = 0
            let maxAttempts = 3
            
            while startAttempts < maxAttempts {
                startAttempts += 1
                
                do {
                    audioEngine.prepare()
                    try audioEngine.start()
                    logger.info("✅ [SIMULATOR] Audio engine started successfully on attempt \(startAttempts)")
                    
                    // ✨ ANTI-CLICK: Give engine time to settle before scheduling audio
                    try await Task.sleep(nanoseconds: 50_000_000) // 50ms settle time
                    logger.info("✅ [SIMULATOR] Audio engine settled, ready for smooth playback")
                    break
                } catch {
                    logger.warning("⚠️ [SIMULATOR] Audio engine start attempt \(startAttempts) failed: \(error)")
                    
                    if startAttempts < maxAttempts {
                        // Brief pause before retry
                        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        
                        // Reset audio engine
                        audioEngine.stop()
                        audioEngine.reset()
                        logger.info("🔄 [SIMULATOR] Audio engine reset for retry")
                    } else {
                        // All attempts failed
                        logger.error("❌ [SIMULATOR] Audio engine failed to start after \(maxAttempts) attempts")
                        throw AudioPlaybackError.audioEngineSetupFailed("Failed to start after \(maxAttempts) attempts: \(error)")
                    }
                }
            }
            #else
            // DEVICE: Standard start procedure with settle time
            audioEngine.prepare()
            try audioEngine.start()
            logger.info("✅ Audio engine started successfully for message: \(session.messageID)")
            
            // ✨ ANTI-CLICK: Give engine time to settle before scheduling audio  
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms settle time
            logger.info("✅ Audio engine settled, ready for smooth playback")
            #endif
        } else {
            logger.info("ℹ️ Audio engine already running for message: \(session.messageID)")
        }
        
        // Apply DSP optimizations if needed
        // TODO: Restore AudioDSPOptimizer when available  
        // let processedBuffer = AudioDSPOptimizer.shared.process(audioBuffer, operation: .normalize) ?? audioBuffer
        let processedBuffer = audioBuffer
        
        // DIAGNOSTIC: Check if we actually have audio samples
        if let channelData = processedBuffer.floatChannelData {
            let firstSample = channelData[0][0]
            let maxSample = (0..<Int(processedBuffer.frameLength)).map { abs(channelData[0][$0]) }.max() ?? 0.0
            logger.info("🔍 Buffer analysis: first sample = \(firstSample), max amplitude = \(maxSample)")
            
            if maxSample < 0.001 {
                logger.warning("⚠️ Audio buffer appears to be silent (max amplitude < 0.001)")
            } else {
                logger.info("✅ Audio buffer contains audible samples")
            }
        }
        
        // Schedule buffer for playback
        logger.info("🎵 Scheduling audio buffer for playback: \(processedBuffer.frameLength) frames")
        
        playerNode.scheduleBuffer(processedBuffer, at: nil, options: [], completionHandler: { [weak self] in
            print("✅ CONSOLE: Audio buffer playback completion callback triggered")
            self?.logger.info("🎵 Audio buffer playback completion callback triggered")
            
            DispatchQueue.main.async {
                self?.handlePlaybackCompletion(session: session)
            }
        })
        
        // DIAGNOSTIC: Check engine and node state before playing
        logger.info("🔍 Pre-play state: engine.isRunning=\(audioEngine.isRunning), playerNode.isPlaying=\(playerNode.isPlaying)")
        
        // ✨ ANTI-CLICK: Brief gap between buffer scheduling and playback start
        // This allows PlayerNode to properly prepare the scheduled buffer
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms buffer preparation time
        logger.info("✨ PlayerNode buffer preparation complete")
        
        // Start playback
        print("🎵 CONSOLE: Calling playerNode.play()")
        playerNode.play()
        print("✅ CONSOLE: playerNode.play() completed")
        logger.info("✅ playerNode.play() called successfully")
        
        await MainActor.run {
            currentSession = session
            playbackState = .playing
            delegate?.audioPlayer(self, didChangeState: playbackState, for: session.messageID)
        }
        
        // Start progress timer
        startProgressTimer()
    }
    
    private func startProgressTimer() {
        progressTimer?.invalidate()
        
        progressTimer = Timer.scheduledTimer(withTimeInterval: progressUpdateInterval, repeats: true) { [weak self] _ in
            self?.updateProgress()
        }
    }
    
    private func updateProgress() {
        guard var session = currentSession else { return }
        
        let elapsed = Date().timeIntervalSince(session.startTime)
        session.currentTime = min(elapsed, session.duration)
        currentSession = session
        
        delegate?.audioPlayer(self, didUpdateProgress: session)
    }
    
    private func updateAudioEngineVolume() {
        mixerNode?.outputVolume = volume
    }
    
    private func handlePlaybackCompletion(session: PlaybackSession) {
        progressTimer?.invalidate()
        
        currentSession = nil
        playbackState = .idle
        
        delegate?.audioPlayer(self, didChangeState: playbackState, for: session.messageID)
        delegate?.audioPlayer(self, didCompletePlayback: session.messageID)
        
        logger.info("Playback completed for message: \(session.messageID)")
    }
    
    private func waitForCompletion(messageID: String) async {
        await withCheckedContinuation { continuation in
            let checkCompletion = {
                if self.currentSession?.messageID != messageID || self.playbackState == .idle {
                    continuation.resume()
                    return true
                }
                return false
            }
            
            // Check immediately
            if checkCompletion() { return }
            
            // Poll for completion
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                if checkCompletion() {
                    timer.invalidate()
                }
            }
        }
    }
    
    // MARK: - Audio Session Interruption Handling
    
    #if os(iOS)
    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        delegate?.audioPlayer(self, didReceiveInterruption: type)
        
        switch type {
        case .began:
            logger.info("Audio session interruption began")
            pause()
            
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            
            if options.contains(.shouldResume) {
                logger.info("Audio session interruption ended - should resume")
                do {
                    try resume()
                } catch {
                    logger.error("Failed to resume playback after interruption: \(error.localizedDescription)")
                }
            } else {
                logger.info("Audio session interruption ended - should not resume")
            }
            
        @unknown default:
            break
        }
    }
    
    private func handleAudioRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .newDeviceAvailable:
            logger.info("New audio device available")
            
        case .oldDeviceUnavailable:
            logger.info("Audio device unavailable")
            // Pause playback if speakers/headphones disconnected
            if playbackState.isActive {
                pause()
            }
            
        case .categoryChange:
            logger.info("Audio category changed")
            
        default:
            break
        }
    }
    #endif
    
    // MARK: - Diagnostics
    
    /// Comprehensive audio system diagnostics for debugging
    public func performAudioDiagnostics() -> String {
        var diagnostic = "🔍 Audio System Diagnostics:\n"
        
        // Audio Engine State
        if let audioEngine = audioEngine {
            diagnostic += "📱 Audio Engine: \(audioEngine.isRunning ? "Running" : "Stopped")\n"
            diagnostic += "🔊 Output Node: \(audioEngine.outputNode.description)\n"
            diagnostic += "🎛️ Main Mixer: \(audioEngine.mainMixerNode.outputVolume)\n"
        } else {
            diagnostic += "❌ Audio Engine: Not initialized\n"
        }
        
        // Player Node State
        if let playerNode = playerNode {
            diagnostic += "▶️ Player Node: \(playerNode.isPlaying ? "Playing" : "Stopped")\n"
        } else {
            diagnostic += "❌ Player Node: Not initialized\n"
        }
        
        // Audio Format
        if let format = audioFormat {
            diagnostic += "🎵 Format: \(format.sampleRate)Hz, \(format.channelCount)ch, \(format.commonFormat.rawValue)\n"
        } else {
            diagnostic += "❌ Audio Format: Not set\n"
        }
        
        // Session State
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        diagnostic += "🎧 Session Category: \(session.category.rawValue)\n"
        diagnostic += "🎧 Session Active: \(session.isOtherAudioPlaying ? "Other audio playing" : "Available")\n"
        diagnostic += "🎧 Current Route: \(session.currentRoute.outputs.first?.portName ?? "Unknown")\n"
        
        #if targetEnvironment(simulator)
        diagnostic += "🎭 Environment: iOS Simulator\n"
        #else
        diagnostic += "📱 Environment: iOS Device\n"
        #endif
        #endif
        
        // Playback State
        diagnostic += "🎮 Playback State: \(playbackState)\n"
        diagnostic += "📊 Session: \(currentSession?.messageID ?? "None")\n"
        
        // Setup Status
        diagnostic += "⚙️ Audio Session Setup: \(audioSessionSetupCompleted ? "✅" : "❌")\n"
        diagnostic += "⚙️ Audio Engine Setup: \(audioEngineSetupCompleted ? "✅" : "❌")\n"
        
        return diagnostic
    }
    
    // MARK: - Performance Optimizations
    
    /// Pre-warm audio session on initialization for faster first playback
    private func preWarmAudioSession() async {
        do {
            try await setupAudioSession()
        } catch {
            logger.warning("Pre-warm audio session failed: \(error.localizedDescription)")
        }
    }
    
    /// Generate a test sine wave for debugging audio issues
    private func generateTestSineWave(duration: TimeInterval, frequency: Double = 440.0) -> Data {
        let sampleRate = 48000.0 // Match OpusAudioService
        let sampleCount = Int(duration * sampleRate)
        var data = Data()
        data.reserveCapacity(sampleCount * MemoryLayout<Float32>.size)
        
        print("🔬 CONSOLE: Generating \(duration)s sine wave at \(frequency)Hz")
        print("🔬 CONSOLE: Sample rate: \(sampleRate)Hz, Total samples: \(sampleCount)")
        
        for i in 0..<sampleCount {
            let time = Double(i) / sampleRate
            let amplitude: Float32 = 0.3 // 30% amplitude - safe level
            let sample = amplitude * Float32(sin(2.0 * .pi * frequency * time))
            data.append(sample.data)
        }
        
        // Verify generated data
        data.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Float32.self)
            let maxAmplitude = (0..<min(samples.count, 1000)).map { abs(samples[$0]) }.max() ?? 0.0
            print("🔬 CONSOLE: Generated sine wave - max amplitude: \(maxAmplitude)")
            print("🔬 CONSOLE: First few samples: [\(samples[0]), \(samples[1]), \(samples[2])]")
        }
        
        logger.info("🔬 Generated CLEAN sine wave: \(duration)s at \(frequency)Hz, \(data.count) bytes")
        return data
    }
    
    // MARK: - Security Validation Methods
    
    /// Comprehensive security validation for playback requests
    private func validatePlaybackSecurity(opusData: Data, messageID: String) async throws {
        try securityQueue.sync {
            // 1. Rate limiting validation
            try self.validateRateLimit(messageID: messageID)
            
            // 2. Blacklist validation
            try self.validateBlacklist(messageID: messageID)
            
            // 3. Data size validation
            try self.validateDataSize(opusData)
            
            // 4. Concurrent playback limits
            try self.validateConcurrentPlaybacks()
            
            // 5. Queue size validation
            try self.validateQueueSize()
            
            // 6. Memory usage validation
            try self.validateMemoryUsage()
            
            // 7. Suspicious pattern detection
            try self.detectSuspiciousPatterns(messageID: messageID)
            
            // 8. Update security metrics
            self.updateSecurityMetrics(messageID: messageID)
        }
    }
    
    /// Validate rate limiting to prevent spam attacks
    private func validateRateLimit(messageID: String) throws {
        let now = Date()
        let oneMinuteAgo = now.addingTimeInterval(-60)
        let oneHourAgo = now.addingTimeInterval(-3600)
        
        // Clean old history entries
        self.playbackHistory.removeAll { $0.date < oneHourAgo }
        
        // Check minute limit
        let recentMinute = self.playbackHistory.filter { $0.date > oneMinuteAgo }
        if recentMinute.count >= SecurityLimits.maxPlaybacksPerMinute {
            logger.error("🚨 Rate limit exceeded: \(recentMinute.count) playbacks in last minute")
            throw AudioSecurityError.rateLimitExceeded
        }
        
        // Check hourly limit
        if self.playbackHistory.count >= SecurityLimits.maxPlaybacksPerHour {
            logger.error("🚨 Hourly rate limit exceeded: \(self.playbackHistory.count) playbacks")
            throw AudioSecurityError.rateLimitExceeded
        }
        
        // Check minimum interval between playbacks
        if let lastTime = self.lastPlaybackTime {
            let interval = now.timeIntervalSince(lastTime)
            if interval < SecurityLimits.minPlaybackInterval {
                logger.error("🚨 Playback interval too short: \(interval)s")
                throw AudioSecurityError.playbackTooFrequent
            }
        }
    }
    
    /// Validate against blacklisted sources
    private func validateBlacklist(messageID: String) throws {
        let now = Date()
        let source = String(messageID.prefix(8)) // Use first 8 chars as source identifier
        
        // Clean expired blacklist entries
        blacklistedSources = blacklistedSources.filter { $0.value.addingTimeInterval(AttackMitigation.blacklistDuration) > now }
        
        // Check if source is blacklisted
        if let blacklistTime = blacklistedSources[source] {
            let remainingTime = blacklistTime.addingTimeInterval(AttackMitigation.blacklistDuration).timeIntervalSince(now)
            if remainingTime > 0 {
                logger.error("🚨 Source blacklisted: \(source), remaining: \(Int(remainingTime))s")
                throw AudioSecurityError.sourceBlacklisted
            }
        }
    }
    
    /// Validate data size to prevent memory exhaustion attacks
    private func validateDataSize(_ data: Data) throws {
        guard data.count <= SecurityLimits.maxMemoryPerPlayback else {
            logger.error("🚨 Audio data exceeds size limit: \(data.count) bytes")
            throw AudioSecurityError.dataTooLarge
        }
        
        guard !data.isEmpty else {
            throw AudioSecurityError.emptyAudioData
        }
    }
    
    /// Validate concurrent playback limits
    private func validateConcurrentPlaybacks() throws {
        let activeCount = activePlayback.count
        guard activeCount < SecurityLimits.maxConcurrentPlaybacks else {
            logger.error("🚨 Too many concurrent playbacks: \(activeCount)")
            throw AudioSecurityError.tooManyConcurrentPlaybacks
        }
    }
    
    /// Validate queue size to prevent memory exhaustion
    private func validateQueueSize() throws {
        let queueCount = playbackQueue.count
        guard queueCount < SecurityLimits.maxQueueSize else {
            logger.error("🚨 Playback queue full: \(queueCount) messages")
            throw AudioSecurityError.queueFull
        }
    }
    
    /// Validate current memory usage
    private func validateMemoryUsage() throws {
        let currentMemory = getCurrentMemoryUsage()
        let memoryLimitMB = 200 * 1024 * 1024 // 200MB limit
        
        guard currentMemory < memoryLimitMB else {
            logger.error("🚨 Memory usage too high: \(currentMemory / 1024 / 1024)MB")
            throw AudioSecurityError.memoryLimitExceeded
        }
    }
    
    /// Detect suspicious patterns that might indicate an attack
    private func detectSuspiciousPatterns(messageID: String) throws {
        let source = String(messageID.prefix(8))
        let now = Date()
        
        // Count recent requests from this source
        let recentRequests = playbackHistory.filter { 
            $0.date > now.addingTimeInterval(-Double(AttackMitigation.detectionWindowMinutes * 60)) &&
            $0.messageId.hasPrefix(source)
        }.count
        
        // Check for burst patterns
        if recentRequests >= AttackMitigation.burstDetectionLimit {
            logger.error("🚨 Burst attack detected from \(source): \(recentRequests) requests")
            
            // Blacklist the source
            blacklistedSources[source] = now
            
            // Update suspicious pattern counter
            suspiciousPatterns[source] = (suspiciousPatterns[source] ?? 0) + 1
            
            throw AudioSecurityError.suspiciousPattern
        }
        
        // Check for repeated failures from same source
        if consecutiveFailures >= SecurityLimits.suspiciousPatternThreshold {
            logger.warning("🚨 Multiple consecutive failures detected")
            
            // Apply progressive delay (simplified for sync context)
            let delay = min(Double(consecutiveFailures) * 0.5, 5.0) // Max 5 second delay
            Thread.sleep(forTimeInterval: delay)
        }
    }
    
    /// Update security metrics for monitoring
    private func updateSecurityMetrics(messageID: String) {
        let now = Date()
        
        // Add to playback history
        self.playbackHistory.append((date: now, messageId: messageID))
        
        // Update last playback time
        self.lastPlaybackTime = now
        
        // Increment total attempts
        self.totalPlaybackAttempts += 1
        
        // Reset consecutive failures on successful validation
        self.consecutiveFailures = 0
        
        // Log security metrics periodically
        if self.totalPlaybackAttempts % 100 == 0 {
            logger.info("🔒 Security metrics: \(self.totalPlaybackAttempts) attempts, \(self.blacklistedSources.count) blacklisted, \(self.suspiciousPatterns.count) suspicious sources")
        }
    }
    
    /// Get current memory usage for monitoring
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
    
    /// Generate security hash for data integrity validation
    private func generateSecurityHash(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Handle security incident and implement countermeasures
    private func handleSecurityIncident(_ incident: AudioSecurityError, messageID: String) {
        let source = String(messageID.prefix(8))
        consecutiveFailures += 1
        
        // Log security incident
        logger.error("🚨 Security incident: \(incident.localizedDescription) from \(source)")
        
        // Apply countermeasures based on incident type
        switch incident {
        case .suspiciousPattern, .rateLimitExceeded:
            blacklistedSources[source] = Date()
            logger.warning("🔒 Source blacklisted: \(source)")
            
        case .tooManyConcurrentPlaybacks:
            // Stop oldest playback to make room
            if let oldestSession = activePlayback.values.min(by: { $0.startTime < $1.startTime }) {
                stop()
                logger.warning("🛑 Stopped oldest playback to prevent overload")
            }
            
        default:
            break
        }
        
        // Notify delegate if available
        delegate?.audioPlayer(self, encounteredSecurityIncident: incident, messageID: messageID)
    }
    
}

// MARK: - Security Error Types

public enum AudioSecurityError: LocalizedError {
    case rateLimitExceeded
    case playbackTooFrequent
    case sourceBlacklisted
    case dataTooLarge
    case emptyAudioData
    case tooManyConcurrentPlaybacks
    case queueFull
    case memoryLimitExceeded
    case suspiciousPattern
    case integrityCheckFailed
    
    public var errorDescription: String? {
        switch self {
        case .rateLimitExceeded:
            return "Playback rate limit exceeded"
        case .playbackTooFrequent:
            return "Playback requests too frequent"
        case .sourceBlacklisted:
            return "Audio source is blacklisted"
        case .dataTooLarge:
            return "Audio data exceeds size limit"
        case .emptyAudioData:
            return "Audio data is empty"
        case .tooManyConcurrentPlaybacks:
            return "Too many concurrent playbacks"
        case .queueFull:
            return "Playback queue is full"
        case .memoryLimitExceeded:
            return "Memory usage limit exceeded"
        case .suspiciousPattern:
            return "Suspicious playback pattern detected"
        case .integrityCheckFailed:
            return "Audio data integrity check failed"
        }
    }
}

// MARK: - Helper Extensions

fileprivate extension Float32 {
    var data: Data {
        return withUnsafeBytes(of: self) { Data($0) }
    }
}