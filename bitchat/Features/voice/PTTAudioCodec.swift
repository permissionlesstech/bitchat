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
    private let outputBuffer: AVAudioCompressedBuffer
    private var pendingInput: [AVAudioPCMBuffer] = []
    private var pendingIndex = 0

    init?() {
        guard let pcm = PTTAudioFormat.pcmFormat,
              let aac = PTTAudioFormat.aacFormat,
              let converter = AVAudioConverter(from: pcm, to: aac)
        else { return nil }
        converter.bitRate = PTTAudioFormat.bitRate
        self.converter = converter
        self.outputBuffer = AVAudioCompressedBuffer(
            format: converter.outputFormat,
            packetCapacity: 8,
            maximumPacketSize: max(converter.maximumOutputPacketSize, 1)
        )
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
            outputBuffer.packetCount = 0
            outputBuffer.byteLength = 0
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { [weak self] _, outStatus in
                guard let self, self.pendingIndex < self.pendingInput.count else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                let next = self.pendingInput[self.pendingIndex]
                self.pendingIndex += 1
                if self.pendingIndex == self.pendingInput.count {
                    self.pendingInput.removeAll(keepingCapacity: true)
                    self.pendingIndex = 0
                }
                outStatus.pointee = .haveData
                return next
            }
            if status == .error {
                SecureLogger.error("PTT encode failed: \(error?.localizedDescription ?? "unknown")", category: .session)
                return frames
            }
            Self.appendPackets(from: outputBuffer, to: &frames)
            // .haveData means the output buffer filled and more may be ready;
            // anything else means the converter wants more input.
            if status != .haveData { return frames }
        }
    }

    private static func appendPackets(from buffer: AVAudioCompressedBuffer, to frames: inout [Data]) {
        guard buffer.packetCount > 0, let descriptions = buffer.packetDescriptions else { return }
        frames.reserveCapacity(frames.count + Int(buffer.packetCount))
        for index in 0..<Int(buffer.packetCount) {
            let description = descriptions[index]
            guard description.mDataByteSize > 0 else { continue }
            let start = buffer.data.advanced(by: Int(description.mStartOffset))
            frames.append(Data(bytes: start, count: Int(description.mDataByteSize)))
        }
    }
}

/// Streaming AAC-LC -> PCM decoder for live voice. Stateful; one instance per
/// inbound burst. Not thread-safe — confine to one queue/actor.
final class PTTFrameDecoder {
    private static let maxFrameBytes = 8 * 1024

    private let converter: AVAudioConverter
    private let pcmFormat: AVAudioFormat
    private let inputBuffer: AVAudioCompressedBuffer

    init?() {
        guard let pcm = PTTAudioFormat.pcmFormat,
              let aac = PTTAudioFormat.aacFormat,
              let converter = AVAudioConverter(from: aac, to: pcm)
        else { return nil }
        self.converter = converter
        self.pcmFormat = pcm
        self.inputBuffer = AVAudioCompressedBuffer(
            format: aac,
            packetCapacity: 1,
            maximumPacketSize: Self.maxFrameBytes
        )
    }

    /// Decodes one raw AAC frame to PCM. Returns nil for malformed input or
    /// while the decoder is still priming (the first frame of a stream).
    func decode(_ frame: Data) -> AVAudioPCMBuffer? {
        guard !frame.isEmpty, frame.count <= Self.maxFrameBytes else { return nil }

        frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            inputBuffer.data.copyMemory(from: base, byteCount: frame.count)
        }
        inputBuffer.byteLength = UInt32(frame.count)
        inputBuffer.packetCount = 1
        inputBuffer.packetDescriptions?.pointee = AudioStreamPacketDescription(
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
            return self.inputBuffer
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
