//
// LiveVideoH264Decoder.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Decodes released live video units (Annex B access units) to CGImages and
/// paces them by presentation time behind a small jitter buffer, so bursty
/// mesh delivery still plays smoothly — the VideoToolbox counterpart of
/// Android's `LiveVideoDecoder`.
///
/// - The format description is (re)built from the in-band SPS/PPS of a
///   keyframe; until the first keyframe after (re)configuration, a resync, or
///   a decoder error, delta frames are dropped instead of decoded to garbage.
/// - Frames are shown `jitterMs` behind their pts. A frame more than 1.5 s
///   late (or 3 s early) rebases the clock instead of being shown off-time.
///
/// Threading: `submit` may be called from one serial caller queue; the other
/// methods from anywhere. Decoding and pacing run on a private serial worker
/// queue (pacing sleeps there, so the backlog stays compressed and bounded);
/// `onFrame` is delivered on the main queue.
/// `@unchecked Sendable`: shared flags are lock-protected; decoder state is
/// confined to `worker`.
final class LiveVideoH264Decoder: @unchecked Sendable {
    private static let queueCapacity = 96
    private static let rebaseLateMs: Int64 = 1_500
    private static let rebaseEarlyMs: Int64 = 3_000

    private let onFrame: (CGImage) -> Void
    private let jitterMs: Int64
    private let worker = DispatchQueue(label: "chat.bitchat.video.decoder", qos: .userInitiated)
    /// Signaled by `stop()` to cut a pacing wait short.
    private let wake = DispatchSemaphore(value: 0)

    // Lock-protected state shared between callers and the worker.
    private let lock = NSLock()
    private var pending = 0
    /// Bumped by a flush; queued units from an older generation are skipped.
    private var generation: UInt = 0
    private var needKeyframeFlag = false
    private var stopped = false
    private var finishing = false
    private var width = 0
    private var height = 0
    private var decodedCount = 0

    // Worker-confined state.
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var formatParameters: (sps: Data, pps: Data)?
    private var configuredSize = (width: 0, height: 0)
    private var needKeyframe = true
    private var baseMs: Int64?

    var framesDecoded: Int {
        lock.withLock { decodedCount }
    }

    init(onFrame: @escaping (CGImage) -> Void, jitterMs: Int64 = 350) {
        self.onFrame = onFrame
        self.jitterMs = jitterMs
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Sets the stream's picture size (from START). A size change waits for
    /// the next keyframe before decoding again.
    func configure(width: Int, height: Int) {
        lock.withLock {
            guard width != self.width || height != self.height else { return }
            self.width = width
            self.height = height
            needKeyframeFlag = true
        }
    }

    func submit(annexB: Data, ptsMs: Int64, keyframe: Bool) {
        let ticket: UInt? = lock.withLock {
            guard !stopped, !finishing else { return nil }
            if pending >= Self.queueCapacity {
                // Falling behind: drop the backlog and resume at a keyframe.
                generation &+= 1
                pending = 0
                needKeyframeFlag = true
                guard keyframe else { return nil }
            }
            pending += 1
            return generation
        }
        guard let ticket else { return }
        worker.async { [self] in
            let current: Bool = lock.withLock {
                guard ticket == generation else { return false }
                pending = max(0, pending - 1)
                return !stopped
            }
            guard current else { return }
            process(annexB: annexB, ptsMs: ptsMs, keyframe: keyframe)
        }
    }

    /// After units were withheld (app in background), restart cleanly at the
    /// next keyframe.
    func resyncAtKeyframe() {
        lock.withLock {
            generation &+= 1
            pending = 0
            needKeyframeFlag = true
        }
    }

    /// Lets every already-submitted unit decode and present, then releases the
    /// decoder. Later submits are ignored.
    func finishAfterDrain() {
        lock.withLock { finishing = true }
        worker.async { [self] in
            releaseSession()
        }
    }

    /// Stops immediately: pending units are discarded and no further frames
    /// are delivered.
    func stop() {
        let wasStopped = lock.withLock {
            let was = stopped
            stopped = true
            generation &+= 1
            pending = 0
            return was
        }
        guard !wasStopped else { return }
        wake.signal()
        worker.async { [self] in
            releaseSession()
        }
    }

    // MARK: - Worker queue

    private func process(annexB: Data, ptsMs: Int64, keyframe: Bool) {
        let (size, resync) = lock.withLock { () -> ((width: Int, height: Int), Bool) in
            let resync = needKeyframeFlag
            needKeyframeFlag = false
            return ((width, height), resync)
        }
        if resync { needKeyframe = true }
        if needKeyframe && !keyframe { return }

        let units = LiveVideoAVCC.nalUnits(inAnnexB: annexB)
        guard !units.isEmpty else { return }

        if keyframe {
            if let sets = LiveVideoAVCC.parameterSets(in: units) {
                let changed = formatParameters.map { $0.sps != sets.sps || $0.pps != sets.pps } ?? true
                if session == nil || changed || size != configuredSize {
                    guard rebuildSession(sps: sets.sps, pps: sets.pps) else { return }
                    configuredSize = size
                }
            }
            guard session != nil else { return }
            needKeyframe = false
        }
        guard let session, let format else { return }

        let slices = units.filter {
            let type = LiveVideoAVCC.nalType($0)
            return type != LiveVideoAVCC.typeSPS && type != LiveVideoAVCC.typePPS
                && type != LiveVideoAVCC.typeAUD && type != LiveVideoAVCC.typeFiller
        }
        guard !slices.isEmpty,
              let sample = LiveVideoAVCC.sampleBuffer(
                  avcc: LiveVideoAVCC.avccSample(from: slices),
                  format: format,
                  pts: CMTime(value: ptsMs, timescale: 1_000),
                  keyframe: keyframe
              )
        else { return }

        // Synchronous decode (no async flag): the handler runs before return.
        var decoded: CGImage?
        var decodeError: OSStatus = noErr
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [],
            infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else {
                decodeError = status
                return
            }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &image)
            decoded = image
        }
        if status != noErr || decodeError != noErr {
            let code = status != noErr ? status : decodeError
            SecureLogger.debug("Live video: decode error \(code); waiting for next keyframe", category: .session)
            // Also covers kVTInvalidSessionErr after an iOS background
            // transition: the session is rebuilt at the next keyframe.
            releaseSession()
            needKeyframe = true
            return
        }
        guard let decoded else { return }
        present(decoded, ptsMs: ptsMs)
    }

    private func present(_ image: CGImage, ptsMs: Int64) {
        let now = Self.nowMs()
        var base = baseMs ?? (now - ptsMs + jitterMs)
        var due = base + ptsMs
        if due < now - Self.rebaseLateMs || due > now + Self.rebaseEarlyMs {
            base = now - ptsMs + jitterMs
            due = base + ptsMs
        }
        baseMs = base
        let wait = min(due - now, Self.rebaseEarlyMs)
        if wait > 0 {
            // Woken early only by stop().
            _ = wake.wait(timeout: .now() + .milliseconds(Int(wait)))
        }
        let deliver: Bool = lock.withLock {
            guard !stopped else { return false }
            decodedCount += 1
            return true
        }
        guard deliver else { return }
        DispatchQueue.main.async { [self] in
            guard !lock.withLock({ stopped }) else { return }
            onFrame(image)
        }
    }

    private func rebuildSession(sps: Data, pps: Data) -> Bool {
        releaseSession()
        guard let description = LiveVideoAVCC.formatDescription(sps: sps, pps: pps) else {
            SecureLogger.debug("Live video: invalid SPS/PPS", category: .session)
            return false
        }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else {
            SecureLogger.error("Live video: decoder creation failed (\(status))", category: .session)
            return false
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        format = description
        formatParameters = (sps, pps)
        return true
    }

    private func releaseSession() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
        formatParameters = nil
    }

    private static func nowMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
