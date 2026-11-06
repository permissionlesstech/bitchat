//
// LiveVideoMp4Writer.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import AVFoundation
import BitLogger
import CoreMedia
import Foundation

/// Muxes already-encoded live video (Annex B H.264) and raw AAC-LC frames
/// into an MP4 without re-encoding — the AVAssetWriter counterpart of
/// Android's `Mp4Writer`. The sender records its own stream with it, and
/// viewers rebuild a stream from the units they received, so it tolerates
/// what a lossy mesh produces:
///
/// - nothing is written until a keyframe carrying SPS/PPS arrives (that
///   keyframe creates the track format and starts the session at its pts);
///   earlier video and audio are dropped;
/// - samples at or before their track's previous timestamp are dropped;
/// - gaps are fine: each video sample lasts until the next one, so missing
///   frames play back as a held picture; missing audio is filled with
///   encoded silence (AVAssetWriter would otherwise close audio gaps and
///   drift the sound ahead of the picture).
///
/// Threading: call from one serial queue (methods are also lock-protected,
/// so a stray call from elsewhere cannot corrupt state).
final class LiveVideoMp4Writer {
    /// How long a real-time append may wait for the writer before dropping.
    private static let readyTimeout: TimeInterval = 0.25
    /// Duration given to the final video sample, which has no successor.
    private static let fallbackFrameDurationUs: Int64 = 66_666

    let url: URL
    private let hasAudio: Bool
    private let lock = NSLock()

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var videoFormat: CMVideoFormatDescription?
    private var videoParameters: (sps: Data, pps: Data)?
    private var audioFormat: CMAudioFormatDescription?
    private var failed = false
    private var finished = false

    /// One-sample lookahead: a video sample's duration is the distance to the
    /// next one, so it is appended when its successor arrives.
    private var pendingVideo: (avcc: Data, ptsUs: Int64, keyframe: Bool)?
    private var lastVideoPtsUs: Int64 = .min
    private var lastAudioPtsUs: Int64 = .min
    private var lastVideoDurationUs: Int64 = fallbackFrameDurationUs
    private var startPtsUs: Int64 = 0
    private var endPtsUs: Int64 = 0

    private(set) var videoSamples = 0
    private(set) var audioSamples = 0

    init(url: URL, hasAudio: Bool) {
        self.url = url
        self.hasAudio = hasAudio
    }

    func writeVideo(annexB: Data, ptsUs: Int64, keyframe: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !failed, !finished, ptsUs > lastVideoPtsUs else { return }
        let units = LiveVideoAVCC.nalUnits(inAnnexB: annexB)
        guard !units.isEmpty else { return }

        if writer == nil {
            // MP4 needs the first video sample to be a sync sample and the
            // track format up front: wait for a self-contained keyframe.
            guard keyframe, let sets = LiveVideoAVCC.parameterSets(in: units) else { return }
            guard start(sps: sets.sps, pps: sets.pps, ptsUs: ptsUs) else { return }
        }

        // Parameter sets live in the track format. Keep them in-band only if
        // the encoder changed them mid-stream, so the sample stays decodable.
        let inBandSetsMatch = LiveVideoAVCC.parameterSets(in: units).map {
            $0.sps == videoParameters?.sps && $0.pps == videoParameters?.pps
        } ?? true
        let kept = units.filter { nal in
            switch LiveVideoAVCC.nalType(nal) {
            case LiveVideoAVCC.typeAUD, LiveVideoAVCC.typeFiller:
                return false
            case LiveVideoAVCC.typeSPS, LiveVideoAVCC.typePPS:
                return !inBandSetsMatch
            default:
                return true
            }
        }
        guard !kept.isEmpty else { return }

        if let previous = pendingVideo {
            let duration = ptsUs - previous.ptsUs
            appendVideo(previous, durationUs: duration)
            lastVideoDurationUs = duration
        }
        pendingVideo = (LiveVideoAVCC.avccSample(from: kept), ptsUs, keyframe)
        lastVideoPtsUs = ptsUs
    }

    /// Raw AAC-LC 16 kHz mono access unit (no ADTS), 1024 samples long.
    func writeAudio(aac: Data, ptsUs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard hasAudio, !failed, !finished, !aac.isEmpty,
              let writer, writer.status == .writing,
              let audioInput, let audioFormat,
              ptsUs >= startPtsUs, ptsUs > lastAudioPtsUs
        else { return }

        // AVAssetWriter packs passthrough audio back to back and ignores
        // timestamp gaps, so units lost on the mesh would pull all later
        // audio early against the picture. Hold the timeline with silence.
        let frameUs = Self.audioFrameDurationUs
        if lastAudioPtsUs != .min, let silence = Self.silentAACFrame {
            var expected = lastAudioPtsUs + frameUs
            var inserted = 0
            while ptsUs - expected >= frameUs / 2, inserted < Self.maxSilenceFrames {
                guard let filler = Self.audioSample(silence, ptsUs: expected, format: audioFormat),
                      append(filler, to: audioInput)
                else { break }
                expected += frameUs
                inserted += 1
            }
        }

        guard let sample = Self.audioSample(aac, ptsUs: ptsUs, format: audioFormat),
              append(sample, to: audioInput)
        else { return }
        lastAudioPtsUs = ptsUs
        audioSamples += 1
        endPtsUs = max(endPtsUs, ptsUs + frameUs)
    }

    /// Finalizes the file synchronously. Returns false (and deletes the file)
    /// when no video was written or the writer failed.
    @discardableResult
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        guard let writer else { return false }

        if let last = pendingVideo {
            appendVideo(last, durationUs: lastVideoDurationUs)
            pendingVideo = nil
        }
        guard !failed, writer.status == .writing, videoSamples > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return false
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: max(endPtsUs, startPtsUs + 1), timescale: 1_000_000))

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            SecureLogger.error("Live video: MP4 finalize failed: \(writer.error?.localizedDescription ?? "unknown")", category: .session)
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }

    // MARK: - Private

    static var audioFrameDurationUs: Int64 {
        Int64(PTTAudioFormat.samplesPerFrame) * 1_000_000 / Int64(PTTAudioFormat.sampleRate)
    }

    /// Longest audio gap bridged with silence (~2 min); longer dropouts end
    /// the recording segment anyway.
    private static let maxSilenceFrames = 2_000

    /// One steady-state AAC-LC frame of digital silence (a few bytes),
    /// encoded once with the live-voice encoder.
    static let silentAACFrame: Data? = {
        guard let encoder = PTTFrameEncoder(), let format = PTTAudioFormat.pcmFormat else { return nil }
        var frames: [Data] = []
        // Run past the encoder's priming so the frame is a plain silent one.
        for _ in 0..<4 {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: PTTAudioFormat.samplesPerFrame) else { return nil }
            pcm.frameLength = PTTAudioFormat.samplesPerFrame
            if let channel = pcm.floatChannelData?[0] {
                channel.update(repeating: 0, count: Int(pcm.frameLength))
            }
            frames.append(contentsOf: encoder.encode(pcm))
        }
        return frames.last
    }()

    /// Wraps one raw AAC frame in a ready sample buffer.
    static func audioSample(_ aac: Data, ptsUs: Int64, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        guard let block = LiveVideoAVCC.blockBuffer(copying: aac) else { return nil }
        var packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(aac.count))
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000),
            packetDescriptions: &packet,
            sampleBufferOut: &sample
        )
        return status == noErr ? sample : nil
    }

    private func start(sps: Data, pps: Data, ptsUs: Int64) -> Bool {
        guard let format = LiveVideoAVCC.formatDescription(sps: sps, pps: pps) else {
            SecureLogger.debug("Live video: MP4 writer got invalid SPS/PPS", category: .session)
            return false
        }
        do {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            video.expectsMediaDataInRealTime = true
            guard writer.canAdd(video) else { throw LiveVideoMp4WriterError.inputRejected }
            writer.add(video)

            if hasAudio, let audioFormat = Self.makeAudioFormat() {
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
                audio.expectsMediaDataInRealTime = true
                if writer.canAdd(audio) {
                    writer.add(audio)
                    self.audioInput = audio
                    self.audioFormat = audioFormat
                }
            }
            guard writer.startWriting() else {
                throw writer.error ?? LiveVideoMp4WriterError.inputRejected
            }
            writer.startSession(atSourceTime: CMTime(value: ptsUs, timescale: 1_000_000))
            self.writer = writer
            self.videoInput = video
            self.videoFormat = format
            self.videoParameters = (sps, pps)
            self.startPtsUs = ptsUs
            self.endPtsUs = ptsUs
            return true
        } catch {
            SecureLogger.error("Live video: MP4 writer unavailable: \(error)", category: .session)
            failed = true
            return false
        }
    }

    private func appendVideo(_ sample: (avcc: Data, ptsUs: Int64, keyframe: Bool), durationUs: Int64) {
        guard let videoInput, let videoFormat,
              let buffer = LiveVideoAVCC.sampleBuffer(
                  avcc: sample.avcc,
                  format: videoFormat,
                  pts: CMTime(value: sample.ptsUs, timescale: 1_000_000),
                  duration: CMTime(value: max(1, durationUs), timescale: 1_000_000),
                  keyframe: sample.keyframe
              )
        else { return }
        guard append(buffer, to: videoInput) else { return }
        videoSamples += 1
        endPtsUs = max(endPtsUs, sample.ptsUs + max(1, durationUs))
    }

    private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput) -> Bool {
        guard let writer, writer.status == .writing else {
            markFailedIfNeeded()
            return false
        }
        let deadline = Date().addingTimeInterval(Self.readyTimeout)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, Date() < deadline else {
                SecureLogger.debug("Live video: MP4 writer busy; dropping sample", category: .session)
                markFailedIfNeeded()
                return false
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard input.append(sample) else {
            markFailedIfNeeded()
            return false
        }
        return true
    }

    private func markFailedIfNeeded() {
        guard let writer, writer.status == .failed, !failed else { return }
        failed = true
        SecureLogger.error("Live video: MP4 writer failed: \(writer.error?.localizedDescription ?? "unknown")", category: .session)
    }

    /// CoreAudio's AAC magic cookie is an MPEG-4 ES_Descriptor wrapping the
    /// AudioSpecificConfig; with the bare 2-byte config AVAssetWriter writes
    /// an `esds` that AVFoundation then refuses to load as a track. The
    /// encoder that `PTTFrameEncoder` uses produces exactly the right cookie
    /// for this format, so take it from there (raw config as last resort).
    private static let aacMagicCookie: Data = {
        if let pcm = PTTAudioFormat.pcmFormat,
           let aac = PTTAudioFormat.aacFormat,
           let converter = AVAudioConverter(from: pcm, to: aac),
           let cookie = converter.magicCookie,
           !cookie.isEmpty {
            return cookie
        }
        // Object type 2 (LC), frequency index 8 (16 kHz), channel config 1.
        return Data([0x14, 0x08])
    }()

    /// AAC-LC, 16 kHz, mono, 1024 frames per packet.
    static func makeAudioFormat() -> CMAudioFormatDescription? {
        var description = AudioStreamBasicDescription(
            mSampleRate: PTTAudioFormat.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: PTTAudioFormat.samplesPerFrame,
            mBytesPerFrame: 0,
            mChannelsPerFrame: PTTAudioFormat.channelCount,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = aacMagicCookie.withUnsafeBytes { cookie in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &description,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: cookie.count,
                magicCookie: cookie.baseAddress,
                extensions: nil,
                formatDescriptionOut: &format
            )
        }
        return status == noErr ? format : nil
    }
}

enum LiveVideoMp4WriterError: Error {
    case inputRejected
}
