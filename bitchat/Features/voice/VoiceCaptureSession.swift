//
// VoiceCaptureSession.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import Foundation

/// Capture backend behind the composer's hold-to-record gesture.
/// `VoiceRecordingViewModel` drives one session per press; the concrete type
/// decides *how* audio leaves the device: `VoiceNoteCaptureSession` records a
/// note delivered on release (today's behavior), `PTTLiveVoiceSession`
/// additionally streams frames live while the button is held.
@MainActor
protocol VoiceCaptureSession: AnyObject {
    /// Whether audio is leaving the device in real time while recording —
    /// drives the composer's LIVE treatment.
    var isLive: Bool { get }
    func requestPermission() async -> Bool
    func start() async throws
    /// Stops capture and returns the finalized voice-note file, or nil when
    /// nothing valid was captured.
    func finish() async -> URL?
    func cancel() async
}

/// The classic record-then-send backend, wrapping the shared `VoiceRecorder`.
@MainActor
final class VoiceNoteCaptureSession: VoiceCaptureSession {
    private let recorder: VoiceRecorder
    private let owner = VoiceRecorder.RecordingOwner()

    var isLive: Bool { false }

    init(recorder: VoiceRecorder = .shared) {
        self.recorder = recorder
    }

    func requestPermission() async -> Bool {
        await recorder.requestPermission()
    }

    func start() async throws {
        try await recorder.startRecording(owner: owner)
    }

    func finish() async -> URL? {
        await recorder.stopRecording(owner: owner)
    }

    func cancel() async {
        await recorder.cancelRecording(owner: owner)
    }
}

/// Testable surface of the live capture engine. Production uses
/// `PTTCaptureEngine`; tests can supply captured-frame counts without opening
/// real audio hardware.
@MainActor
protocol PTTCapturing: AnyObject {
    var onFrames: (([Data]) -> Void)? { get set }
    func start(outputURL: URL) async throws
    func stop() -> (url: URL?, encodedFrames: Int)
    func cancel()
}

extension PTTCaptureEngine: PTTCapturing {}

/// Live push-to-talk backend: streams `VoiceBurstPacket`s to one peer while
/// recording, then finalizes the same audio as a standard voice note whose
/// file name carries the burst ID (`voice_<burstID>.m4a`) so receivers that
/// heard the live stream absorb the note silently instead of seeing a
/// duplicate.
@MainActor
final class PTTLiveVoiceSession: VoiceCaptureSession {
    let burstID: Data

    private let sendPacket: (Data) -> Void
    private let capture: any PTTCapturing
    private let now: () -> Date
    /// Capture-queue-confined stream state: packetizes frames and lazily
    /// emits START so packet order is guaranteed by queue serialization.
    private final class StreamState {
        var packetizer: VoiceBurstPacketizer
        var sentStart = false
        init(burstID: Data) {
            packetizer = VoiceBurstPacketizer(burstID: burstID)
        }
    }
    private let stream: StreamState
    private var startDate: Date?
    private var completed = false

    var isLive: Bool { true }

    /// - Parameter sendPacket: delivers one encoded `VoiceBurstPacket` to the
    ///   target peer; must be safe to call from any queue (BLEService hops to
    ///   its own message queue internally).
    init(
        sendPacket: @escaping (Data) -> Void,
        capture: (any PTTCapturing)? = nil,
        now: @escaping () -> Date = Date.init,
        burstID: Data? = nil
    ) {
        self.burstID = burstID ?? VoiceBurstPacket.makeBurstID()
        self.sendPacket = sendPacket
        self.capture = capture ?? PTTCaptureEngine()
        self.now = now
        self.stream = StreamState(burstID: self.burstID)
    }

    func requestPermission() async -> Bool {
        await VoiceRecorder.shared.requestPermission()
    }

    func start() async throws {
        let outputURL = try Self.makeOutputURL(burstID: burstID)
        let sendPacket = sendPacket
        let stream = stream
        capture.onFrames = { frames in
            if !stream.sentStart {
                stream.sentStart = true
                if let start = VoiceBurstPacket(
                    burstID: stream.packetizer.burstID,
                    seq: 0,
                    kind: .start(codec: .aacLC16kMono)
                ) {
                    sendPacket(start.encode())
                }
            }
            for frame in frames {
                for packet in stream.packetizer.add(frame) {
                    sendPacket(packet)
                }
            }
            // Flush per callback batch: at ~130-byte frames the budget fits
            // one frame per packet anyway, and holding residue would add
            // ~100 ms of avoidable latency.
            for packet in stream.packetizer.flush() {
                sendPacket(packet)
            }
        }
        do {
            try await capture.start(outputURL: outputURL)
        } catch is CancellationError {
            // The hold was released/canceled while the session acquire was
            // in flight: the engine never started and the capture already
            // handed its token back — nothing to retry. A coordinator-side
            // interruption during handoff also cancels acquire, but that is
            // not a successful start and must propagate to the view model.
            guard completed else { throw CancellationError() }
            return
        } catch {
            // The HAL can briefly report a dead input right after the audio
            // session (re)activates while the route settles; one retry after
            // a short pause covers it (observed on iPhone field tests).
            SecureLogger.warning("PTT: capture start failed (\(error)) — retrying once after route settle", category: .session)
            try? await Task.sleep(nanoseconds: 150_000_000)
            // The hold may have been released/canceled during the retry pause.
            // Starting the mic now would leave it live and streaming after the
            // user let go, so bail instead of opening a hot mic.
            guard !completed else {
                capture.cancel()
                return
            }
            try await capture.start(outputURL: outputURL)
        }
        startDate = now()
        SecureLogger.info("PTT: live burst \(burstID.hexEncodedString()) capture started", category: .session)
    }

    func finish() async -> URL? {
        guard !completed else { return nil }
        completed = true

        let elapsed = startDate.map { now().timeIntervalSince($0) } ?? 0
        let (url, encodedFrames) = capture.stop()
        // stop() drained the capture queue, so touching `stream` is safe now.

        let capturedDuration = Double(encodedFrames) * PTTAudioFormat.frameDuration

        guard elapsed >= VoiceRecorder.minRecordingDuration,
              capturedDuration >= VoiceRecorder.minRecordingDuration,
              let url
        else {
            sendControlPacket(.canceled)
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
            return nil
        }

        for packet in stream.packetizer.flush() {
            sendPacket(packet)
        }
        let durationMs = UInt32((capturedDuration * 1000).rounded())
        sendControlPacket(.end(totalDataPackets: stream.packetizer.dataPacketCount, durationMs: durationMs))
        SecureLogger.info("PTT: live burst \(burstID.hexEncodedString()) finished — \(stream.packetizer.dataPacketCount) data packets, \(encodedFrames) frames, \(durationMs) ms", category: .session)
        return url
    }

    func cancel() async {
        let alreadyCompleted = completed
        completed = true
        // Always tear down the capture, even if a quick-release already marked
        // us completed: the engine can start late (during start()'s retry
        // pause), and only capture.cancel() stops the mic and deactivates the
        // session. It is idempotent, so a redundant call is harmless.
        capture.cancel()
        if !alreadyCompleted {
            sendControlPacket(.canceled)
        }
    }

    private func sendControlPacket(_ kind: VoiceBurstPacket.Kind) {
        guard let packet = VoiceBurstPacket(burstID: burstID, seq: stream.packetizer.nextSeq, kind: kind) else { return }
        sendPacket(packet.encode())
    }

    private static func makeOutputURL(burstID: Data) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent("voicenotes/outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory.appendingPathComponent("voice_\(burstID.hexEncodedString()).m4a")
    }
}
