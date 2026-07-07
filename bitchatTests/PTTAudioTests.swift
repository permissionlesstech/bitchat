//
// PTTAudioTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import AVFoundation
import Foundation
@testable import bitchat

struct PTTAudioTests {
    // MARK: - ADTS framing

    @Test func adtsHeaderEncodesFrameLengthAndFormat() {
        let payload = Data(repeating: 0xAB, count: 100)
        let framed = ADTSFramer.frame(payload)
        #expect(framed.count == 107)

        // Syncword + MPEG-4 + layer 00 + no CRC.
        #expect(framed[0] == 0xFF)
        #expect(framed[1] == 0xF1)
        // AAC-LC (01), sampling index 8 (16 kHz), channel config 1.
        #expect(framed[2] == 0x60)
        #expect(framed[3] == 0x40 | UInt8((107 >> 11) & 0x3))
        #expect(framed[4] == UInt8((107 >> 3) & 0xFF))
        #expect(framed[5] == UInt8((107 & 0x7) << 5) | 0x1F)
        #expect(framed[6] == 0xFC)
        #expect(Data(framed.dropFirst(7)) == payload)
    }

    @Test func adtsStreamIsReadableByCoreAudio() throws {
        // A receiver persists bursts as ADTS .aac; the file must be openable
        // by the same machinery the voice-note UI uses (AVAudioFile).
        let frames = try encodeSineFrames(seconds: 0.5)
        #expect(frames.count >= 4)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptt-test-\(UUID().uuidString).aac")
        defer { try? FileManager.default.removeItem(at: url) }
        var stream = Data()
        for frame in frames {
            stream.append(ADTSFramer.frame(frame))
        }
        try stream.write(to: url)

        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 0)
    }

    // MARK: - Codec round trip

    @Test func encoderProducesRealtimeSizedFrames() throws {
        let frames = try encodeSineFrames(seconds: 1.0)
        // 1 s of 64 ms frames ≈ 15 (allow encoder priming slack).
        #expect(frames.count >= 10)
        // ~16 kbps -> ~130 bytes/frame; all frames must fit the wire budget.
        for frame in frames {
            #expect(frame.count > 0)
            #expect(frame.count < TransportConfig.pttMaxBurstContentBytes)
        }
    }

    @Test func decoderRoundTripsEncodedAudio() throws {
        let frames = try encodeSineFrames(seconds: 0.5)
        let decoder = try #require(PTTFrameDecoder())

        var decodedSamples = 0
        var energy: Float = 0
        for frame in frames {
            guard let pcm = decoder.decode(frame) else { continue } // priming
            decodedSamples += Int(pcm.frameLength)
            if let channel = pcm.floatChannelData?[0] {
                for i in 0..<Int(pcm.frameLength) {
                    energy += abs(channel[i])
                }
            }
        }
        // Most of the audio must decode, and it must not be silence.
        #expect(decodedSamples >= 4 * Int(PTTAudioFormat.samplesPerFrame))
        #expect(energy > 1)
    }

    // MARK: - Helpers

    private func encodeSineFrames(seconds: Double) throws -> [Data] {
        let encoder = try #require(PTTFrameEncoder())
        let format = try #require(PTTAudioFormat.pcmFormat)
        let totalFrames = AVAudioFrameCount(seconds * PTTAudioFormat.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames))
        buffer.frameLength = totalFrames
        let channel = try #require(buffer.floatChannelData?[0])
        for i in 0..<Int(totalFrames) {
            channel[i] = sinf(2 * .pi * 440 * Float(i) / Float(PTTAudioFormat.sampleRate)) * 0.5
        }
        return encoder.encode(buffer)
    }
}
