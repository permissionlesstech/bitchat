//
// PrivateMediaDecodeFailureReasonTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
@testable import bitchat

struct PrivateMediaDecodeFailureReasonTests {
    @Test func mapsMalformedRejection() {
        let reason = PrivateMediaDecodeFailureReason.from(.malformedPayload)
        #expect(reason.logLabel == "malformed_payload")
        #expect(!reason.localizedSystemMessage.isEmpty)
    }

    @Test func mapsMagicMismatchWithMimeRawValue() {
        let reason = PrivateMediaDecodeFailureReason.from(
            .magicMismatch(mime: .jpeg, bytes: 12, prefixHex: "ff d8")
        )
        #expect(reason.logLabel.contains("magic_mismatch"))
        #expect(reason.localizedSystemMessage.contains("jpeg") || reason.localizedSystemMessage.contains("image"))
    }
}
