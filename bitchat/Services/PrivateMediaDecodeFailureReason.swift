//
// PrivateMediaDecodeFailureReason.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// People-visible reasons when authenticated private media fails locally (#1518).
enum PrivateMediaDecodeFailureReason: Equatable {
    case malformedPayload
    case payloadTooLarge(bytes: Int)
    case unsupportedMime(mimeType: String?)
    case magicMismatch(mime: String, prefixHex: String)

    var logLabel: String {
        switch self {
        case .malformedPayload:
            return "malformed_payload"
        case .payloadTooLarge(let bytes):
            return "payload_too_large:\(bytes)"
        case .unsupportedMime(let mimeType):
            return "unsupported_mime:\(mimeType ?? "<empty>")"
        case .magicMismatch(let mime, let prefixHex):
            return "magic_mismatch:\(mime):\(prefixHex)"
        }
    }

    var localizedSystemMessage: String {
        switch self {
        case .malformedPayload:
            return String(
                localized: "media.decode.failure.malformed",
                defaultValue: "couldn't open the media file — the payload didn't decode. if this arrived from Android, see docs/ANDROID-IOS-MEDIA-INTEROP.md.",
                comment: "System message when a private media payload fails to decode"
            )
        case .payloadTooLarge:
            return String(
                localized: "media.decode.failure.too_large",
                defaultValue: "couldn't save the media file — it exceeds this device's size limit.",
                comment: "System message when an incoming media file is too large"
            )
        case .unsupportedMime(let mimeType):
            return String(
                format: String(
                    localized: "media.decode.failure.unsupported_mime",
                    defaultValue: "couldn't open the media file — unsupported type (%@).",
                    comment: "System message when MIME type is unsupported; %@ is the MIME"
                ),
                locale: .current,
                mimeType ?? "unknown"
            )
        case .magicMismatch(let mime, _):
            return String(
                format: String(
                    localized: "media.decode.failure.magic_mismatch",
                    defaultValue: "couldn't open the media file — contents don't match the declared type (%@).",
                    comment: "System message when file magic bytes mismatch MIME; %@ is the MIME"
                ),
                locale: .current,
                mime
            )
        }
    }

    static func from(_ failure: BLEIncomingFileRejection) -> PrivateMediaDecodeFailureReason {
        switch failure {
        case .malformedPayload:
            return .malformedPayload
        case .payloadTooLarge(let bytes):
            return .payloadTooLarge(bytes: bytes)
        case .unsupportedMime(let mimeType, _):
            return .unsupportedMime(mimeType: mimeType)
        case .magicMismatch(let mime, _, let prefixHex):
            return .magicMismatch(mime: mime.rawValue, prefixHex: prefixHex)
        }
    }
}
