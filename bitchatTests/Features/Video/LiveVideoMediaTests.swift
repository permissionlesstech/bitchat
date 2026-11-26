//
// LiveVideoMediaTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import bitchat

/// Synthetic media helpers: everything is generated from the test card and
/// tone, so no test touches a camera or microphone.
private enum VideoTestMedia {
    static func tempURL(_ name: String = UUID().uuidString, ext: String = "mp4") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bitchat-video-tests", isDirectory: true)
            .appendingPathComponent("\(name).\(ext)")
    }

    /// Encodes `frameCount` test-card frames at `fps` and returns the encoder
    /// output in order.
    static func encode(
        width: Int = 144,
        height: Int = 192,
        fps: Int = 12,
        bitrate: Int = 120_000,
        frameCount: Int,
        firstPtsUs: Int64 = 0,
        keyframeAt: Set<Int> = [],
        sourceWidth: Int = 480,
        sourceHeight: Int = 640
    ) throws -> [LiveVideoEncodedFrame] {
        let encoder = try LiveVideoH264Encoder(width: width, height: height, fps: fps, bitrate: bitrate, keyframeIntervalSeconds: 2)
        let source = LiveVideoSyntheticSource(width: sourceWidth, height: sourceHeight, fps: fps, audioEnabled: false)
        let collected = Collected<LiveVideoEncodedFrame>()
        encoder.onFrame = { collected.append($0) }
        for index in 0..<frameCount {
            guard let frame = source.makeFrame(index: index) else { continue }
            if keyframeAt.contains(index) { encoder.requestKeyframe() }
            encoder.encode(frame, ptsUs: firstPtsUs + Int64(index) * 1_000_000 / Int64(fps))
        }
        encoder.finish()
        encoder.invalidate()
        return collected.values
    }

    /// Raw AAC frames of the synthetic tone covering `seconds`.
    static func toneFrames(seconds: Double) -> [Data] {
        let source = LiveVideoSyntheticSource(audioEnabled: true)
        guard let encoder = PTTFrameEncoder() else { return [] }
        let chunks = Int(seconds * PTTAudioFormat.sampleRate) / Int(PTTAudioFormat.samplesPerFrame)
        var frames: [Data] = []
        for chunk in 0..<chunks {
            guard let pcm = source.makeToneBuffer(
                startSample: Int64(chunk) * Int64(PTTAudioFormat.samplesPerFrame),
                frameCount: PTTAudioFormat.samplesPerFrame
            ) else { continue }
            frames.append(contentsOf: encoder.encode(pcm))
        }
        return frames
    }

    static func writeMp4(
        _ frames: [LiveVideoEncodedFrame],
        audio: [Data] = [],
        audioStartUs: Int64 = 0,
        droppingAudio lost: Range<Int> = 0..<0,
        to url: URL
    ) -> Bool {
        let writer = LiveVideoMp4Writer(url: url, hasAudio: !audio.isEmpty)
        // Interleave by timestamp the way a live sender would.
        var audioIndex = 0
        let frameUs = LiveVideoMp4Writer.audioFrameDurationUs
        func writeAudio(through ptsUs: Int64) {
            while audioIndex < audio.count, audioStartUs + Int64(audioIndex) * frameUs <= ptsUs {
                if !lost.contains(audioIndex) {
                    writer.writeAudio(aac: audio[audioIndex], ptsUs: audioStartUs + Int64(audioIndex) * frameUs)
                }
                audioIndex += 1
            }
        }
        for frame in frames {
            writer.writeVideo(annexB: frame.annexB, ptsUs: frame.ptsUs, keyframe: frame.keyframe)
            writeAudio(through: frame.ptsUs)
        }
        writeAudio(through: .max)
        return writer.finish()
    }

    static func nalTypes(_ annexB: Data) -> [UInt8] {
        LiveVideoAVCC.nalUnits(inAnnexB: annexB).map(LiveVideoAVCC.nalType)
    }

    static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}

private final class Collected<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }

    var values: [Value] {
        lock.withLock { storage }
    }
}

struct LiveVideoAVCCTests {
    @Test func splitsThreeAndFourByteStartCodes() {
        let annexB = Data([0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0, 0, 0, 1, 0x65, 0x01, 0x00])
        let units = LiveVideoAVCC.nalUnits(inAnnexB: annexB)
        #expect(units == [Data([0x67, 0xAA]), Data([0x68, 0xBB]), Data([0x65, 0x01])])
        #expect(LiveVideoAVCC.nalUnits(inAnnexB: Data([0x65, 0x01])).isEmpty)
    }

    @Test func avccRoundTrip() {
        let units = [Data([0x65, 1, 2, 3]), Data([0x06, 9])]
        let avcc = LiveVideoAVCC.avccSample(from: units)
        #expect(avcc.prefix(4) == Data([0, 0, 0, 4]))
        #expect(LiveVideoAVCC.nalUnits(inAVCC: avcc, lengthSize: 4) == units)
        // A truncated length must not read past the buffer.
        #expect(LiveVideoAVCC.nalUnits(inAVCC: avcc.prefix(6), lengthSize: 4).isEmpty)
    }
}

struct LiveVideoH264EncoderTests {
    @Test func keyframesCarryParameterSetsAndDeltasDoNot() throws {
        let frames = try VideoTestMedia.encode(frameCount: 30)
        #expect(frames.count >= 28)
        let first = try #require(frames.first)
        #expect(first.keyframe)
        #expect(first.annexB.prefix(4) == LiveVideoAVCC.startCode)
        let keyTypes = VideoTestMedia.nalTypes(first.annexB)
        #expect(Array(keyTypes.prefix(2)) == [LiveVideoAVCC.typeSPS, LiveVideoAVCC.typePPS])
        #expect(keyTypes.contains(LiveVideoAVCC.typeIDR))

        for frame in frames.dropFirst() where !frame.keyframe {
            let types = VideoTestMedia.nalTypes(frame.annexB)
            #expect(!types.contains(LiveVideoAVCC.typeSPS))
            #expect(!types.contains(LiveVideoAVCC.typeFiller))
            #expect(types.contains(LiveVideoAVCC.typeSlice))
        }
        // Monotonic, microsecond pts straight from the input.
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.ptsUs < $1.ptsUs })
    }

    @Test func requestKeyframeForcesIDR() throws {
        let fps = 12
        let frames = try VideoTestMedia.encode(fps: fps, frameCount: 20, keyframeAt: [10])
        let forced = try #require(frames.first { $0.ptsUs == 10 * 1_000_000 / Int64(fps) })
        #expect(forced.keyframe)
        #expect(VideoTestMedia.nalTypes(forced.annexB).first == LiveVideoAVCC.typeSPS)
    }

    @Test func rejectsOddDimensions() {
        #expect(throws: LiveVideoH264Encoder.EncoderError.self) {
            try LiveVideoH264Encoder(width: 145, height: 192, fps: 8, bitrate: 18_000, keyframeIntervalSeconds: 2)
        }
    }
}

struct LiveVideoMp4WriterTests {
    @Test func encodedFramesMuxIntoPlayableMp4() async throws {
        let frames = try VideoTestMedia.encode(fps: 12, frameCount: 48)
        let url = VideoTestMedia.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(VideoTestMedia.writeMp4(frames, to: url))

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 3.5 && duration < 4.5)
        let size = try await tracks[0].load(.naturalSize)
        #expect(size == CGSize(width: 144, height: 192))
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test func aacFramesProduceDecodableAudioTrack() async throws {
        let frames = try VideoTestMedia.encode(fps: 12, frameCount: 36)
        let audio = VideoTestMedia.toneFrames(seconds: 3)
        #expect(audio.count > 40)
        let url = VideoTestMedia.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // ~0.6 s of audio lost on the mesh mid-stream: the writer must hold
        // the timeline with silence, not pull later audio early.
        #expect(VideoTestMedia.writeMp4(frames, audio: audio, droppingAudio: 15..<25, to: url))

        let asset = AVURLAsset(url: url)
        let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let audioDuration = try await audioTrack.load(.timeRange).duration.seconds
        #expect(audioDuration > 2.5 && audioDuration < 3.5)

        // The magic cookie must be good enough to decode.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        #expect(reader.startReading())
        var pcmFrames = 0
        while let sample = output.copyNextSampleBuffer() {
            pcmFrames += CMSampleBufferGetNumSamples(sample)
        }
        #expect(reader.status == .completed)
        #expect(pcmFrames > Int(PTTAudioFormat.sampleRate * 2))
    }

    @Test func waitsForKeyframeAndHoldsAcrossGaps() async throws {
        let frames = try VideoTestMedia.encode(fps: 10, frameCount: 40)
        let url = VideoTestMedia.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = LiveVideoMp4Writer(url: url, hasAudio: true)
        // Audio before the first keyframe and a leading delta are dropped.
        writer.writeAudio(aac: Data([0x21, 0x10]), ptsUs: 0)
        writer.writeVideo(annexB: frames[1].annexB, ptsUs: frames[1].ptsUs, keyframe: false)
        // Frames 10..<25 lost on the mesh; the delta after the gap is kept.
        for (index, frame) in frames.enumerated() where !(10..<25).contains(index) {
            writer.writeVideo(annexB: frame.annexB, ptsUs: frame.ptsUs, keyframe: frame.keyframe)
        }
        // Duplicate and out-of-order timestamps are ignored.
        writer.writeVideo(annexB: frames[30].annexB, ptsUs: frames[30].ptsUs, keyframe: false)
        // 25 kept; the newest is still waiting for its successor (duration).
        #expect(writer.videoSamples == 24)
        #expect(writer.finish())

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 3.5 && duration < 4.5)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var samples = 0
        var firstIsSync = false
        // Passthrough readers also emit zero-sample marker buffers; skip them.
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            if samples == 0 { firstIsSync = LiveVideoAVCC.isSync(sample) }
            samples += 1
        }
        #expect(samples == 25)
        #expect(firstIsSync)
    }

    @Test func finishWithoutVideoFails() {
        let url = VideoTestMedia.tempURL()
        let writer = LiveVideoMp4Writer(url: url, hasAudio: true)
        writer.writeAudio(aac: Data([0x21, 0x10]), ptsUs: 0)
        #expect(!writer.finish())
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

struct LiveVideoH264DecoderTests {
    @MainActor
    @Test func roundTripProducesImagesOfConfiguredSize() async throws {
        let frames = try VideoTestMedia.encode(width: 240, height: 320, fps: 12, frameCount: 24)
        var images: [CGImage] = []
        let decoder = LiveVideoH264Decoder(onFrame: { images.append($0) }, jitterMs: 50)
        decoder.configure(width: 240, height: 320)
        for frame in frames {
            decoder.submit(annexB: frame.annexB, ptsMs: frame.ptsUs / 1_000, keyframe: frame.keyframe)
        }
        decoder.finishAfterDrain()
        let deadline = Date().addingTimeInterval(10)
        while images.count < frames.count, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        decoder.stop()
        #expect(images.count == frames.count)
        #expect(decoder.framesDecoded == frames.count)
        #expect(images.allSatisfy { $0.width == 240 && $0.height == 320 })
    }

    @MainActor
    @Test func dropsDeltasUntilKeyframe() async throws {
        let frames = try VideoTestMedia.encode(fps: 12, frameCount: 12)
        var images = 0
        let decoder = LiveVideoH264Decoder(onFrame: { _ in images += 1 }, jitterMs: 0)
        decoder.configure(width: 144, height: 192)
        // Joined mid-stream: no keyframe yet, nothing must be shown.
        for frame in frames.dropFirst() where !frame.keyframe {
            decoder.submit(annexB: frame.annexB, ptsMs: frame.ptsUs / 1_000, keyframe: false)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(images == 0)
        #expect(decoder.framesDecoded == 0)

        // A keyframe starts decoding.
        decoder.submit(annexB: frames[0].annexB, ptsMs: 2_000, keyframe: true)
        let deadline = Date().addingTimeInterval(3)
        while decoder.framesDecoded < 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(decoder.framesDecoded == 1)

        // After a resync, deltas are withheld until the next keyframe.
        decoder.resyncAtKeyframe()
        decoder.submit(annexB: frames[1].annexB, ptsMs: 2_083, keyframe: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(decoder.framesDecoded == 1)
        decoder.submit(annexB: frames[0].annexB, ptsMs: 2_166, keyframe: true)
        let second = Date().addingTimeInterval(3)
        while decoder.framesDecoded < 2, Date() < second {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        decoder.stop()
        #expect(decoder.framesDecoded == 2)
    }
}

struct LiveVideoMp4SegmentsTests {
    @Test func joinHoldsDropoutAsFreeze() async throws {
        let fps = 12
        let first = try VideoTestMedia.encode(fps: fps, frameCount: 24)
        // Second segment resumes 5 s into the stream at a fresh keyframe.
        let second = try VideoTestMedia.encode(fps: fps, frameCount: 24, firstPtsUs: 5_000_000)
        let audio = VideoTestMedia.toneFrames(seconds: 2)
        let firstURL = VideoTestMedia.tempURL()
        let secondURL = VideoTestMedia.tempURL()
        let joinedURL = VideoTestMedia.tempURL()
        defer {
            for url in [firstURL, secondURL, joinedURL] { try? FileManager.default.removeItem(at: url) }
        }
        #expect(VideoTestMedia.writeMp4(first, audio: audio, to: firstURL))
        #expect(VideoTestMedia.writeMp4(second, audio: audio, audioStartUs: 5_000_000, to: secondURL))

        let joined = await LiveVideoMp4Segments.join(
            [(url: firstURL, firstVideoPtsUs: 0), (url: secondURL, firstVideoPtsUs: 5_000_000)],
            to: joinedURL
        )
        #expect(joined)
        let asset = AVURLAsset(url: joinedURL)
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 6.5 && duration < 7.5)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        // Audio keeps its place across the dropout (silence fills the gap):
        // it must run to the end of the second segment, not stop near 4 s.
        let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let audioRange = try await audioTrack.load(.timeRange)
        #expect(audioRange.end.seconds > 6.5)

        // 48 samples, and the one before the dropout spans it (a freeze).
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var durations: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            durations.append(CMSampleBufferGetDuration(sample).seconds)
        }
        #expect(durations.count == 48)
        #expect(durations.max() ?? 0 > 2.5)
    }

    @Test func joinWithNoReadableSegmentsFails() async {
        let missing = VideoTestMedia.tempURL()
        let output = VideoTestMedia.tempURL()
        #expect(!(await LiveVideoMp4Segments.join([(url: missing, firstVideoPtsUs: 0)], to: output)))
        #expect(!(await LiveVideoMp4Segments.join([], to: output)))
    }
}

struct VideoTranscoderTests {
    @Test func planFollowsBudgetAndAspect() {
        // 100 KiB over 10 s ≈ 75 kbps: audio kept, 320 long edge, 15 fps.
        let portrait = VideoTranscoder.plan(totalBits: 100 * 1024 * 8 * 0.92, duration: 10, uprightSize: CGSize(width: 1080, height: 1920), hasAudio: true)
        #expect(portrait.withAudio)
        #expect(portrait.height == 320)
        #expect(portrait.width % 16 == 0 && portrait.width == 176)
        #expect(portrait.fps == 15)
        // 60 s leaves ~12.5 kbps: no audio, small picture.
        let long = VideoTranscoder.plan(totalBits: 100 * 1024 * 8 * 0.92, duration: 60, uprightSize: CGSize(width: 1920, height: 1080), hasAudio: true)
        #expect(!long.withAudio)
        #expect(long.width == 192 && long.height % 16 == 0)
        #expect(long.fps == 6)
    }

    @Test func transcodedClipFitsBudget() async throws {
        // 3 s of 480×640 @ 24 fps with frequent keyframes and a tone. The
        // test card compresses very well, so the budget is set below the
        // source size (~50 KiB) to force a real shrink.
        let frames = try VideoTestMedia.encode(
            width: 480, height: 640, fps: 24, bitrate: 900_000, frameCount: 72,
            keyframeAt: Set(stride(from: 6, to: 72, by: 6))
        )
        let audio = VideoTestMedia.toneFrames(seconds: 3)
        let sourceURL = VideoTestMedia.tempURL()
        let outputURL = VideoTestMedia.tempURL()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputURL)
        }
        #expect(VideoTestMedia.writeMp4(frames, audio: audio, to: sourceURL))
        let maxBytes = 48 * 1024
        let sourceSize = VideoTestMedia.fileSize(sourceURL)
        #expect(sourceSize > maxBytes)

        let result = try await VideoTranscoder.transcode(source: sourceURL, output: outputURL, maxBytes: maxBytes)
        let size = VideoTestMedia.fileSize(result)
        #expect(size > 0 && size <= maxBytes)

        let asset = AVURLAsset(url: result)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let naturalSize = try await video.load(.naturalSize)
        #expect(max(naturalSize.width, naturalSize.height) <= 320)
        #expect(Int(naturalSize.width) % 16 == 0 && Int(naturalSize.height) % 16 == 0)
        #expect(naturalSize.height > naturalSize.width)
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 2.5 && duration < 3.5)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func impossibleBudgetThrowsTypedError() async throws {
        let frames = try VideoTestMedia.encode(fps: 12, frameCount: 24)
        let sourceURL = VideoTestMedia.tempURL()
        let outputURL = VideoTestMedia.tempURL()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        #expect(VideoTestMedia.writeMp4(frames, to: sourceURL))
        await #expect(throws: VideoTranscoder.TranscodeError.self) {
            try await VideoTranscoder.transcode(source: sourceURL, output: outputURL, maxBytes: 600)
        }
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }
}

struct VideoPosterLoaderTests {
    @Test func loadsPosterAndDuration() async throws {
        let frames = try VideoTestMedia.encode(fps: 12, frameCount: 24)
        let url = VideoTestMedia.tempURL()
        defer {
            VideoPosterLoader.evict(url: url)
            try? FileManager.default.removeItem(at: url)
        }
        #expect(VideoTestMedia.writeMp4(frames, to: url))
        let result = await VideoPosterLoader.load(url: url)
        let poster = try #require(result.poster)
        #expect(poster.width == 144 && poster.height == 192)
        #expect(result.durationSeconds > 1.5 && result.durationSeconds < 2.5)
        // Cached: a second call returns the same image object.
        let again = await VideoPosterLoader.load(url: url)
        #expect(again.poster === poster)
    }
}

struct LiveVideoSyntheticSourceTests {
    @MainActor
    @Test func deliversFramesAndToneOnOneClock() async throws {
        let source = LiveVideoSyntheticSource(width: 144, height: 192, fps: 20, audioEnabled: true)
        let videoPts = Collected<Int64>()
        let widths = Collected<Int>()
        let audio = Collected<(count: Int, ptsUs: Int64)>()
        source.onPixelBuffer = { buffer, ptsUs in
            widths.append(CVPixelBufferGetWidth(buffer))
            videoPts.append(ptsUs)
        }
        source.onAudioFrames = { frames, ptsUs in audio.append((frames.count, ptsUs)) }
        try await source.start()
        try await Task.sleep(nanoseconds: 700_000_000)
        source.isMuted = true
        try await Task.sleep(nanoseconds: 300_000_000)
        source.stop()

        let pts = videoPts.values
        #expect(pts.count >= 10)
        #expect(widths.values.allSatisfy { $0 == 144 })
        #expect(zip(pts, pts.dropFirst()).allSatisfy { $0 < $1 })
        let batches = audio.values
        #expect(batches.reduce(0) { $0 + $1.count } >= 8)
        // Audio timestamps advance exactly one AAC frame (64 ms) per frame.
        for (previous, next) in zip(batches, batches.dropFirst()) {
            #expect(next.ptsUs == previous.ptsUs + Int64(previous.count) * 64_000)
        }
    }

    @Test func testCardMovesBetweenFrames() throws {
        let source = LiveVideoSyntheticSource(width: 144, height: 192, fps: 8, audioEnabled: false)
        let a = try #require(source.makeFrame(index: 0))
        let b = try #require(source.makeFrame(index: 5))
        #expect(CVPixelBufferGetPixelFormatType(a) == kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        let length = CVPixelBufferGetBytesPerRow(a) * CVPixelBufferGetHeight(a)
        let same = memcmp(CVPixelBufferGetBaseAddress(a), CVPixelBufferGetBaseAddress(b), length) == 0
        #expect(!same)
    }
}
