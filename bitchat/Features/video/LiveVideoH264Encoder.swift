//
// LiveVideoH264Encoder.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// One encoded H.264 access unit, ready for the wire: Annex B with 4-byte
/// start codes, and on keyframes prefixed with SPS + PPS so any keyframe can
/// start a decoder (viewers join mid-stream).
struct LiveVideoEncodedFrame {
    let annexB: Data
    let ptsUs: Int64
    let keyframe: Bool
}

/// Real-time H.264 Constrained Baseline encoder for live video, the
/// VideoToolbox counterpart of Android's `H264Encoder`.
///
/// Any input picture (camera NV12, synthetic BGRA, any size) is center-cropped
/// and scaled to `width`×`height` NV12 through a pixel transfer session into a
/// pooled buffer before encoding, so callers never resize themselves.
///
/// Threading: `encode`/`setBitrate`/`requestKeyframe`/`finish`/`invalidate`
/// may be called from any thread (session state is lock-protected); `onFrame`
/// is always called on the encoder's private serial queue, in output order.
/// `@unchecked Sendable`: mutable state is guarded by `lock` or confined to
/// `callbackQueue`.
final class LiveVideoH264Encoder: @unchecked Sendable {
    enum EncoderError: Error {
        case invalidDimensions
        case sessionCreationFailed(OSStatus)
        case pixelTransferUnavailable(OSStatus)
    }

    let width: Int
    let height: Int
    let fps: Int

    /// Called on the encoder's serial queue with each encoded access unit.
    var onFrame: ((LiveVideoEncodedFrame) -> Void)?

    private let callbackQueue = DispatchQueue(label: "chat.bitchat.video.encoder", qos: .userInitiated)
    private let lock = NSLock()

    // Lock-protected state.
    private var session: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var forceKeyframe = false
    private var lastPtsUs: Int64 = .min
    private(set) var currentBitrate: Int

    init(width: Int, height: Int, fps: Int, bitrate: Int, keyframeIntervalSeconds: Int) throws {
        guard width >= 16, height >= 16, width % 2 == 0, height % 2 == 0, fps > 0 else {
            throw EncoderError.invalidDimensions
        }
        self.width = width
        self.height = height
        self.fps = fps
        self.currentBitrate = bitrate

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: Self.pixelBufferAttributes(width: width, height: height) as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let session = created else {
            throw EncoderError.sessionCreationFailed(status)
        }

        Self.set(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        // Constrained Baseline is what every Android decoder accepts; older
        // OS encoders that lack the constant fall back to plain Baseline.
        if VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel) != noErr {
            Self.set(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
        }
        Self.set(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        Self.set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: max(1, fps * keyframeIntervalSeconds)))
        Self.set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: max(1, keyframeIntervalSeconds)))
        Self.set(session, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        Self.applyBitrate(bitrate, to: session)
        VTCompressionSessionPrepareToEncodeFrames(session)

        var transferSession: VTPixelTransferSession?
        let transferStatus = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession)
        guard transferStatus == noErr, let transferSession else {
            VTCompressionSessionInvalidate(session)
            throw EncoderError.pixelTransferUnavailable(transferStatus)
        }
        // Trim = preserve aspect ratio and crop to fill: a center crop.
        Self.set(transferSession, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Trim)

        var createdPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
            Self.pixelBufferAttributes(width: width, height: height) as CFDictionary,
            &createdPool
        )

        self.session = session
        self.transfer = transferSession
        self.pool = createdPool
    }

    deinit {
        invalidate()
    }

    /// Encodes one picture. `ptsUs` must increase; frames at or before the
    /// previous timestamp are dropped (VideoToolbox rejects them anyway).
    func encode(_ pixelBuffer: CVPixelBuffer, ptsUs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard let session, ptsUs > lastPtsUs else { return }
        guard let input = prepare(pixelBuffer) else { return }
        lastPtsUs = ptsUs

        var properties: CFDictionary?
        if forceKeyframe {
            forceKeyframe = false
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: input,
            presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000),
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, flags, sample in
            self?.handleOutput(status: status, flags: flags, sample: sample)
        }
        if status != noErr {
            SecureLogger.error("Live video: encode failed (\(status))", category: .session)
        }
    }

    /// Changes the target bitrate of the running session (congestion control).
    func setBitrate(_ bitrate: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard bitrate > 0, bitrate != currentBitrate, let session else { return }
        currentBitrate = bitrate
        Self.applyBitrate(bitrate, to: session)
    }

    /// The next encoded picture will be an IDR.
    func requestKeyframe() {
        lock.lock()
        forceKeyframe = true
        lock.unlock()
    }

    /// Flushes every pending frame and waits until `onFrame` has seen them all.
    func finish() {
        lock.lock()
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        }
        lock.unlock()
        // Output handlers hop to callbackQueue; draining it delivers the tail.
        callbackQueue.sync {}
    }

    /// Tears the session down; pending output is discarded. Idempotent.
    func invalidate() {
        lock.lock()
        let session = self.session
        let transfer = self.transfer
        self.session = nil
        self.transfer = nil
        self.pool = nil
        lock.unlock()
        if let session { VTCompressionSessionInvalidate(session) }
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
    }

    // MARK: - Private

    /// Returns `pixelBuffer` itself when it already matches the encoder, else
    /// a pooled NV12 copy center-cropped/scaled to width×height.
    private func prepare(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if CVPixelBufferGetWidth(pixelBuffer) == width,
           CVPixelBufferGetHeight(pixelBuffer) == height,
           format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            return pixelBuffer
        }
        guard let transfer else { return nil }
        var output: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        }
        if output == nil {
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                Self.pixelBufferAttributes(width: width, height: height) as CFDictionary,
                &output
            )
        }
        guard let output else { return nil }
        let status = VTPixelTransferSessionTransferImage(transfer, from: pixelBuffer, to: output)
        guard status == noErr else {
            SecureLogger.error("Live video: pixel transfer failed (\(status))", category: .session)
            return nil
        }
        return output
    }

    /// Runs on a VideoToolbox thread; converts synchronously (the sample's
    /// memory belongs to the encoder) and hands the frame to the serial queue.
    private func handleOutput(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        guard status == noErr, !flags.contains(.frameDropped), let sample else {
            if status != noErr {
                SecureLogger.error("Live video: encoder output error (\(status))", category: .session)
            }
            return
        }
        guard let frame = Self.annexBFrame(from: sample) else { return }
        callbackQueue.async { [weak self] in
            self?.onFrame?(frame)
        }
    }

    static func annexBFrame(from sample: CMSampleBuffer) -> LiveVideoEncodedFrame? {
        guard CMSampleBufferDataIsReady(sample),
              let format = CMSampleBufferGetFormatDescription(sample),
              let data = LiveVideoAVCC.data(of: sample),
              let parameters = LiveVideoAVCC.parameterSets(of: format)
        else { return nil }
        let keyframe = LiveVideoAVCC.isSync(sample)
        var units = LiveVideoAVCC.nalUnits(inAVCC: data, lengthSize: parameters.lengthSize)
            .filter { LiveVideoAVCC.nalType($0) != LiveVideoAVCC.typeFiller }
        guard !units.isEmpty else { return nil }
        if keyframe {
            // In-band SPS/PPS let a viewer start at any keyframe.
            units.removeAll { [LiveVideoAVCC.typeSPS, LiveVideoAVCC.typePPS].contains(LiveVideoAVCC.nalType($0)) }
            units.insert(contentsOf: parameters.sets, at: 0)
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let ptsUs = pts.isValid ? CMTimeConvertScale(pts, timescale: 1_000_000, method: .roundHalfAwayFromZero).value : 0
        return LiveVideoEncodedFrame(annexB: LiveVideoAVCC.annexB(from: units), ptsUs: ptsUs, keyframe: keyframe)
    }

    private static func applyBitrate(_ bitrate: Int, to session: VTCompressionSession) {
        set(session, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        // Cap each one-second window at 1.5x the average: the mesh link has no
        // spare capacity for the bursts unconstrained VBR produces.
        let bytesPerSecond = max(1, bitrate * 3 / 2 / 8)
        set(session, kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: bytesPerSecond), NSNumber(value: 1)] as CFArray)
    }

    private static func set(_ session: VTSession, _ key: CFString, _ value: CFTypeRef?) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            SecureLogger.debug("Live video: VideoToolbox rejected \(key) (\(status))", category: .session)
        }
    }

    private static func pixelBufferAttributes(width: Int, height: Int) -> [CFString: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()
        ]
    }
}
