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
    var isLive: Bool { false }

    func requestPermission() async -> Bool {
        await VoiceRecorder.shared.requestPermission()
    }

    func start() async throws {
        try await VoiceRecorder.shared.startRecording()
    }

    func finish() async -> URL? {
        await VoiceRecorder.shared.stopRecording()
    }

    func cancel() async {
        await VoiceRecorder.shared.cancelRecording()
    }
}

/// Live push-to-talk backend: streams `VoiceBurstPacket`s to one peer while
/// recording, then finalizes the same audio as a standard voice note whose
/// file name carries the burst ID (`voice_<burstID>.m4a`) so receivers that
/// heard the live stream absorb the note silently instead of seeing a
/// duplicate.
@MainActor
final class PTTLiveVoiceSession: VoiceCaptureSession {
    let burstID: Data

    private let sendPacket: (Data) -> Void
    private let capture = PTTCaptureEngine()
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
    init(sendPacket: @escaping (Data) -> Void) {
        self.burstID = VoiceBurstPacket.makeBurstID()
        self.sendPacket = sendPacket
        self.stream = StreamState(burstID: burstID)
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
        try capture.start(outputURL: outputURL)
        startDate = Date()
    }

    func finish() async -> URL? {
        guard !completed else { return nil }
        completed = true

        let elapsed = startDate.map { Date().timeIntervalSince($0) } ?? 0
        let (url, encodedFrames) = capture.stop()
        // stop() drained the capture queue, so touching `stream` is safe now.

        guard elapsed >= VoiceRecorder.minRecordingDuration, let url else {
            sendControlPacket(.canceled)
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
            return nil
        }

        for packet in stream.packetizer.flush() {
            sendPacket(packet)
        }
        let durationMs = UInt32((Double(encodedFrames) * PTTAudioFormat.frameDuration * 1000).rounded())
        sendControlPacket(.end(totalDataPackets: stream.packetizer.dataPacketCount, durationMs: durationMs))
        return url
    }

    func cancel() async {
        guard !completed else { return }
        completed = true
        capture.cancel()
        sendControlPacket(.canceled)
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
