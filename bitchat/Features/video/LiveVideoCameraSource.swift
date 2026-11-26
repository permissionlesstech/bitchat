//
// LiveVideoCameraSource.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import AVFoundation
import BitLogger
import CoreMedia
import CoreVideo
import Foundation

/// Camera (+ optional microphone) capture for a live video sender.
///
/// Video: an `AVCaptureSession` delivering upright (portrait on iOS) pixel
/// buffers at up to 30 fps; the encoder crops/scales them, so any preset
/// works. `session` is exposed so a preview layer can attach to it.
/// Audio: an `AVAudioEngine` tap resampled and encoded with the live-voice
/// pieces (`PTTInputResampler` + `PTTFrameEncoder`), holding a capture token
/// from `AudioSessionCoordinator` exactly like `PTTCaptureEngine`. Losing the
/// audio session (call, Siri, route loss) stops audio only; video continues.
///
/// `@unchecked Sendable`: capture configuration is confined to
/// `sessionQueue`, frame state to `videoQueue`, encoder state to
/// `audioQueue`, engine/lifecycle state to the main actor; the clock and mute
/// flag are lock-protected.
final class LiveVideoCameraSource: NSObject, LiveVideoFrameSource, @unchecked Sendable {
    enum CameraError: Error {
        case permissionDenied
        case cameraUnavailable
        case configurationFailed
        case microphoneUnavailable
    }

    enum Position {
        case front
        case back
    }

    private static let maxFps: Int32 = 30

    /// Attach an `AVCaptureVideoPreviewLayer` to this session for the
    /// sender's own preview.
    let session = AVCaptureSession()
    let audioEnabled: Bool

    var onPixelBuffer: ((CVPixelBuffer, Int64) -> Void)?
    var onAudioFrames: (([Data], Int64) -> Void)?

    var isMuted: Bool {
        get { stateLock.withLock { muted } }
        set { stateLock.withLock { muted = newValue } }
    }

    /// Camera currently in use (or about to be, before `start()`).
    var position: Position {
        stateLock.withLock { currentPosition }
    }

    private let sessionQueue = DispatchQueue(label: "chat.bitchat.video.camera.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "chat.bitchat.video.camera.frames", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "chat.bitchat.video.camera.audio", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let coordinator: AudioSessionCoordinator
    private let sessionLease: PTTCaptureSessionLease
    private let captureGeneration = PTTCaptureGeneration()

    // Lock-protected.
    private let stateLock = NSLock()
    private var muted = false
    private var currentPosition: Position
    /// Host-clock seconds at `start()`; timestamps are relative to it.
    private var clockOriginSeconds: Double = 0

    // sessionQueue-confined.
    private var videoInput: AVCaptureDeviceInput?
    private var outputAdded = false

    // videoQueue-confined.
    private var lastFramePtsUs: Int64 = .min

    // audioQueue-confined.
    private var resampler: PTTInputResampler?
    private var encoder: PTTFrameEncoder?
    private var firstAudioPtsUs: Int64?
    private var aacFramesEmitted: Int64 = 0

    // Main-actor-confined.
    @MainActor private var engine: AVAudioEngine?
    @MainActor private var engineStarted = false
    @MainActor private var configChangeObserver: NSObjectProtocol?

    init(position: Position = .front, audioEnabled: Bool = true, coordinator: AudioSessionCoordinator = .shared) {
        self.currentPosition = position
        self.audioEnabled = audioEnabled
        self.coordinator = coordinator
        self.sessionLease = PTTCaptureSessionLease(coordinator: coordinator)
        super.init()
    }

    deinit {
        sessionLease.release()
    }

    // MARK: - Permissions

    static func requestCameraAccess() async -> Bool {
        await requestAccess(for: .video)
    }

    static func requestMicrophoneAccess() async -> Bool {
        await requestAccess(for: .audio)
    }

    private static func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: mediaType)
        default:
            return false
        }
    }

    // MARK: - Lifecycle

    /// Starts the camera, then (if enabled and permitted) the microphone.
    /// Throws when the camera cannot run; a microphone failure only logs, and
    /// the stream continues without audio.
    @MainActor
    func start() async throws {
        guard await Self.requestCameraAccess() else { throw CameraError.permissionDenied }
        stateLock.withLock { clockOriginSeconds = Self.hostSeconds() }
        videoQueue.sync { lastFramePtsUs = .min }
        let position = self.position
        try await onSessionQueue { try self.configureAndRun(position: position) }

        guard audioEnabled else { return }
        guard await Self.requestMicrophoneAccess() else {
            SecureLogger.info("Live video: microphone permission denied; streaming without audio", category: .session)
            return
        }
        do {
            try await startAudio()
        } catch {
            SecureLogger.error("Live video: microphone unavailable, streaming without audio: \(error)", category: .session)
        }
    }

    @MainActor
    func stop() {
        stopAudio()
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Switches between the front and back camera while running (or picks
    /// the camera the next `start()` uses).
    func setPosition(_ position: Position) async throws {
        stateLock.withLock { currentPosition = position }
        try await onSessionQueue {
            guard self.outputAdded else { return }
            self.session.beginConfiguration()
            do {
                try self.installInput(position: position)
                self.configureConnection()
            } catch {
                self.session.commitConfiguration()
                throw error
            }
            self.session.commitConfiguration()
            // Frame rate settings belong to the device: reapply on the new one.
            self.capFrameRate()
        }
    }

    func switchCamera() async throws {
        try await setPosition(position == .front ? .back : .front)
    }

    // MARK: - Session queue

    private func onSessionQueue(_ body: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try body()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configureAndRun(position: Position) throws {
        session.beginConfiguration()
        do {
            // 640×480 covers the largest preset (480×640 portrait) without
            // paying for full-resolution capture.
            if session.canSetSessionPreset(.vga640x480) {
                session.sessionPreset = .vga640x480
            } else if session.canSetSessionPreset(.medium) {
                session.sessionPreset = .medium
            }
            try installInput(position: position)
            if !outputAdded {
                let nv12 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                if videoOutput.availableVideoPixelFormatTypes.contains(nv12) {
                    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: nv12]
                }
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
                guard session.canAddOutput(videoOutput) else { throw CameraError.configurationFailed }
                session.addOutput(videoOutput)
                outputAdded = true
            }
            configureConnection()
        } catch {
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()
        capFrameRate()
        if !session.isRunning { session.startRunning() }
        guard session.isRunning else { throw CameraError.configurationFailed }
        SecureLogger.info("Live video: camera running", category: .session)
    }

    private func installInput(position: Position) throws {
        guard let device = Self.device(for: position) else { throw CameraError.cameraUnavailable }
        if let videoInput, videoInput.device.uniqueID == device.uniqueID { return }
        let input = try AVCaptureDeviceInput(device: device)
        if let videoInput { session.removeInput(videoInput) }
        guard session.canAddInput(input) else {
            if let videoInput, session.canAddInput(videoInput) { session.addInput(videoInput) }
            throw CameraError.configurationFailed
        }
        session.addInput(input)
        videoInput = input
    }

    /// Portrait, upright frames on iOS (the encoder's targets are 3:4
    /// portrait). macOS cameras stay landscape; the encoder center-crops.
    private func configureConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        #if os(iOS)
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        #endif
        // Viewers see the scene as it is (readable text); only the local
        // preview layer mirrors the front camera.
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    private func capFrameRate() {
        guard let device = videoInput?.device else { return }
        let target = CMTime(value: 1, timescale: Self.maxFps)
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameDuration <= target && target <= $0.maxFrameDuration
        }
        guard supported else { return }
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = target
            device.unlockForConfiguration()
        } catch {
            SecureLogger.debug("Live video: could not cap camera frame rate: \(error)", category: .session)
        }
    }

    private static func device(for position: Position) -> AVCaptureDevice? {
        let wanted: AVCaptureDevice.Position = position == .front ? .front : .back
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: wanted)
            ?? AVCaptureDevice.default(for: .video)
    }

    private static func hostSeconds() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    private func relativeUs(hostSeconds: Double) -> Int64 {
        let origin = stateLock.withLock { clockOriginSeconds }
        return Int64((hostSeconds - origin) * 1_000_000)
    }

    // MARK: - Audio (main actor lifecycle, audioQueue processing)

    @MainActor
    private func startAudio() async throws {
        let generation = captureGeneration.begin()
        let token = try await coordinator.acquire(.capture) { [weak self] in
            self?.handleAudioInterruption(for: generation)
        }
        // stop() ran while the session was activating: starting the engine
        // now would leave a hot mic after release.
        guard captureGeneration.isCurrent(generation) else {
            coordinator.release(token)
            throw CancellationError()
        }
        sessionLease.install(token)
        do {
            try beginAudioCapture(generation: generation)
        } catch {
            sessionLease.release()
            throw error
        }
    }

    @MainActor
    private func beginAudioCapture(generation: UInt) throws {
        // Fresh engine per capture so its input unit binds to the session
        // that is active now (see PTTCaptureEngine.engine).
        let engine = AVAudioEngine()
        self.engine = engine
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let resampler = PTTInputResampler(inputFormat: inputFormat),
              let encoder = PTTFrameEncoder()
        else { throw CameraError.microphoneUnavailable }

        audioQueue.sync {
            self.resampler = resampler
            self.encoder = encoder
            self.firstAudioPtsUs = nil
            self.aacFramesEmitted = 0
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            let hostSeconds = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
            self?.audioQueue.async { self?.processAudio(buffer, hostSeconds: hostSeconds, generation: generation) }
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(for: generation)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeConfigObserver()
            engine.inputNode.removeTap(onBus: 0)
            audioQueue.sync { self.resetAudioState() }
            throw error
        }
        engineStarted = true
        SecureLogger.info("Live video: microphone running (\(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch)", category: .session)
    }

    /// Interruption, route loss or engine reconfiguration: audio ends for this
    /// stream; video keeps going.
    @MainActor
    private func handleAudioInterruption(for generation: UInt) {
        guard captureGeneration.invalidate(ifCurrent: generation) else { return }
        stopEngineIfStarted()
        audioQueue.sync { resetAudioState() }
        sessionLease.release()
        SecureLogger.info("Live video: audio interrupted; continuing video only", category: .session)
    }

    @MainActor
    private func stopAudio() {
        captureGeneration.invalidate()
        stopEngineIfStarted()
        audioQueue.sync { resetAudioState() }
        sessionLease.release()
    }

    /// Never touches `inputNode` of an engine that did not start (that would
    /// instantiate its input unit; see PTTCaptureEngine).
    @MainActor
    private func stopEngineIfStarted() {
        removeConfigObserver()
        guard engineStarted, let engine else {
            self.engine = nil
            return
        }
        engineStarted = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    @MainActor
    private func removeConfigObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    private func resetAudioState() {
        resampler = nil
        encoder = nil
        firstAudioPtsUs = nil
        aacFramesEmitted = 0
    }

    private func processAudio(_ buffer: AVAudioPCMBuffer, hostSeconds: Double?, generation: UInt) {
        guard captureGeneration.isCurrent(generation),
              let encoder,
              let resampled = resampler?.resample(buffer)
        else { return }
        if firstAudioPtsUs == nil {
            firstAudioPtsUs = max(0, hostSeconds.map { relativeUs(hostSeconds: $0) } ?? 0)
        }
        if isMuted, let channels = resampled.floatChannelData {
            for channel in 0..<Int(resampled.format.channelCount) {
                channels[channel].update(repeating: 0, count: Int(resampled.frameLength))
            }
        }
        let frames = encoder.encode(resampled)
        guard !frames.isEmpty else { return }
        // Frame-count timing keeps the AAC timeline gapless and monotonic.
        let ptsUs = (firstAudioPtsUs ?? 0)
            + aacFramesEmitted * Int64(PTTAudioFormat.samplesPerFrame) * 1_000_000 / Int64(PTTAudioFormat.sampleRate)
        aacFramesEmitted += Int64(frames.count)
        onAudioFrames?(frames, ptsUs)
    }
}

// MARK: - Video frames

extension LiveVideoCameraSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }
        // Capture timestamps run on the session's clock; map them to the host
        // clock the audio tap reports, so both tracks share one timeline.
        if let clock = session.synchronizationClock {
            pts = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        }
        let ptsUs = relativeUs(hostSeconds: pts.seconds)
        guard ptsUs >= 0 else { return }
        // Software cap in case the device ignored the frame duration request
        // (20% tolerance for capture jitter).
        let minIntervalUs = Int64(1_000_000 / Self.maxFps) * 8 / 10
        if lastFramePtsUs != .min, ptsUs - lastFramePtsUs < minIntervalUs { return }
        lastFramePtsUs = ptsUs
        onPixelBuffer?(pixelBuffer, ptsUs)
    }
}
