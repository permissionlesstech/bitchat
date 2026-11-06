//
// LiveVideoMp4Segments.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import AVFoundation
import BitLogger
import CoreMedia
import Foundation

/// Joins recordings of one live stream that a viewer captured across
/// dropouts — the counterpart of Android's `Mp4Segments`.
///
/// Every segment comes from the same sender encoder, so samples are copied
/// without re-encoding (AVAssetReader passthrough -> AVAssetWriter
/// passthrough). Each segment is placed at its offset on the sender's clock
/// (its first video pts), and the last video sample before a dropout is given
/// a duration that reaches the next segment, so the dropout plays back as a
/// held frame. Audio is bridged with encoded silence for the same span.
///
/// Why a sample remux instead of `AVMutableComposition` + passthrough export:
/// a composition can only express the gap as an empty edit (a black/blank
/// stretch in most players) or a scaled edit (an edit list with a non-unit
/// rate, which passthrough export and Android's extractors handle poorly).
/// Extending the last sample's duration encodes the freeze in plain sample
/// timing that every player honors, with no edit lists at all.
enum LiveVideoMp4Segments {
    private struct Sample {
        let buffer: CMSampleBuffer
        let isVideo: Bool
        /// First pts of the buffer, on the joined timeline once placed.
        let ptsUs: Int64
        /// End of the buffer's last sample (pts + duration), same timeline.
        let endUs: Int64
        /// Offset added to the buffer's own timestamps when it is written.
        var shiftUs: Int64 = 0
    }

    /// `segments` pairs each file with its first video timestamp on the
    /// sender's clock (microseconds). Returns false when nothing usable was
    /// read or the output could not be written.
    static func join(_ segments: [(url: URL, firstVideoPtsUs: Int64)], to output: URL) async -> Bool {
        guard !segments.isEmpty else { return false }
        var loaded: [(asset: AVURLAsset, tracks: SegmentTracks, firstPtsUs: Int64)] = []
        for (url, firstPtsUs) in segments {
            let asset = AVURLAsset(url: url)
            guard let tracks = await loadTracks(asset) else {
                SecureLogger.debug("Live video: skipping unreadable segment", category: .session)
                continue
            }
            loaded.append((asset, tracks, firstPtsUs))
        }
        guard !loaded.isEmpty else { return false }
        let baseUs = segments[0].firstVideoPtsUs
        // Reading and writing block on the media pipeline (and poll writer
        // readiness), so they run on a dispatch queue, not the async pool.
        let segmentsToJoin = loaded
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: joinSynchronously(segmentsToJoin, baseUs: baseUs, to: output))
            }
        }
    }

    private struct SegmentTracks {
        let video: AVAssetTrack
        let videoFormat: CMFormatDescription?
        let audio: AVAssetTrack?
        let audioFormat: CMFormatDescription?
    }

    private static func loadTracks(_ asset: AVURLAsset) async -> SegmentTracks? {
        guard let video = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let audio = try? await asset.loadTracks(withMediaType: .audio).first
        let videoFormat = try? await video.load(.formatDescriptions).first
        var audioFormat: CMFormatDescription?
        if let audio {
            audioFormat = try? await audio.load(.formatDescriptions).first
        }
        return SegmentTracks(video: video, videoFormat: videoFormat, audio: audio, audioFormat: audioFormat)
    }

    private static func joinSynchronously(
        _ segments: [(asset: AVURLAsset, tracks: SegmentTracks, firstPtsUs: Int64)],
        baseUs: Int64,
        to output: URL
    ) -> Bool {
        var videoFormat: CMFormatDescription?
        var audioFormat: CMFormatDescription?
        var samples: [Sample] = []
        var lastEndUs: Int64 = -1

        for (asset, tracks, firstPtsUs) in segments {
            guard let segment = readSegment(asset, tracks: tracks), !segment.isEmpty else {
                SecureLogger.debug("Live video: skipping unreadable segment", category: .session)
                continue
            }
            if videoFormat == nil { videoFormat = tracks.videoFormat }
            if audioFormat == nil { audioFormat = tracks.audioFormat }
            // Rebase the segment to its own start, place it on the sender's
            // clock, and never let it overlap the previous one.
            let segmentStart = segment.map(\.ptsUs).min() ?? 0
            let offsetUs = max(firstPtsUs - baseUs, lastEndUs + 1)
            let shiftUs = offsetUs - segmentStart
            var segmentEnd = offsetUs
            for sample in segment {
                samples.append(Sample(
                    buffer: sample.buffer,
                    isVideo: sample.isVideo,
                    ptsUs: sample.ptsUs + shiftUs,
                    endUs: sample.endUs + shiftUs,
                    shiftUs: shiftUs
                ))
                // Video sample durations are re-derived when writing, so only
                // a video sample's start bounds the segment; audio counts in full.
                segmentEnd = max(segmentEnd, sample.isVideo ? sample.ptsUs + shiftUs : sample.endUs + shiftUs)
            }
            lastEndUs = segmentEnd
        }
        guard let videoFormat, samples.contains(where: \.isVideo) else { return false }
        samples.sort { $0.ptsUs < $1.ptsUs }
        return write(samples, videoFormat: videoFormat, audioFormat: audioFormat, to: output)
    }

    /// Reads every compressed sample of the segment. Each track gets its own
    /// reader, so draining video first can never stall on unread audio.
    private static func readSegment(_ asset: AVURLAsset, tracks: SegmentTracks) -> [Sample]? {
        guard let video = readTrack(asset, track: tracks.video, isVideo: true) else { return nil }
        let audio = tracks.audio.flatMap { readTrack(asset, track: $0, isVideo: false) } ?? []
        return video + audio
    }

    private static func readTrack(_ asset: AVURLAsset, track: AVAssetTrack, isVideo: Bool) -> [Sample]? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        // Passthrough (nil settings): compressed samples, attachments intact.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var samples: [Sample] = []
        while let buffer = output.copyNextSampleBuffer() {
            // Passthrough readers also emit zero-sample marker buffers.
            guard CMSampleBufferGetNumSamples(buffer) > 0 else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard pts.isNumeric else { continue }
            let duration = CMSampleBufferGetDuration(buffer)
            let ptsUs = microseconds(pts)
            let endUs = duration.isNumeric ? ptsUs + microseconds(duration) : ptsUs
            samples.append(Sample(buffer: buffer, isVideo: isVideo, ptsUs: ptsUs, endUs: endUs))
        }
        guard reader.status != .failed else { return nil }
        return samples
    }

    private static func microseconds(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
    }

    private static func write(
        _ samples: [Sample],
        videoFormat: CMFormatDescription,
        audioFormat: CMFormatDescription?,
        to output: URL
    ) -> Bool {
        try? FileManager.default.removeItem(at: output)
        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else { return false }
        // Samples arrive already sorted by time, so the writer's own
        // interleaving gate only gets in the way: across a dropout one track
        // has nothing to offer for seconds, and a non-real-time input would
        // stall waiting for it. Real-time inputs skip that gate.
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if let audioFormat {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }
        guard writer.startWriting() else { return false }
        let firstUs = samples[0].ptsUs
        writer.startSession(atSourceTime: CMTime(value: firstUs, timescale: 1_000_000))

        let videoSamples = samples.filter(\.isVideo)
        var nextVideoPts: [Int: Int64] = [:]
        for index in videoSamples.indices.dropLast() {
            nextVideoPts[index] = videoSamples[index + 1].ptsUs
        }
        var videoIndex = 0
        var lastVideoDuration: Int64 = 66_666
        var lastPts: [Bool: Int64] = [true: .min, false: .min]
        var endUs = firstUs
        var wroteVideo = false
        var nextAudioUs: Int64?
        // Silence filler only fits the live format (AAC-LC 16 kHz mono).
        let silence = audioFormat.flatMap { isLiveAudioFormat($0) ? LiveVideoMp4Writer.silentAACFrame : nil }

        for sample in samples {
            guard sample.ptsUs > lastPts[sample.isVideo, default: .min] else {
                if sample.isVideo { videoIndex += 1 }
                continue
            }
            let input: AVAssetWriterInput
            // Shift every entry by the segment offset: passthrough audio
            // buffers carry several AAC packets, each with its own timing.
            var timings = timingEntries(of: sample.buffer).map { entry -> CMSampleTimingInfo in
                var shifted = entry
                shifted.presentationTimeStamp = shift(entry.presentationTimeStamp, byUs: sample.shiftUs)
                shifted.decodeTimeStamp = shift(entry.decodeTimeStamp, byUs: sample.shiftUs)
                return shifted
            }
            guard !timings.isEmpty else { continue }
            if sample.isVideo {
                input = videoInput
                // Held frame: a video sample lasts until the next one, which
                // spans any dropout between segments.
                if let next = nextVideoPts[videoIndex], next > sample.ptsUs {
                    lastVideoDuration = next - sample.ptsUs
                }
                if timings.count == 1 {
                    timings[0].duration = CMTime(value: lastVideoDuration, timescale: 1_000_000)
                }
                videoIndex += 1
            } else {
                guard let audioInput else { continue }
                input = audioInput
                // The writer packs audio back to back, so a dropout between
                // segments must be held with silence or the later segment's
                // audio would play early against its picture.
                if let expectedStart = nextAudioUs, let silence, let audioFormat {
                    let frameUs = LiveVideoMp4Writer.audioFrameDurationUs
                    var expected = expectedStart
                    var inserted = 0
                    while sample.ptsUs - expected >= frameUs / 2, inserted < maxSilenceFrames {
                        guard let filler = LiveVideoMp4Writer.audioSample(silence, ptsUs: expected, format: audioFormat),
                              waitUntilReady(audioInput, writer: writer),
                              audioInput.append(filler)
                        else { break }
                        expected += frameUs
                        inserted += 1
                    }
                }
            }
            var retimed: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sample.buffer,
                sampleTimingEntryCount: timings.count,
                sampleTimingArray: &timings,
                sampleBufferOut: &retimed
            ) == noErr, let retimed else { continue }
            guard waitUntilReady(input, writer: writer), input.append(retimed) else {
                if writer.status == .failed { break }
                continue
            }
            lastPts[sample.isVideo] = sample.ptsUs
            if sample.isVideo { wroteVideo = true }
            let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(retimed), CMSampleBufferGetDuration(retimed))
            if end.isNumeric {
                let bufferEndUs = microseconds(end)
                endUs = max(endUs, bufferEndUs)
                if !sample.isVideo { nextAudioUs = bufferEndUs }
            }
        }

        guard wroteVideo, writer.status == .writing else {
            SecureLogger.error("Live video: segment join failed: \(writer.error?.localizedDescription ?? "no video")", category: .session)
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            return false
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: endUs, timescale: 1_000_000))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            return false
        }
        return true
    }

    /// Longest dropout bridged with silence (~2 min, beyond the 90 s at which
    /// a silent stream closes).
    private static let maxSilenceFrames = 2_000

    private static func isLiveAudioFormat(_ format: CMFormatDescription) -> Bool {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return false }
        return asbd.mFormatID == kAudioFormatMPEG4AAC
            && asbd.mSampleRate == PTTAudioFormat.sampleRate
            && asbd.mChannelsPerFrame == PTTAudioFormat.channelCount
    }

    private static func timingEntries(of buffer: CMSampleBuffer) -> [CMSampleTimingInfo] {
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0
        else { return [] }
        var entries = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &entries, entriesNeededOut: &count) == noErr else {
            return []
        }
        return entries
    }

    private static func shift(_ time: CMTime, byUs shiftUs: Int64) -> CMTime {
        guard time.isNumeric else { return time }
        return CMTimeAdd(time, CMTime(value: shiftUs, timescale: 1_000_000))
    }

    private static func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return true
    }
}
