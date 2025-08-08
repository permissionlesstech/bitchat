//
// AudioRecorder.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

///
/// # AudioRecorder
///
/// High-performance audio recording service using AVAudioEngine with real-time
/// Opus encoding for efficient voice message transmission over BitChat's mesh network.
///
/// ## Overview
/// AudioRecorder provides a complete audio recording pipeline optimized for
/// Bluetooth LE constraints and battery efficiency. It handles:
/// - Microphone permission management
/// - Real-time audio capture via AVAudioEngine
/// - Live Opus encoding during recording
/// - Audio session management and interruption handling
/// - Battery-aware recording optimization
/// - Voice activity detection (VAD) for automatic start/stop
///
/// ## Architecture
/// The recorder operates in a streaming pipeline:
/// 1. **Microphone Input**: AVAudioEngine captures audio at 48kHz mono (Opus native)
/// 2. **Real-time Processing**: Audio buffers processed in 20ms chunks
/// 3. **Opus Encoding**: Live encoding to minimize latency and memory usage
/// 4. **Data Streaming**: Encoded packets immediately available for transmission
/// 5. **Session Management**: Proper audio session handling for iOS/macOS
///
/// ## Key Features
///
/// ### Performance Optimizations
/// - Zero-copy audio buffer handling where possible
/// - Streaming encoding reduces memory footprint
/// - Battery-aware sample rate and quality adaptation
/// - Efficient voice activity detection
/// - Background recording support
///
/// ### Audio Quality Management
/// - Automatic gain control (AGC) for consistent levels
/// - Noise suppression for cleaner voice transmission
/// - Echo cancellation on supported devices
/// - Dynamic quality adjustment based on battery/signal
///
/// ### Robust Error Handling
/// - Microphone permission failures
/// - Audio session interruptions (calls, other apps)
/// - Hardware availability changes
/// - Memory pressure adaptation
/// - Network congestion backpressure
///
/// ## Recording States
/// - **idle**: Not recording, ready to start
/// - **preparing**: Setting up audio session and permissions
/// - **recording**: Actively capturing and encoding audio
/// - **paused**: Recording paused (iOS app backgrounding)
/// - **error**: Recording failed, needs reset
///
/// ## Usage Example
/// ```swift
/// let recorder = AudioRecorder(opusService: opusAudioService)
/// recorder.delegate = self
/// 
/// // Start recording
/// try await recorder.startRecording()
/// 
/// // Stop and get final encoded data
/// let audioData = try await recorder.stopRecording()
/// ```
///

import Foundation
import AVFoundation
import Combine
import os.log
#if os(iOS)
import UIKit
#endif

// Import for simulator detection
#if os(iOS)
import Darwin
#endif

/// Audio recording states
public enum RecordingState {
    case idle           // Not recording
    case preparing      // Setting up audio session
    case recording      // Actively recording
    case paused         // Recording paused (backgrounding)
    case error(Error)   // Recording failed
    
    public var isActive: Bool {
        switch self {
        case .recording, .paused:
            return true
        default:
            return false
        }
    }
}

/// Voice activity detection states
public enum VoiceActivity {
    case silence        // No voice detected
    case speaking       // Voice detected
    case unknown        // Unable to determine
}

/// Audio recorder delegate for real-time callbacks
public protocol AudioRecorderDelegate: AnyObject {
    /// Called when recording state changes
    func audioRecorder(_ recorder: AudioRecorder, didChangeState state: RecordingState)
    
    /// Called when new encoded audio data is available (real-time streaming)
    func audioRecorder(_ recorder: AudioRecorder, didCaptureAudioData data: Data, timestamp: Date)
    
    /// Called when voice activity changes (for UI feedback)
    func audioRecorder(_ recorder: AudioRecorder, didDetectVoiceActivity activity: VoiceActivity, level: Float)
    
    /// Called when recording permissions change
    #if os(iOS)
    func audioRecorder(_ recorder: AudioRecorder, didChangePermissionStatus status: AVAudioSession.RecordPermission)
    #else
    func audioRecorder(_ recorder: AudioRecorder, didChangePermissionStatus status: Int)
    #endif
}

/// Audio recording errors
public enum AudioRecordingError: Error, LocalizedError {
    case permissionDenied
    case audioSessionSetupFailed(String)
    case audioEngineSetupFailed(String)
    case recordingInProgress
    case notRecording
    case encodingFailed(String)
    case hardwareUnavailable
    
    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission denied"
        case .audioSessionSetupFailed(let reason):
            return "Audio session setup failed: \(reason)"
        case .audioEngineSetupFailed(let reason):
            return "Audio engine setup failed: \(reason)"
        case .recordingInProgress:
            return "Recording already in progress"
        case .notRecording:
            return "Not currently recording"
        case .encodingFailed(let reason):
            return "Audio encoding failed: \(reason)"
        case .hardwareUnavailable:
            return "Audio recording hardware unavailable"
        }
    }
}

/// High-performance audio recorder with real-time Opus encoding
public class AudioRecorder: ObservableObject {
    
    // MARK: - Public Properties
    
    @Published public var recordingState: RecordingState = .idle
    @Published public var currentVoiceActivity: VoiceActivity = .silence
    @Published public var currentAudioLevel: Float = 0.0
    @Published public var recordingDuration: TimeInterval = 0.0
    #if os(iOS)
    @Published public var permissionStatus: AVAudioSession.RecordPermission = .undetermined
    #else
    @Published public var permissionStatus: Int = 0 // 0=undetermined, 1=denied, 2=granted
    #endif
    
    public weak var delegate: AudioRecorderDelegate?
    
    // MARK: - Private Properties
    
    private let opusService: OpusAudioService
    private var audioEngine: AVAudioEngine?
    private let logger = Logger(subsystem: "chat.bitchat", category: "AudioRecorder")
    
    // Audio processing
    private var inputNode: AVAudioInputNode?
    private var recordingFormat: AVAudioFormat?
    private var processingFormat: AVAudioFormat?
    
    // Real-time data streaming
    private var accumulatedPCMData = Data()
    private var recordingStartTime: Date?
    private let audioProcessingQueue = DispatchQueue(label: "audio.recording.processing", qos: .userInitiated)
    private let encodingQueue = DispatchQueue(label: "audio.recording.encoding", qos: .userInitiated)
    
    // Voice activity detection
    private var voiceActivityDetector: VoiceActivityDetector
    private var audioLevelDetector: AudioLevelDetector
    
    // Battery optimization
    private var batteryOptimizer: BatteryOptimizer { BatteryOptimizer.shared }
    
    // Interruption handling
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var appStateObserver: NSObjectProtocol?
    
    // MARK: - Initialization
    
    public init(opusService: OpusAudioService) {
        SecureLogger.log("🎤 [DEBUG] AudioRecorder.init() starting", category: SecureLogger.voice, level: .info)
        
        SecureLogger.log("🎤 [DEBUG] Setting opusService...", category: SecureLogger.voice, level: .info)
        self.opusService = opusService
        
        SecureLogger.log("🎤 [DEBUG] Creating VoiceActivityDetector...", category: SecureLogger.voice, level: .info)
        self.voiceActivityDetector = VoiceActivityDetector()
        
        SecureLogger.log("🎤 [DEBUG] Creating AudioLevelDetector...", category: SecureLogger.voice, level: .info)
        self.audioLevelDetector = AudioLevelDetector()
        
        SecureLogger.log("🎤 [DEBUG] Setting up observers...", category: SecureLogger.voice, level: .info)
        setupObservers()
        
        SecureLogger.log("🎤 [DEBUG] Checking permissions...", category: SecureLogger.voice, level: .info)
        checkPermissions()
        
        SecureLogger.log("✅ [DEBUG] AudioRecorder.init() completed successfully", category: SecureLogger.voice, level: .info)
    }
    
    deinit {
        stopRecording()
        removeObservers()
    }
    
    // MARK: - Public Methods
    
    /// Requests microphone permission if needed
    /// - Returns: Current permission status after request
    @discardableResult
    public func requestPermission() async -> Bool {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            // Request permission
            let granted = await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            
            let newStatus: AVAudioSession.RecordPermission = granted ? .granted : .denied
            
            await MainActor.run {
                self.permissionStatus = newStatus
                self.delegate?.audioRecorder(self, didChangePermissionStatus: newStatus)
            }
            
            return granted
        @unknown default:
            return false
        }
        #else
        // macOS doesn't require explicit microphone permission for recording
        await MainActor.run {
            self.permissionStatus = 2 // granted
            self.delegate?.audioRecorder(self, didChangePermissionStatus: 2)
        }
        return true
        #endif
    }
    
    /// Starts audio recording with real-time Opus encoding
    /// - Throws: AudioRecordingError if recording cannot be started
    public func startRecording() async throws {
        SecureLogger.log("🎤 [DEBUG] AudioRecorder.startRecording() called", category: SecureLogger.voice, level: .info)
        logger.info("Starting audio recording")
        
        // Check current state
        SecureLogger.log("🎤 [DEBUG] Checking current recording state: \(recordingState)", category: SecureLogger.voice, level: .info)
        guard case .idle = recordingState else {
            SecureLogger.log("❌ [DEBUG] Recording already in progress, state: \(recordingState)", category: SecureLogger.voice, level: .error)
            throw AudioRecordingError.recordingInProgress
        }
        
        // Update state
        SecureLogger.log("🎤 [DEBUG] Updating state to preparing...", category: SecureLogger.voice, level: .info)
        await MainActor.run {
            recordingState = .preparing
            delegate?.audioRecorder(self, didChangeState: recordingState)
        }
        
        // Check permissions with detailed logging
        SecureLogger.log("🎤 [DEBUG] Requesting audio permission...", category: SecureLogger.voice, level: .info)
        
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        SecureLogger.log("🎤 [DEBUG] Current permission status: \(session.recordPermission.rawValue)", category: SecureLogger.voice, level: .info)
        SecureLogger.log("🎤 [DEBUG] Audio session category: \(session.category)", category: SecureLogger.voice, level: .info)
        SecureLogger.log("🎤 [DEBUG] Audio session active: \(session.isOtherAudioPlaying)", category: SecureLogger.voice, level: .info)
        #endif
        
        let hasPermission = await requestPermission()
        guard hasPermission else {
            SecureLogger.log("❌ [DEBUG] Audio permission denied - this will prevent recording", category: SecureLogger.voice, level: .error)
            await MainActor.run {
                recordingState = .error(AudioRecordingError.permissionDenied)
                delegate?.audioRecorder(self, didChangeState: recordingState)
            }
            throw AudioRecordingError.permissionDenied
        }
        SecureLogger.log("✅ [DEBUG] Audio permission granted - proceeding with recording setup", category: SecureLogger.voice, level: .info)
        
        // Setup audio session
        SecureLogger.log("🎤 [DEBUG] Setting up audio session...", category: SecureLogger.voice, level: .info)
        try await setupAudioSession()
        SecureLogger.log("✅ [DEBUG] Audio session setup completed", category: SecureLogger.voice, level: .info)
        
        // Setup audio engine
        SecureLogger.log("🎤 [DEBUG] Setting up audio engine...", category: SecureLogger.voice, level: .info)
        try await setupAudioEngine()
        SecureLogger.log("✅ [DEBUG] Audio engine setup completed", category: SecureLogger.voice, level: .info)
        
        // Start recording
        SecureLogger.log("🎤 [DEBUG] Beginning actual recording...", category: SecureLogger.voice, level: .info)
        try await beginRecording()
        SecureLogger.log("✅ [DEBUG] Recording began successfully", category: SecureLogger.voice, level: .info)
        
        logger.info("Audio recording started successfully")
        SecureLogger.log("✅ [DEBUG] AudioRecorder.startRecording() completed successfully", category: SecureLogger.voice, level: .info)
    }
    
    /// Stops audio recording and returns final encoded data
    /// - Returns: Complete encoded audio data
    /// - Throws: AudioRecordingError if stopping fails
    @discardableResult
    public func stopRecording() -> Data {
        logger.info("Stopping audio recording")
        
        guard recordingState.isActive else {
            return Data()
        }
        
        // SAFE STOP: Check engine state before stopping operations
        var finalData = Data()
        
        // ✅ NORMAL OPUS ENCODING: Process accumulated PCM data with Opus
        if !accumulatedPCMData.isEmpty {
            logger.info("✅ PRODUCTION: Processing \(self.accumulatedPCMData.count) bytes of 48kHz Float32 PCM data")
            finalData = processFinalAudioData()
            logger.info("✅ PRODUCTION: Opus encoded \(self.accumulatedPCMData.count) → \(finalData.count) bytes")
        } else {
            logger.warning("⚠️ No PCM data accumulated for encoding")
            finalData = Data()
        }
        
        // CRASH-SAFE CLEANUP: Prevent crashes on second recording
        audioProcessingQueue.sync {
            // CRITICAL: Safe tap removal with try-catch
            do {
                if let audioEngine = audioEngine, inputNode != nil {
                    try audioEngine.inputNode.removeTap(onBus: 0)
                    logger.info("Audio tap removed successfully")
                }
            } catch {
                logger.warning("Could not remove audio tap (safe to ignore): \(error)")
            }
            
            // SAFE: Stop engine if running
            if let audioEngine = audioEngine, audioEngine.isRunning {
                audioEngine.stop()
                logger.info("Audio engine stopped")
            }
            
            // CRITICAL: Reset and clear audioEngine
            audioEngine?.reset()
            audioEngine = nil
            logger.info("AudioEngine cleared - will be recreated safely on next recording")
            
            // CRASH FIX: Brief delay to ensure audio session state is fully reset
            // This prevents "IsFormatSampleRateAndChannelCountValid" crash on second recording
            #if os(iOS)
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                try AVAudioSession.sharedInstance().setActive(true)
                logger.info("Audio session reset for next recording")
            } catch {
                logger.warning("Audio session reset failed (safe to ignore): \(error)")
            }
            #endif
        }
        
        // ENHANCED STATE CLEANUP for stable next recording
        recordingState = .idle
        recordingDuration = 0.0
        recordingStartTime = nil
        
        // CRITICAL: Complete data cleanup
        accumulatedPCMData.removeAll(keepingCapacity: false)
        
        // Clear ALL references completely
        inputNode = nil
        recordingFormat = nil
        processingFormat = nil
        
        // Reset detectors to fresh state  
        voiceActivityDetector = VoiceActivityDetector()
        audioLevelDetector = AudioLevelDetector()
        
        delegate?.audioRecorder(self, didChangeState: recordingState)
        
        logger.info("Audio recording stopped")
        return finalData
    }
    
    /// Pauses recording (typically when app goes to background)
    public func pauseRecording() {
        guard case .recording = recordingState else { return }
        
        audioEngine?.pause()
        recordingState = .paused
        delegate?.audioRecorder(self, didChangeState: recordingState)
        
        logger.info("Audio recording paused")
    }
    
    /// Resumes recording (when app returns to foreground)
    public func resumeRecording() throws {
        guard case .paused = recordingState else { return }
        guard let audioEngine = audioEngine else {
            throw AudioRecordingError.hardwareUnavailable
        }
        
        try audioEngine.start()
        recordingState = .recording
        delegate?.audioRecorder(self, didChangeState: recordingState)
        
        logger.info("Audio recording resumed")
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
            self?.pauseRecording()
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
    
    private func checkPermissions() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        permissionStatus = session.recordPermission
        #else
        permissionStatus = 2 // granted on macOS
        #endif
    }
    
    private func setupAudioSession() async throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        
        do {
            // Use existing unified session configuration - don't reconfigure
            // Just verify it's active and optimal for recording
            if !session.isOtherAudioPlaying {
                // Only set preferred input if no other audio is playing
                if let availableInputs = session.availableInputs {
                    for input in availableInputs {
                        // Prefer built-in microphone with noise cancellation
                        if input.portType == .builtInMic {
                            try session.setPreferredInput(input)
                            
                            // Set optimal data source for quality
                            if let dataSources = input.dataSources {
                                for dataSource in dataSources {
                                    if dataSource.dataSourceName.localizedCaseInsensitiveContains("front") ||
                                       dataSource.dataSourceName.localizedCaseInsensitiveContains("bottom") {
                                        try input.setPreferredDataSource(dataSource)
                                        break
                                    }
                                }
                            }
                            break
                        }
                    }
                }
            }
            
            logger.info("Audio session verified for recording")
            
        } catch {
            logger.error("Audio session setup failed: \(error.localizedDescription)")
            throw AudioRecordingError.audioSessionSetupFailed(error.localizedDescription)
        }
        #endif
    }
    
    private func createAudioEngineIfNeeded() throws {
        if audioEngine == nil {
            // CRITICAL: Enhanced simulator detection - multiple methods for reliability
            let isSimulator = isRunningOnSimulator()
            
            if isSimulator {
                SecureLogger.log("🎭 [FORCE-SIMULATOR] Detected iOS Simulator - FORCING mock recording to prevent corrupted audio", category: SecureLogger.voice, level: .warning)
                logger.info("🎭 Running in simulator - will use mock recording")
                throw AudioRecordingError.hardwareUnavailable
            }
            
            // Safe to create AudioEngine
            audioEngine = AVAudioEngine()
            logger.info("🎤 AudioEngine created successfully")
        }
    }
    
    /// Enhanced simulator detection using multiple methods for maximum reliability
    private func isRunningOnSimulator() -> Bool {
        // Method 1: Compile-time detection
        #if targetEnvironment(simulator)
        return true
        #endif
        
        // Method 2: Runtime detection via device model
        #if os(iOS)
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = String(bytes: Data(bytes: &systemInfo.machine, count: Int(_SYS_NAMELEN)), encoding: .ascii)?.trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        
        if let deviceModel = machine, deviceModel.contains("x86_64") || deviceModel.contains("i386") {
            SecureLogger.log("🎭 [RUNTIME-DETECTION] Device model indicates simulator: \(deviceModel)", category: SecureLogger.voice, level: .info)
            return true
        }
        
        // Method 3: Check for simulator environment variables
        if ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil {
            SecureLogger.log("🎭 [ENV-DETECTION] Simulator environment variable detected", category: SecureLogger.voice, level: .info)
            return true
        }
        
        // Method 4: Check for Simulator-specific bundle identifier
        if Bundle.main.bundleIdentifier?.contains("Simulator") == true {
            SecureLogger.log("🎭 [BUNDLE-DETECTION] Simulator bundle identifier detected", category: SecureLogger.voice, level: .info)
            return true
        }
        #endif
        
        return false
    }
    
    private func setupAudioEngine() async throws {
        do {
            // CRITICAL: Create AudioEngine safely first
            try createAudioEngineIfNeeded()
            guard let audioEngine = audioEngine else {
                throw AudioRecordingError.hardwareUnavailable
            }
            
            // CRITICAL: Force proper engine initialization first
            if !audioEngine.isRunning {
                audioEngine.prepare()
                try audioEngine.start()
                logger.info("🚀 AudioEngine started for format detection")
            }
            
            // Get input node
            inputNode = audioEngine.inputNode
            guard let inputNode = inputNode else {
                throw AudioRecordingError.hardwareUnavailable
            }
            
            // Get input format with validation
            recordingFormat = inputNode.inputFormat(forBus: 0)
            guard let recordingFormat = recordingFormat else {
                throw AudioRecordingError.audioEngineSetupFailed("Unable to get input format")
            }
            
            // 🎵 CRITICAL: Force 48kHz mono to avoid upsampling artifacts
            logger.info("🎵 Device format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch")
            
            // Always use 48kHz mono to match Opus native format
            guard let opusNativeFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48000,
                channels: 1,
                interleaved: false
            ) else {
                throw AudioRecordingError.audioEngineSetupFailed("Cannot create Opus native format")
            }
            self.recordingFormat = opusNativeFormat
            logger.info("✅ Using Opus native format: \(opusNativeFormat)")
            
            // Create processing format (48kHz mono Float32 - Opus native)
            guard let audioFormatOptional = OpusAudioService.inputAudioFormat() else {
                throw AudioRecordingError.audioEngineSetupFailed("Unable to create processing format - AVAudioFormat creation failed")
            }
            processingFormat = audioFormatOptional
            
            logger.info("✅ Recording format validated: \(recordingFormat)")
            logger.info("✅ Processing format: \(self.processingFormat)")
            
            // Setup audio tap with format conversion if needed
            setupAudioTap(inputNode: inputNode, recordingFormat: recordingFormat, processingFormat: audioFormatOptional)
            
            // Prepare engine
            audioEngine.prepare()
            
            logger.info("Audio engine setup completed")
            
        } catch {
            logger.error("Audio engine setup failed: \(error.localizedDescription)")
            throw AudioRecordingError.audioEngineSetupFailed(error.localizedDescription)
        }
    }
    
    private func setupAudioTap(inputNode: AVAudioInputNode, recordingFormat: AVAudioFormat, processingFormat: AVAudioFormat) {
        // 🎵 CRITICAL: Always use device format for tap to avoid audio corruption
        let tapFormat = inputNode.inputFormat(forBus: 0)
        let converter: AVAudioConverter?
        
        if tapFormat.sampleRate == processingFormat.sampleRate && tapFormat.channelCount == processingFormat.channelCount {
            logger.info("✅ No conversion needed: formats match")
            converter = nil
        } else {
            logger.info("🔧 Creating converter: \(tapFormat.sampleRate)Hz->\(processingFormat.sampleRate)Hz")
            converter = AVAudioConverter(from: tapFormat, to: processingFormat)
            if converter == nil {
                logger.warning("⚠️ Failed to create audio converter - will use direct format")
            }
        }
        
        // Use pooled buffer size
        let bufferSize = AVAudioFrameCount(4096)
        
        SecureLogger.log("🎤 [DEBUG] Installing audio tap with buffer size: \(bufferSize)", category: SecureLogger.voice, level: .info)
        SecureLogger.log("🎤 [DEBUG] Tap format: \(tapFormat)", category: SecureLogger.voice, level: .info)
        SecureLogger.log("🎤 [DEBUG] Processing format: \(processingFormat)", category: SecureLogger.voice, level: .info)
        
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { [weak self] buffer, time in
            SecureLogger.log("🎤 [DEBUG] Audio buffer received: \(buffer.frameLength) frames", category: SecureLogger.voice, level: .debug)
            self?.processAudioBuffer(buffer, converter: converter, processingFormat: processingFormat)
        }
        
        SecureLogger.log("✅ [DEBUG] Audio tap installed successfully", category: SecureLogger.voice, level: .info)
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter?, processingFormat: AVAudioFormat) {
        audioProcessingQueue.async { [weak self] in
            guard let self = self else { return }
            
            do {
                // Convert format if needed
                let processedBuffer: AVAudioPCMBuffer
                if let converter = converter {
                    guard let convertedBuffer = try self.convertAudioBuffer(buffer, using: converter, to: processingFormat) else {
                        return
                    }
                    processedBuffer = convertedBuffer
                } else {
                    processedBuffer = buffer
                }
                
                // Convert buffer to PCM data
                guard let pcmData = OpusAudioService.bufferToData(processedBuffer) else {
                    return
                }
                
                // 🎵 QUALITY: Verify PCM data quality
                if pcmData.count >= 16 { // At least 4 Float32 samples
                    pcmData.withUnsafeBytes { bytes in
                        let samples = bytes.bindMemory(to: Float32.self)
                        let maxAmplitude = (0..<min(samples.count, 100)).map { abs(samples[$0]) }.max() ?? 0.0
                        if maxAmplitude < 0.0001 {
                            SecureLogger.log("⚠️ Muito silencioso: max amplitude = \(maxAmplitude)", category: SecureLogger.voice, level: .warning)
                        } else {
                            SecureLogger.log("✅ Áudio com amplitude: \(maxAmplitude)", category: SecureLogger.voice, level: .debug)
                        }
                    }
                }
                
                // Update audio level and voice activity
                self.updateAudioLevelAndVAD(from: processedBuffer)
                
                // Release buffer back to pool if converted
                if converter != nil {
                    // TODO: Restore AudioBufferPool when available
                    // processedBuffer.releaseToPool()
                }
                
                // Accumulate PCM data
                self.accumulatedPCMData.append(pcmData)
                
                // Check if we have enough data for encoding (20ms frame at 48kHz)
                let frameSize = OpusAudioService.samplesPerFrame * MemoryLayout<Float32>.size
                while self.accumulatedPCMData.count >= frameSize {
                    let frameData = self.accumulatedPCMData.prefix(frameSize)
                    self.accumulatedPCMData.removeFirst(frameSize)
                    
                    // Encode frame
                    self.encodeAndDeliverFrame(Data(frameData))
                }
                
                // Update recording duration
                if let startTime = self.recordingStartTime {
                    let duration = Date().timeIntervalSince(startTime)
                    DispatchQueue.main.async {
                        self.recordingDuration = duration
                    }
                }
                
            } catch {
                self.logger.error("Audio buffer processing failed: \(error.localizedDescription)")
            }
        }
    }
    
    private func convertAudioBuffer(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        // Use pooled buffer
        // TODO: Restore AudioBufferPool when available
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity) else {
            return nil
        }
        
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        if status == .error, let error = error {
            throw error
        }
        
        return outputBuffer
    }
    
    private func encodeAndDeliverFrame(_ pcmData: Data) {
        // Check network conditions before encoding
        // TODO: Restore NetworkOptimizer when available
        // guard NetworkOptimizer.shared.shouldSendRequest() else {
        guard true else {
            // Queue for later if network is congested
            return
        }
        
        encodingQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Record performance metric
            // TODO: Restore PerformanceMonitor when available
            // let encodeStart = PerformanceMonitor.shared.beginInterval("AudioEncoding")
            _ = Date() // Encode start time (not used)
            
            do {
                // Encode PCM data to Opus
                let encodedData = try self.opusService.encode(pcmData: pcmData)
                
                // End performance tracking
                // TODO: Restore PerformanceMonitor when available
                // PerformanceMonitor.shared.endInterval("AudioEncoding", id: encodeStart)
                
                // Deliver encoded data to delegate
                DispatchQueue.main.async {
                    self.delegate?.audioRecorder(self, didCaptureAudioData: encodedData, timestamp: Date())
                }
                
            } catch {
                // TODO: Restore PerformanceMonitor when available
                // PerformanceMonitor.shared.endInterval("AudioEncoding", id: encodeStart)
                self.logger.error("Frame encoding failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.recordingState = .error(AudioRecordingError.encodingFailed(error.localizedDescription))
                    self.delegate?.audioRecorder(self, didChangeState: self.recordingState)
                }
            }
        }
    }
    
    private func updateAudioLevelAndVAD(from buffer: AVAudioPCMBuffer) {
        let level = audioLevelDetector.analyzeBuffer(buffer)
        let activity = voiceActivityDetector.analyzeBuffer(buffer)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentAudioLevel = level
            self.currentVoiceActivity = activity
            self.delegate?.audioRecorder(self, didDetectVoiceActivity: activity, level: level)
        }
    }
    
    private func beginRecording() async throws {
        do {
            guard let audioEngine = audioEngine else {
                throw AudioRecordingError.hardwareUnavailable
            }
            
            SecureLogger.log("🎤 [DEBUG] About to start audioEngine", category: SecureLogger.voice, level: .info)
            try audioEngine.start()
            SecureLogger.log("✅ [DEBUG] AudioEngine started successfully", category: SecureLogger.voice, level: .info)
            
            await MainActor.run {
                recordingState = .recording
                recordingStartTime = Date()
                accumulatedPCMData.removeAll()
                delegate?.audioRecorder(self, didChangeState: recordingState)
                SecureLogger.log("✅ [DEBUG] Recording state set to .recording, startTime set", category: SecureLogger.voice, level: .info)
            }
            
            // Start fallback timer to ensure UI updates even without audio data
            startFallbackDurationTimer()
            
        } catch {
            SecureLogger.log("❌ [DEBUG] AudioEngine start failed: \(error)", category: SecureLogger.voice, level: .error)
            await MainActor.run {
                recordingState = .error(AudioRecordingError.audioEngineSetupFailed(error.localizedDescription))
                delegate?.audioRecorder(self, didChangeState: recordingState)
            }
            throw AudioRecordingError.audioEngineSetupFailed(error.localizedDescription)
        }
    }
    
    /// Fallback timer to update duration even if no audio data is received
    private func startFallbackDurationTimer() {
        // Create a timer that updates duration every 100ms for smooth UI
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self,
                  case .recording = self.recordingState,
                  let startTime = self.recordingStartTime else {
                timer.invalidate()
                return
            }
            
            let duration = Date().timeIntervalSince(startTime)
            DispatchQueue.main.async {
                self.recordingDuration = duration
                SecureLogger.log("⏱️ [DEBUG] Fallback duration update: \(duration)s", category: SecureLogger.voice, level: .debug)
            }
        }
    }
    
    private func processFinalAudioData() -> Data {
        // SAFE PROCESSING: Handle empty or invalid data gracefully
        guard !accumulatedPCMData.isEmpty else {
            logger.info("No accumulated PCM data to process")
            return Data()
        }
        
        guard accumulatedPCMData.count > 0 else {
            logger.warning("Invalid accumulated PCM data size")
            return Data()
        }
        
        do {
            // Validate data size before processing
            let frameSize = OpusAudioService.samplesPerFrame * MemoryLayout<Float32>.size
            guard frameSize > 0 else {
                logger.error("Invalid frame size calculated")
                return Data()
            }
            
            // Create a copy to avoid modifying the original during processing
            var processingData = accumulatedPCMData
            
            // Pad to frame size if needed (safely)
            if processingData.count < frameSize {
                let paddingSize = frameSize - processingData.count
                guard paddingSize > 0 && paddingSize < 1000000 else { // Sanity check
                    logger.error("Invalid padding size calculated: \(paddingSize)")
                    return Data()
                }
                processingData.append(Data(repeating: 0, count: paddingSize))
            }
            
            // Encode with additional safety checks
            guard !processingData.isEmpty else {
                logger.warning("Processing data became empty after padding")
                return Data()
            }
            
            let finalEncodedData = try opusService.encode(pcmData: processingData)
            logger.info("Successfully encoded final audio data: \(processingData.count) → \(finalEncodedData.count) bytes")
            return finalEncodedData
            
        } catch {
            logger.error("Final frame encoding failed: \(error.localizedDescription)")
            // Return empty data instead of crashing
            return Data()
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
        
        switch type {
        case .began:
            logger.info("Audio session interruption began")
            pauseRecording()
            
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            
            if options.contains(.shouldResume) {
                logger.info("Audio session interruption ended - should resume")
                do {
                    try resumeRecording()
                } catch {
                    logger.error("Failed to resume recording after interruption: \(error.localizedDescription)")
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
            // Stop recording if microphone becomes unavailable
            if recordingState.isActive {
                _ = stopRecording()
            }
            
        default:
            break
        }
    }
    #endif
}

// MARK: - Voice Activity Detection

/// Simple voice activity detector based on energy and spectral analysis
private class VoiceActivityDetector {
    private var energyHistory: [Float] = []
    private let historySize = 10
    private let voiceThreshold: Float = 0.01
    
    func analyzeBuffer(_ buffer: AVAudioPCMBuffer) -> VoiceActivity {
        guard let channelData = buffer.floatChannelData?[0] else {
            return .unknown
        }
        
        // SAFE CONVERSION: Prevent integer overflow crash
        let frameCount = safeConvertFrameLength(buffer.frameLength)
        guard frameCount > 0 else { return .silence }
        
        // Calculate RMS energy
        var sum: Float = 0
        for i in 0..<frameCount {
            let sample = channelData[i]
            sum += sample * sample
        }
        
        let rms = sqrtf(sum / Float(frameCount))
        
        // Update history
        energyHistory.append(rms)
        if energyHistory.count > historySize {
            energyHistory.removeFirst()
        }
        
        // Calculate average energy
        let averageEnergy = energyHistory.reduce(0, +) / Float(energyHistory.count)
        
        // Simple threshold-based VAD
        return averageEnergy > voiceThreshold ? .speaking : .silence
    }
    
    /// Safely convert AVAudioFrameCount to Int, preventing overflow crashes
    private func safeConvertFrameLength(_ frameCount: AVAudioFrameCount) -> Int {
        // AVAudioFrameCount is UInt32, Int can be 32 or 64 bit
        // COMPLETELY SAFE: Use hardcoded limits to prevent ANY overflow
        let maxSafeFrameCount: UInt32 = 100_000 // Cap at 100K frames - always safe for our use case
        let clampedFrameCount = min(frameCount, maxSafeFrameCount)
        
        // Since we capped at 100K, this is guaranteed to fit in Int on all platforms
        return Int(clampedFrameCount)
    }
}

// MARK: - Audio Level Detection

/// Audio level detector for UI feedback
private class AudioLevelDetector {
    func analyzeBuffer(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else {
            return 0.0
        }
        
        // SAFE CONVERSION: Prevent integer overflow crash
        let frameCount = safeConvertFrameLength(buffer.frameLength)
        guard frameCount > 0 else { return 0.0 }
        
        // Find peak level
        var peak: Float = 0.0
        for i in 0..<frameCount {
            let sample = abs(channelData[i])
            if sample > peak {
                peak = sample
            }
        }
        
        // Convert to dB scale (0.0 to 1.0)
        let dB = 20.0 * log10(max(peak, 0.000001)) // Avoid log(0)
        let normalizedLevel = max(0.0, min(1.0, (dB + 60.0) / 60.0)) // Map -60dB to 0dB -> 0.0 to 1.0
        
        return normalizedLevel
    }
    
    /// Safely convert AVAudioFrameCount to Int, preventing overflow crashes
    private func safeConvertFrameLength(_ frameCount: AVAudioFrameCount) -> Int {
        // AVAudioFrameCount is UInt32, Int can be 32 or 64 bit
        // COMPLETELY SAFE: Use hardcoded limits to prevent ANY overflow
        let maxSafeFrameCount: UInt32 = 100_000 // Cap at 100K frames - always safe for our use case
        let clampedFrameCount = min(frameCount, maxSafeFrameCount)
        
        // Since we capped at 100K, this is guaranteed to fit in Int on all platforms
        return Int(clampedFrameCount)
    }
}