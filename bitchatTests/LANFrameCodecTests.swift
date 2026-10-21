//
// LANFrameCodecTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

struct LANFrameCodecTests {

    @Test("A frame round-trips through the length-prefixed codec")
    func roundTrip() throws {
        let payload = Data("hello bitchat".utf8)
        let frame = try LANFrameCodec.encode(payload: payload)
        #expect(frame.count == LANFrameCodec.headerLength + payload.count)

        let decoder = LANFrameDecoder()
        let frames = try decoder.append(frame)
        #expect(frames.count == 1)
        #expect(frames.first == payload)
    }

    @Test("The length prefix is big-endian and carries the payload length")
    func headerLayout() throws {
        let payload = Data([0x01, 0x02, 0x03])
        let frame = try LANFrameCodec.encode(payload: payload)
        #expect(frame[0] == 0x00)
        #expect(frame[1] == 0x00)
        #expect(frame[2] == 0x00)
        #expect(frame[3] == 0x03)
        #expect(LANFrameCodec.declaredLength(in: Data(frame.prefix(4))) == 3)
    }

    @Test("Several frames in one chunk are decoded in order")
    func multipleFrames() throws {
        let first = Data("one".utf8)
        let second = Data("two".utf8)
        let third = Data("three".utf8)
        var buffer = Data()
        buffer.append(try LANFrameCodec.encode(payload: first))
        buffer.append(try LANFrameCodec.encode(payload: second))
        buffer.append(try LANFrameCodec.encode(payload: third))

        let decoder = LANFrameDecoder()
        let frames = try decoder.append(buffer)
        #expect(frames == [first, second, third])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("A frame split across writes is only delivered when it is complete")
    func partialWrite() throws {
        let payload = Data("split frame payload".utf8)
        let frame = try LANFrameCodec.encode(payload: payload)

        let decoder = LANFrameDecoder()
        // One byte at a time: nothing is delivered before the last byte.
        for index in 0..<(frame.count - 1) {
            let chunk = Data(frame[index..<frame.count].prefix(1))
            let frames = try decoder.append(chunk)
            #expect(frames.isEmpty)
        }
        let frames = try decoder.append(Data(frame.suffix(1)))
        #expect(frames.count == 1)
        #expect(frames.first == payload)
    }

    @Test("A frame whose header is split across writes is buffered, not dropped")
    func splitHeader() throws {
        let payload = Data("x".utf8)
        let frame = try LANFrameCodec.encode(payload: payload)

        let decoder = LANFrameDecoder()
        #expect(try decoder.append(Data(frame.prefix(2))).isEmpty)
        #expect(try decoder.append(Data(frame.dropFirst(2).prefix(1))).isEmpty)
        #expect(try decoder.append(Data(frame.dropFirst(3))).count == 1)
    }

    @Test("A frame that declares more bytes than the maximum is rejected")
    func oversizedDeclaredFrame() {
        let decoder = LANFrameDecoder(maximumPayloadLength: 16)
        var header = Data([0x00, 0x00, 0x10, 0x00]) // 4096 bytes
        header.append(Data(repeating: 0x41, count: 32))

        do {
            try decoder.append(header)
            Issue.record("expected an oversized frame to be rejected")
        } catch let error as LANFrameError {
            #expect(error == .frameTooLarge(declaredLength: 4096, maximumLength: 16))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // The stream is not resynchronisable after an oversized frame.
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("Encoding a payload above the maximum fails")
    func oversizedPayload() {
        let payload = Data(repeating: 0x41, count: 33)
        do {
            _ = try LANFrameCodec.encode(payload: payload, maximumPayloadLength: 32)
            Issue.record("expected an oversized payload to be rejected")
        } catch let error as LANFrameError {
            #expect(error == .frameTooLarge(declaredLength: 33, maximumLength: 32))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("A declared length of zero yields an empty frame")
    func emptyFrame() throws {
        let decoder = LANFrameDecoder()
        let frames = try decoder.append(try LANFrameCodec.encode(payload: Data()))
        #expect(frames.count == 1)
        #expect(frames.first?.isEmpty == true)
    }
}
