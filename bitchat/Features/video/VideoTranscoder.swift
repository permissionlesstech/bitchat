//
// VideoTranscoder.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import AVFoundation
import BitLogger
import CoreMedia
import Foundation

/// Re-encodes a recorded clip or gallery video into a small H.264/AAC MP4
/// that fits one mesh file transfer — the counterpart of Android's
/// `VideoTranscoder`.
///
/// The bitrate comes from the duration and byte budget; resolution and frame
/// rate follow the bitrate; the upright aspect ratio is kept in 16-pixel
/// blocks (long edge at most 320). Sources longer than 60 s are trimmed.
/// Audio is dropped when the budget cannot afford intelligible speech next to
/// the picture. If the first result is still too big, one retry runs at a
/// bitrate scaled down by the overshoot.
enum VideoTranscoder {
    enum TranscodeError: Error, Equatable {
        case noVideoTrack
        case readerFailed(String)
        case writerFailed(String)
        /// Even the retry exceeded the budget.
        case doesNotFit(bytes: Int, maxBytes: Int)
    }

    static let maxSourceDuration: Double = 60
    private static let audioBitrate = 12_000
    private static let audioMinimumTotalBitrate = 30_000
    private static let containerHeadroom = 0.92
    private static let maxAttempts = 2
    private static let maxLongEdge = 320

    struct Plan: Equatable {
        let width: Int
        let height: Int
        let fps: Int
        let videoBitrate: Int
        let withAudio: Bool
    }

    @discardableResult
    static func transcode(source: URL, output: URL, maxBytes: Int = 100 * 1024) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw TranscodeError.noVideoTrack
        }
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        let (naturalSize, transform) = try await videoTrack.load(.naturalSize, .preferredTransform)
        let assetDuration = try await asset.load(.duration)
        let sourceDuration = assetDuration.seconds
        let duration = min(max(sourceDuration.isFinite ? sourceDuration : maxSourceDuration, 0.5), maxSourceDuration)
        let upright = CGRect(origin: .zero, size: naturalSize).applying(transform).size
        let uprightSize = CGSize(width: abs(upright.width), height: abs(upright.height))

        var totalBits = Double(maxBytes) * 8 * containerHeadroom
        var lastSize = 0
        for attempt in 1...maxAttempts {
            let plan = plan(totalBits: totalBits, duration: duration, uprightSize: uprightSize, hasAudio: audioTrack != nil)
            let job = Job(
                asset: asset,
                videoTrack: videoTrack,
                audioTrack: plan.withAudio ? audioTrack : nil,
                naturalSize: naturalSize,
                transform: transform,
                assetDuration: assetDuration,
                duration: duration,
                plan: plan,
                output: output
            )
            try await job.run()
            let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? Int.max
            SecureLogger.info("Video transcode attempt \(attempt): \(plan.width)x\(plan.height)@\(plan.fps) \(plan.videoBitrate) bps -> \(size) B", category: .session)
            if size <= maxBytes { return output }
            lastSize = size
            totalBits *= Double(maxBytes) / Double(size) * 0.9
        }
        try? FileManager.default.removeItem(at: output)
        throw TranscodeError.doesNotFit(bytes: lastSize, maxBytes: maxBytes)
    }

    static func plan(totalBits: Double, duration: Double, uprightSize: CGSize, hasAudio: Bool) -> Plan {
        let totalBps = Int(totalBits / max(duration, 0.5))
        let withAudio = hasAudio && totalBps >= audioMinimumTotalBitrate
        let videoBps = min(max(totalBps - (withAudio ? audioBitrate : 0), 6_000), 600_000)
        let longSide = videoBps >= 60_000 ? maxLongEdge : 192
        let fps: Int
        switch videoBps {
        case 120_000...: fps = 24
        case 40_000...: fps = 15
        case 18_000...: fps = 10
        default: fps = 6
        }
        let aspect = uprightSize.width / max(uprightSize.height, 1)
        let width: Int
        let height: Int
        if aspect >= 1 {
            width = longSide
            height = roundTo16(Double(longSide) / aspect)
        } else {
            width = roundTo16(Double(longSide) * aspect)
            height = longSide
        }
        return Plan(width: width, height: height, fps: fps, videoBitrate: videoBps, withAudio: withAudio)
    }

    private static func roundTo16(_ value: Double) -> Int {
        max(64, Int((value / 16).rounded()) * 16)
    }

    // MARK: - One encode pass

    /// AVAssetReader (upright, scaled, frame-rate-limited through a video
    /// composition) -> AVAssetWriter (H.264 Baseline + optional AAC).
    private struct Job {
        let asset: AVURLAsset
        let videoTrack: AVAssetTrack
        let audioTrack: AVAssetTrack?
        let naturalSize: CGSize
        let transform: CGAffineTransform
        let assetDuration: CMTime
        let duration: Double
        let plan: Plan
        let output: URL

        func run() async throws {
            try? FileManager.default.removeItem(at: output)
            let reader: AVAssetReader
            let writer: AVAssetWriter
            do {
                reader = try AVAssetReader(asset: asset)
                writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
            } catch {
                throw TranscodeError.readerFailed(error.localizedDescription)
            }
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))

            let videoOutput = AVAssetReaderVideoCompositionOutput(
                videoTracks: [videoTrack],
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            videoOutput.videoComposition = makeComposition()
            videoOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOutput) else { throw TranscodeError.readerFailed("video output rejected") }
            reader.add(videoOutput)

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings())
            videoInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoInput) else { throw TranscodeError.writerFailed("video input rejected") }
            writer.add(videoInput)

            var audioOutput: AVAssetReaderTrackOutput?
            var audioInput: AVAssetWriterInput?
            if let audioTrack {
                let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: PTTAudioFormat.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ])
                output.alwaysCopiesSampleData = false
                let settings = audioSettings(writer: writer)
                if reader.canAdd(output), let settings {
                    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                    input.expectsMediaDataInRealTime = false
                    if writer.canAdd(input) {
                        reader.add(output)
                        writer.add(input)
                        audioOutput = output
                        audioInput = input
                    }
                }
            }

            guard reader.startReading() else {
                throw TranscodeError.readerFailed(reader.error?.localizedDescription ?? "startReading")
            }
            guard writer.startWriting() else {
                reader.cancelReading()
                throw TranscodeError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
            }
            writer.startSession(atSourceTime: .zero)

            let endTime = CMTime(seconds: duration, preferredTimescale: 600)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                pump(output: videoOutput, into: videoInput, label: "video", endTime: endTime, group: group)
                if let audioOutput, let audioInput {
                    pump(output: audioOutput, into: audioInput, label: "audio", endTime: endTime, group: group)
                }
                group.notify(queue: .global(qos: .utility)) { continuation.resume() }
            }

            if reader.status == .failed {
                writer.cancelWriting()
                throw TranscodeError.readerFailed(reader.error?.localizedDescription ?? "read")
            }
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw TranscodeError.writerFailed(writer.error?.localizedDescription ?? "finish")
            }
        }

        /// Upright frames at the planned size and frame rate: the composition
        /// applies `preferredTransform`, then scales to fill and center-crops.
        private func makeComposition() -> AVMutableVideoComposition {
            let target = CGSize(width: plan.width, height: plan.height)
            let rotated = CGRect(origin: .zero, size: naturalSize).applying(transform)
            let upright = CGSize(width: abs(rotated.width), height: abs(rotated.height))
            let scale = max(target.width / max(upright.width, 1), target.height / max(upright.height, 1))
            let placement = transform
                .concatenating(CGAffineTransform(translationX: -rotated.minX, y: -rotated.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(
                    translationX: (target.width - upright.width * scale) / 2,
                    y: (target.height - upright.height * scale) / 2
                ))

            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(placement, at: .zero)
            let instruction = AVMutableVideoCompositionInstruction()
            // Must span the whole source timeline, not just the trimmed part.
            instruction.timeRange = CMTimeRange(start: .zero, duration: assetDuration)
            instruction.layerInstructions = [layer]

            let composition = AVMutableVideoComposition()
            composition.renderSize = target
            composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(plan.fps))
            composition.instructions = [instruction]
            return composition
        }

        private func videoSettings() -> [String: Any] {
            [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: plan.width,
                AVVideoHeightKey: plan.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: plan.videoBitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: plan.fps * 3,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoExpectedSourceFrameRateKey: plan.fps
                ]
            ]
        }

        /// AAC-LC mono 16 kHz at ~12 kbps, or the PTT bitrate if the encoder
        /// refuses one that low.
        private func audioSettings(writer: AVAssetWriter) -> [String: Any]? {
            for bitrate in [VideoTranscoder.audioBitrate, PTTAudioFormat.bitRate] {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: PTTAudioFormat.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: bitrate
                ]
                if writer.canApply(outputSettings: settings, forMediaType: .audio) { return settings }
            }
            return nil
        }

        /// Copies samples until the reader runs dry (or past the trim point),
        /// driven by the input's own readiness callback; leaves `group` once
        /// the track is done.
        private func pump(
            output: AVAssetReaderOutput,
            into input: AVAssetWriterInput,
            label: String,
            endTime: CMTime,
            group: DispatchGroup
        ) {
            group.enter()
            let queue = DispatchQueue(label: "chat.bitchat.video.transcode.\(label)")
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(),
                          CMSampleBufferGetPresentationTimeStamp(sample) < endTime,
                          input.append(sample)
                    else {
                        finished = true
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
    }
}
