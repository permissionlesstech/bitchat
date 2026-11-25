//
// WaveformTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import AVFoundation
import Foundation
import Testing

@testable import bitchat

@Suite("Waveform & Audio Ingest Hardening Tests")
struct WaveformTests {
    @Test("Crafted CAF claiming 2^40 data bytes does not crash waveform extraction and is rejected at ingest")
    func craftedGiantCAFRejectedWithoutCrash() throws {
        let cafData = makeCraftedCAF(claimedDataBytes: Int64(1) << 40)
        #expect(cafData.count < 512)

        // 1. Direct waveform extraction must refuse out-of-range frame counts cleanly instead of trapping.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("crafted-giant-\(UUID().uuidString).m4a")
        try cafData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        #expect(WaveformCache.computeWaveform(url: tempURL, bins: 64) == nil)

        // 2. Ingest validator must reject CAF disguised as any audio MIME type.
        for mimeType in ["audio/mp4", "audio/m4a", "audio/aac", "audio/wav", "audio/mpeg"] {
            let packet = BitchatFilePacket(
                fileName: "voice_crafted.m4a",
                fileSize: UInt64(cafData.count),
                mimeType: mimeType,
                content: cafData
            )
            let encoded = try #require(packet.encode())
            let result = BLEIncomingFileValidator.validate(payload: encoded)
            guard case .failure(.magicMismatch) = result else {
                Issue.record("Expected magicMismatch for CAF with \(mimeType), got \(result)")
                return
            }
        }
    }

    @Test("Crafted WAV declaring an oversized duration is rejected at ingest and by WaveformCache")
    func craftedGiantWAVRejected() throws {
        // Valid RIFF/WAVE at 10 Hz mono 16-bit PCM carrying 7,000 samples (700s > 600s cap)
        // in only ~14 KiB of payload.
        let sampleCount = 7_000
        let wavData = makeCraftedWAV(sampleRate: 10, sampleCount: sampleCount)

        let packet = BitchatFilePacket(
            fileName: "voice_huge.wav",
            fileSize: UInt64(wavData.count),
            mimeType: "audio/wav",
            content: wavData
        )
        let encoded = try #require(packet.encode())
        let result = BLEIncomingFileValidator.validate(payload: encoded)
        guard case .failure(.invalidAudio(let mime, _, _)) = result else {
            Issue.record("Expected invalidAudio for oversized WAV, got \(result)")
            return
        }
        #expect(mime == .wav)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("crafted-huge-\(UUID().uuidString).wav")
        try wavData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        #expect(WaveformCache.computeWaveform(url: tempURL, bins: 64) == nil)
    }

    @Test("Unparseable ftyp prefix garbage is rejected by audio ingest validator")
    func unparseableFtypGarbageRejected() throws {
        let fakeM4A = Data([0x00, 0x00, 0x00, 0x18])
            + Data("ftypM4A ".utf8)
            + Data(repeating: 0x00, count: 12)
            + Data(repeating: 0x42, count: 256)
        let packet = BitchatFilePacket(
            fileName: "voice_fake.m4a",
            fileSize: UInt64(fakeM4A.count),
            mimeType: "audio/mp4",
            content: fakeM4A
        )
        let encoded = try #require(packet.encode())
        let result = BLEIncomingFileValidator.validate(payload: encoded)
        guard case .failure(.invalidAudio(let mime, _, _)) = result else {
            Issue.record("Expected invalidAudio for truncated/fake M4A, got \(result)")
            return
        }
        #expect(mime == .mp4Audio)
    }

    @Test("Valid M4A passes audio ingest validation and produces normalized waveform across multiple read chunks")
    func validM4APassesIngestAndChunkedWaveform() throws {
        // 1.2 seconds at 16 kHz = 19,200 frames (> 8,192 chunk capacity), exercising multi-chunk reads.
        let m4aURL = try makeValidM4A(durationSeconds: 1.2)
        defer { try? FileManager.default.removeItem(at: m4aURL) }

        let data = try Data(contentsOf: m4aURL)
        let packet = BitchatFilePacket(
            fileName: "voice_valid.m4a",
            fileSize: UInt64(data.count),
            mimeType: "audio/mp4",
            content: data
        )
        let encoded = try #require(packet.encode())
        let result = BLEIncomingFileValidator.validate(payload: encoded)
        guard case .success(let acceptance) = result else {
            Issue.record("Expected valid M4A to pass ingest, got \(result)")
            return
        }
        #expect(acceptance.mime == .mp4Audio)

        let bins = try #require(WaveformCache.computeWaveform(url: m4aURL, bins: 32))
        #expect(bins.count == 32)
        #expect(bins.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1.0 })
        #expect((bins.max() ?? 0) > 0.5)
    }

    // MARK: - Fixtures

    /// Minimal Apple CAF header (big-endian) with a Linear PCM `desc` chunk and a `data` chunk
    /// claiming `claimedDataBytes` while carrying only a handful of actual payload bytes.
    private func makeCraftedCAF(claimedDataBytes: Int64) -> Data {
        var data = Data()
        // File header: "caff" + version (1) + flags (0)
        data.append(contentsOf: Array("caff".utf8))
        appendBE(&data, UInt16(1))
        appendBE(&data, UInt16(0))

        // Audio Description chunk ("desc", 32 bytes): 16 kHz, lpcm, 2 bytes/packet, 1 frame/packet, 1 ch, 16-bit
        data.append(contentsOf: Array("desc".utf8))
        appendBE(&data, Int64(32))
        appendBE(&data, Float64(16_000).bitPattern) // mSampleRate
        data.append(contentsOf: Array("lpcm".utf8)) // mFormatID
        appendBE(&data, UInt32(0))                  // mFormatFlags
        appendBE(&data, UInt32(2))                  // mBytesPerPacket
        appendBE(&data, UInt32(1))                  // mFramesPerPacket
        appendBE(&data, UInt32(1))                  // mChannelsPerFrame
        appendBE(&data, UInt32(16))                 // mBitsPerChannel

        // Audio Data chunk ("data"): editCount (4 bytes) + claimed data bytes
        data.append(contentsOf: Array("data".utf8))
        appendBE(&data, claimedDataBytes)
        appendBE(&data, UInt32(0)) // mEditCount
        data.append(Data(repeating: 0, count: 200))
        return data
    }

    private func makeCraftedWAV(sampleRate: UInt32, sampleCount: Int) -> Data {
        let dataBytes = UInt32(sampleCount * 2)
        var data = Data()
        // RIFF header
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(&data, dataBytes &+ 36)
        data.append(contentsOf: Array("WAVE".utf8))

        // fmt chunk (16 bytes, PCM, mono, 16-bit)
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE(&data, UInt32(16))
        appendLE(&data, UInt16(1))                // PCM
        appendLE(&data, UInt16(1))                // mono
        appendLE(&data, sampleRate)
        appendLE(&data, sampleRate * 2)           // byte rate
        appendLE(&data, UInt16(2))                // block align
        appendLE(&data, UInt16(16))               // bits per sample

        // data chunk
        data.append(contentsOf: Array("data".utf8))
        appendLE(&data, dataBytes)
        data.append(Data(repeating: 0, count: Int(dataBytes)))
        return data
    }

    private func makeValidM4A(durationSeconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("valid-waveform-\(UUID().uuidString).m4a")
        let pcmFormat = try #require(PTTAudioFormat.pcmFormat)
        let frameCount = AVAudioFrameCount(durationSeconds * PTTAudioFormat.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(frameCount) {
                let phase = 2.0 * Float.pi * 440.0 * Float(index) / Float(PTTAudioFormat.sampleRate)
                channel[index] = 0.5 * sinf(phase)
            }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: PTTAudioFormat.voiceNoteFileSettings)
            try file.write(from: buffer)
        }
        return url
    }

    private func appendBE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
