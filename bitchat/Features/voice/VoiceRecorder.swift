import Foundation
import AVFoundation

/// The small surface of `AVAudioRecorder` that `VoiceRecorder` owns. Keeping
/// it behind a protocol lets lifecycle races be tested without opening the
/// microphone on the test host.
protocol VoiceAudioRecording: AnyObject {
    var isRecording: Bool { get }
    var isMeteringEnabled: Bool { get set }
    func prepareToRecord() -> Bool
    func record(forDuration duration: TimeInterval) -> Bool
    func stop()
}

extension AVAudioRecorder: VoiceAudioRecording {}

protocol VoiceAudioRecorderCreating {
    func makeRecorder(url: URL) throws -> any VoiceAudioRecording
}

private struct SystemVoiceAudioRecorderFactory: VoiceAudioRecorderCreating {
    func makeRecorder(url: URL) throws -> any VoiceAudioRecording {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 16_000
        ]
        return try AVAudioRecorder(url: url, settings: settings)
    }
}

/// Manages audio capture for mesh voice notes with predictable encoding settings.
actor VoiceRecorder {
    enum RecorderError: Error, Equatable {
        case microphoneAccessDenied
        case recordingInProgress
        case failedToStartRecording
    }

    static let shared = VoiceRecorder()

    static let minRecordingDuration: TimeInterval = 1

    /// Identity of one press/hold. Every lifecycle mutation must present the
    /// same owner that started the recorder, so a stale finish or cancel from
    /// another hold cannot stop or delete the current recording.
    final class RecordingOwner: @unchecked Sendable {}

    /// Test-only scheduling seams for lifecycle boundaries that otherwise rely
    /// on wall-clock sleeps. Production uses the real padding delay.
    struct TestingHooks: Sendable {
        let waitForStopPadding: (@Sendable (TimeInterval) async -> Void)?

        init(waitForStopPadding: (@Sendable (TimeInterval) async -> Void)? = nil) {
            self.waitForStopPadding = waitForStopPadding
        }
    }

    private let sessionCoordinator: AudioSessionCoordinator
    private let recorderFactory: any VoiceAudioRecorderCreating
    private let permissionGranted: () -> Bool
    private let paddingInterval: TimeInterval
    private let maxRecordingDuration: TimeInterval
    private let outputDirectory: URL?
    private let testingHooks: TestingHooks

    private var recorder: (any VoiceAudioRecording)?
    private var currentURL: URL?
    private var sessionToken: AudioSessionCoordinator.Token?
    private var activeOwner: RecordingOwner?
    /// True only while `startRecording()` is suspended in session acquire.
    /// A second start is rejected instead of superseding the first one.
    private var startInFlight = false

    init(
        sessionCoordinator: AudioSessionCoordinator = .shared,
        recorderFactory: any VoiceAudioRecorderCreating = SystemVoiceAudioRecorderFactory(),
        permissionGranted: (() -> Bool)? = nil,
        paddingInterval: TimeInterval = 0.5,
        maxRecordingDuration: TimeInterval = 120,
        outputDirectory: URL? = nil,
        testingHooks: TestingHooks = TestingHooks()
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.recorderFactory = recorderFactory
        self.permissionGranted = permissionGranted ?? Self.hasSystemPermission
        self.paddingInterval = paddingInterval
        self.maxRecordingDuration = maxRecordingDuration
        self.outputDirectory = outputDirectory
        self.testingHooks = testingHooks
    }

    // MARK: - Permissions

    nonisolated
    func requestPermission() async -> Bool {
        #if os(iOS)
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #elseif os(macOS)
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        return true
        #endif
    }

    // MARK: - Recording Lifecycle

    @discardableResult
    func startRecording(owner: RecordingOwner) async throws -> URL {
        if activeOwner != nil {
            throw RecorderError.recordingInProgress
        }

        guard permissionGranted() else {
            throw RecorderError.microphoneAccessDenied
        }

        activeOwner = owner
        startInFlight = true

        // The acquire suspends while the blocking session IPC runs on the
        // coordinator's queue (never this actor's thread or main).
        let token: AudioSessionCoordinator.Token
        do {
            token = try await sessionCoordinator.acquire(.capture) { [weak self] in
                Task { await self?.handleSessionInterruption(for: owner) }
            }
        } catch {
            guard activeOwner === owner else {
                throw CancellationError()
            }
            startInFlight = false
            activeOwner = nil
            throw error
        }

        // Actor reentrancy: release/cancel may have ended this hold while the
        // blocking session activation was still in progress.
        guard activeOwner === owner, startInFlight else {
            sessionCoordinator.release(token)
            throw CancellationError()
        }
        startInFlight = false
        sessionToken = token

        var outputURL: URL?
        do {
            let newURL = try makeOutputURL()
            outputURL = newURL
            let audioRecorder = try recorderFactory.makeRecorder(url: newURL)
            audioRecorder.isMeteringEnabled = true
            guard audioRecorder.prepareToRecord() else {
                throw RecorderError.failedToStartRecording
            }
            guard audioRecorder.record(forDuration: maxRecordingDuration) else {
                throw RecorderError.failedToStartRecording
            }

            recorder = audioRecorder
            currentURL = newURL
            return newURL
        } catch {
            releaseSessionToken()
            recorder = nil
            currentURL = nil
            activeOwner = nil
            if let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
            throw error
        }
    }

    func stopRecording(owner: RecordingOwner) async -> URL? {
        guard activeOwner === owner else { return nil }

        // `finish()` can race a still-suspended start on a direct caller even
        // though the UI normally routes quick releases through cancel().
        if startInFlight {
            activeOwner = nil
            startInFlight = false
            return nil
        }

        guard let activeRecorder = recorder else {
            let sessionURL = currentURL
            releaseSessionToken()
            currentURL = nil
            activeOwner = nil
            return sessionURL
        }

        let sessionURL = currentURL

        if activeRecorder.isRecording, paddingInterval > 0 {
            if let waitForStopPadding = testingHooks.waitForStopPadding {
                await waitForStopPadding(paddingInterval)
            } else {
                try? await Task.sleep(nanoseconds: UInt64(paddingInterval * 1_000_000_000))
            }
        }

        // Cancellation or interruption may have run during the padding sleep.
        // Only the recorder whose stop began here may be finalized by it.
        guard activeOwner === owner,
              let recorder = self.recorder,
              recorder === activeRecorder
        else { return nil }

        if activeRecorder.isRecording {
            activeRecorder.stop()
        }
        releaseSessionToken()
        self.recorder = nil
        currentURL = nil
        activeOwner = nil

        return sessionURL
    }

    func cancelRecording(owner: RecordingOwner) async {
        guard activeOwner === owner else { return }

        // Invalidate ownership before cleanup. An actor-reentrant start whose
        // session acquire resumes later will observe the mismatch and release
        // its token without opening the microphone.
        activeOwner = nil
        startInFlight = false
        if let recorder, recorder.isRecording {
            recorder.stop()
        }
        releaseSessionToken()
        if let currentURL {
            try? FileManager.default.removeItem(at: currentURL)
        }
        recorder = nil
        currentURL = nil
    }

    /// The audio session was interrupted (call, Siri) or reconfigured: stop
    /// the recorder but keep `recorder`/`currentURL` so the caller's pending
    /// `stopRecording()` still returns the partial note.
    private func handleSessionInterruption(for owner: RecordingOwner) async {
        // A callback captured for a released token must never stop a newer
        // recording. Conversely, an interruption delivered while acquire is
        // still suspended invalidates that acquire before it can open the mic.
        guard activeOwner === owner else { return }
        if startInFlight {
            activeOwner = nil
            startInFlight = false
            return
        }
        startInFlight = false
        if let recorder, recorder.isRecording {
            recorder.stop()
        }
        releaseSessionToken()
    }

    // MARK: - Helpers

    private static func hasSystemPermission() -> Bool {
        #if os(iOS)
        AVAudioSession.sharedInstance().recordPermission == .granted
        #elseif os(macOS)
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        #else
        true
        #endif
    }

    private func makeOutputURL() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "voice_\(formatter.string(from: Date()))_\(UUID().uuidString).m4a"

        let baseDirectory = try outputDirectory
            ?? applicationFilesDirectory().appendingPathComponent("voicenotes/outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true, attributes: nil)
        return baseDirectory.appendingPathComponent(fileName)
    }

    private func applicationFilesDirectory() throws -> URL {
        #if os(iOS)
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("files", isDirectory: true)
        #else
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("files", isDirectory: true)
        #endif
    }

    /// Fire-and-forget: the coordinator hops the blocking deactivation IPC
    /// onto its own queue.
    private func releaseSessionToken() {
        guard let token = sessionToken else { return }
        sessionToken = nil
        sessionCoordinator.release(token)
    }
}
