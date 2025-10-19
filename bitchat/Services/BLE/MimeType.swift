//
// MimeType.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import UniformTypeIdentifiers

// MARK: - Extensions for missing UTTypes

extension UTType {
    static let webP = UTType(importedAs: "image/webp")
    static let aac  = UTType(importedAs: "audio/aac")
    static let m4a  = UTType(importedAs: "audio/m4a")
    static let ogg  = UTType(importedAs: "audio/ogg")
}

// MARK: - MimeType Enum

enum MimeType: CaseIterable, Hashable {
    case jpeg
    case jpg
    case png
    case gif
    case webp
    case mp4Audio
    case m4a
    case aac
    case mpeg
    case mp3
    case wav
    case xWav
    case ogg
    case pdf
    case octetStream

    var utType: UTType {
        switch self {
        case .jpeg, .jpg:   .jpeg
        case .png:          .png
        case .gif:          .gif
        case .webp:         .webP
        case .aac:          .aac
        case .m4a:          .m4a
        case .mp4Audio:     .mpeg4Audio
        case .mp3, .mpeg:   .mp3
        case .wav, .xWav:   .wav
        case .ogg:          .ogg
        case .pdf:          .pdf
        case .octetStream:  .data
        }
    }
    
    var category: Category {
        switch self {
        case .jpeg, .jpg, .png, .gif, .webp:
            return .image
        case .aac, .m4a, .mp4Audio, .mpeg, .mp3, .wav, .xWav, .ogg:
            return .audio
        case .pdf, .octetStream:
            return .file
        }
    }


    var mimeString: String {
        switch self {
        case .jpeg, .jpg:   "image/jpeg"
        case .png:          "image/png"
        case .gif:          "image/gif"
        case .webp:         "image/webp"
        case .mp4Audio:     "audio/mp4"
        case .m4a:          "audio/m4a"
        case .aac:          "audio/aac"
        case .mpeg:         "audio/mpeg"
        case .mp3:          "audio/mp3"
        case .wav:          "audio/wav"
        case .xWav:         "audio/x-wav"
        case .ogg:          "audio/ogg"
        case .pdf:          "application/pdf"
        case .octetStream:  "application/octet-stream"
        }
    }
    
    var defaultExtension: String {
        switch self {
        case .jpeg, .jpg:           "jpg"
        case .png:                  "png"
        case .webp:                 "webp"
        case .gif:                  "gif"
        case .mp4Audio, .m4a, .aac: "m4a"
        case .mpeg, .mp3:           "mp3"
        case .wav, .xWav:           "wav"
        case .ogg:                  "ogg"
        case .pdf:                  "pdf"
        case .octetStream:          "bin"
        }
    }

    static var allowed: Set<MimeType> = [
        .jpeg, .jpg, .png, .gif, .webp,
        .mp4Audio, .m4a, .aac, .mpeg, .mp3,
        .wav, .xWav, .ogg,
        .pdf, .octetStream
    ]

    var isAllowed: Bool {
        Self.allowed.contains(self)
    }

    // MARK: - Byte signature validation
    func matches(data: Data) -> Bool {
        guard !data.isEmpty else { return false }

        // Generic type → skip validation
        if self == .octetStream { return true }

        switch self {
        case .jpeg, .jpg:
            return data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF

        case .png:
            return data.count >= 8 &&
                   data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47 &&
                   data[4] == 0x0D && data[5] == 0x0A && data[6] == 0x1A && data[7] == 0x0A

        case .gif:
            return data.count >= 6 && data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46 &&
                   data[3] == 0x38 && (data[4] == 0x37 || data[4] == 0x39) && data[5] == 0x61

        case .webp:
            return data.count >= 12 &&
                   data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46 &&
                   data[8] == 0x57 && data[9] == 0x45 && data[10] == 0x42 && data[11] == 0x50

        case .m4a, .mp4Audio, .aac:
            // AVAudioRecorder output varies by platform - be lenient
            // Security: size already capped + sandboxed execution
            return data.count > 100

        case .mpeg, .mp3:
            if data.count >= 3 && data[0] == 0x49 && data[1] == 0x44 && data[2] == 0x33 {
                return true // ID3 header
            }
            return data.count >= 2 && data[0] == 0xFF && (data[1] & 0xE0) == 0xE0

        case .wav, .xWav:
            return data.count >= 12 &&
                   data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46 &&
                   data[8] == 0x57 && data[9] == 0x41 && data[10] == 0x56 && data[11] == 0x45

        case .ogg:
            return data.count >= 4 &&
                   data[0] == 0x4F && data[1] == 0x67 && data[2] == 0x67 && data[3] == 0x53

        case .pdf:
            return data.count >= 4 &&
                   data[0] == 0x25 && data[1] == 0x50 && data[2] == 0x44 && data[3] == 0x46

        default:
            return false
        }
    }

    // MARK: - Convenience Initializers

    init?(_ mimeString: String?) {
        guard let mimeString else { return nil }
        
        let normalized = mimeString.lowercased()

        // Direct match with our canonical list
        if let match = MimeType.allCases.first(where: { $0.mimeString == normalized }) {
            self = match
            return
        }

        // Let UTType normalize aliases like "image/jpg", "audio/x-wav", etc.
        if let type = UTType(mimeType: normalized),
           let match = MimeType.allCases.first(where: { type.conforms(to: $0.utType) }) {
            self = match
            return
        }

        return nil
    }
}

extension MimeType {
    enum Category: String {
        case audio, image, file
    }
}
