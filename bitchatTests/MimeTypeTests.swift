//
// MimeTypeTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

// MARK: - MimeType Mapping and Signature Tests

struct MimeTypeTests {

    // MARK: MIME → Enum Parsing + Default Extension
    @Test(arguments: [
        ("image/jpeg", MimeType.jpeg, "jpg"),
        ("image/jpg", MimeType.jpeg, "jpg"),
        ("image/png", MimeType.png, "png"),
        ("image/gif", MimeType.gif, "gif"),
        ("image/webp", MimeType.webp, "webp"),
        ("audio/mp4", MimeType.mp4Audio, "m4a"),
        ("audio/m4a", MimeType.m4a, "m4a"),
        ("audio/aac", MimeType.aac, "m4a"),
        ("audio/mpeg", MimeType.mpeg, "mp3"),
        ("audio/mp3", MimeType.mp3, "mp3"),
        ("audio/wav", MimeType.wav, "wav"),
        ("audio/x-wav", MimeType.xWav, "wav"),
        ("audio/ogg", MimeType.ogg, "ogg"),
        ("application/pdf", MimeType.pdf, "pdf"),
        ("application/octet-stream", MimeType.octetStream, "bin")
    ])
    func mimeTypeParsingAndExtensions(
        mimeString: String,
        expectedType: MimeType,
        expectedExt: String
    ) throws {
        guard let mime = MimeType(mimeString) else {
            Issue.record("Failed to parse \(mimeString)")
            return
        }

        #expect(mime == expectedType, "Expected \(expectedType) for \(mimeString)")
        #expect(mime.mimeString == expectedType.mimeString)
        #expect(mime.defaultExtension == expectedExt)
        #expect(mime.isAllowed)
    }

    // MARK: - File Signature Validation
    @Test(arguments: [
        // === Image types ===
        (MimeType.jpeg, [0xFF, 0xD8, 0xFF]),
        (MimeType.png,  [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        (MimeType.gif,  [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]), // "GIF89a"
        (MimeType.webp, [0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
                         0x57, 0x45, 0x42, 0x50]),             // "RIFF....WEBP"

        // === Audio types ===
        (MimeType.mp3,  [0x49, 0x44, 0x33]),                   // "ID3"
        (MimeType.wav,  [0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
                         0x57, 0x41, 0x56, 0x45]),             // "RIFF....WAVE"
        (MimeType.ogg,  [0x4F, 0x67, 0x67, 0x53]),             // "OggS"

        // === Application types ===
        (MimeType.pdf,  [0x25, 0x50, 0x44, 0x46])              // "%PDF"
    ])
    func validSignatures(mime: MimeType, bytes: [UInt8]) throws {
        let data = Data(bytes)
        #expect(mime.matches(data: data),
                "Expected \(mime.mimeString) to match its signature")
    }

    // MARK: - Negative Tests
    @Test func invalidDataDoesNotMatch() throws {
        let badData = Data(repeating: 0x00, count: 16)
        for mime in MimeType.allCases where mime != .octetStream {
            #expect(!mime.matches(data: badData),
                    "Unexpectedly matched \(mime.mimeString) with zeroed data")
        }
    }

    // MARK: - Octet-stream (generic binary)
    @Test func octetStreamAlwaysMatches() throws {
        let randomData = Data([0x00, 0x11, 0x22, 0x33])
        #expect(MimeType.octetStream.matches(data: randomData),
                "application/octet-stream should always be considered valid")
    }
}
