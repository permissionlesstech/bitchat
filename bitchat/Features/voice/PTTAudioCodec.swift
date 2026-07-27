//
// PTTAudioCodec.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import AVFoundation
import BitLogger
import Foundation

/// Streaming PCM -> AAC-LC encoder for live voice. Stateful (the AAC encoder
/// carries a bit reservoir across frames); one instance per burst.
/// Not thread-safe — confine to one queue.
final class PTTFrameEncoder {
    private let converter: AVAudioConverter
    private var pendingInput: [AVAudioPCMBuffer] = []

    init?() {
        guard let pcm = PTTAudioFormat.pcmFormat,
              let aac = PTTAudioFormat.aacFormat,
              let converter = AVAudioConverter(from: pcm, to: aac)
        else { return nil }
        converter.bitRate = PTTAudioFormat.bitRate
        self.converter = converter
    }

    /// Feeds PCM (16 kHz mono float) and returns every complete AAC frame the
    /// encoder produced. Frames come out ~130 bytes each at 16 kbps.
    func encode(_ buffer: AVAudioPCMBuffer) -> [Data] {
        pendingInput.append(buffer)
        return drainConverter()
    }

    private func drainConverter() -> [Data] {
        var frames: [Data] = []
        while true {
            let output = AVAudioCompressedBuffer(
                format: converter.outputFormat,
                packetCapacity: 8,
                maximumPacketSize: max(converter.maximumOutputPacketSize, 1)
            )
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { [weak self] _, outStatus in
                guard let self, let next = self.pendingInput.first else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                self.pendingInput.removeFirst()
                outStatus.pointee = .haveData
                return next
            }
            if status == .error {
                SecureLogger.error("PTT encode failed: \(error?.localizedDescription ?? "unknown")", category: .session)
                return frames
            }
            frames.append(contentsOf: Self.extractPackets(from: output))
            // .haveData means the output buffer filled and more may be ready;
            // anything else means the converter wants more input.
            if status != .haveData { return frames }
        }
    }

    private static func extractPackets(from buffer: AVAudioCompressedBuffer) -> [Data] {
        guard buffer.packetCount > 0, let descriptions = buffer.packetDescriptions else { return [] }
        var frames: [Data] = []
        frames.reserveCapacity(Int(buffer.packetCount))
        for index in 0..<Int(buffer.packetCount) {
            let description = descriptions[index]
            guard description.mDataByteSize > 0 else { continue }
            let start = buffer.data.advanced(by: Int(description.mStartOffset))
            frames.append(Data(bytes: start, count: Int(description.mDataByteSize)))
        }
        return frames
    }
}

/// Streaming AAC-LC -> PCM decoder for live voice. Stateful; one instance per
/// inbound burst. Not thread-safe — confine to one queue/actor.
final class PTTFrameDecoder {
    private let converter: AVAudioConverter
    private let pcmFormat: AVAudioFormat
    private let aacFormat: AVAudioFormat

    init?() {
        guard let pcm = PTTAudioFormat.pcmFormat,
              let aac = PTTAudioFormat.aacFormat,
              let converter = AVAudioConverter(from: aac, to: pcm)
        else { return nil }
        self.converter = converter
        self.pcmFormat = pcm
        self.aacFormat = aac
    }

    /// Decodes one raw AAC frame to PCM. Returns nil for malformed input or
    /// while the decoder is still priming (the first frame of a stream).
    func decode(_ frame: Data) -> AVAudioPCMBuffer? {
        guard !frame.isEmpty, frame.count <= 8 * 1024 else { return nil }

        let input = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 1, maximumPacketSize: frame.count)
        frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            input.data.copyMemory(from: base, byteCount: frame.count)
        }
        input.byteLength = UInt32(frame.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(frame.count)
        )

        guard let output = AVAudioPCMBuffer(
            pcmFormat: pcmFormat,
            frameCapacity: PTTAudioFormat.samplesPerFrame * 2
        ) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error else {
            SecureLogger.debug("PTT decode failed: \(error?.localizedDescription ?? "unknown")", category: .session)
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }
}

/// Sample-rate/channel converter from the microphone's native format to the
/// 16 kHz mono processing format. Stateful; not thread-safe.
final class PTTInputResampler {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    init?(inputFormat: AVAudioFormat) {
        guard let pcm = PTTAudioFormat.pcmFormat,
              let converter = AVAudioConverter(from: inputFormat, to: pcm)
        else { return nil }
        self.converter = converter
        self.outputFormat = pcm
        self.ratio = PTTAudioFormat.sampleRate / inputFormat.sampleRate
    }

    func resample(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            SecureLogger.debug("PTT resample failed: \(error?.localizedDescription ?? "unknown")", category: .session)
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }
}
