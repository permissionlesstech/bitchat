//
// MeshPlaintextNoticeSettingsTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

struct MeshPlaintextNoticeSettingsTests {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MeshPlaintextNoticeSettingsTests-\(UUID().uuidString)")!
    }

    @Test func defaultsToVisibleUntilDismissed() {
        let defaults = isolatedDefaults()
        #expect(!MeshPlaintextNoticeSettings.isDismissed(in: defaults))
        MeshPlaintextNoticeSettings.setDismissed(true, in: defaults)
        #expect(MeshPlaintextNoticeSettings.isDismissed(in: defaults))
        MeshPlaintextNoticeSettings.reset(in: defaults)
        #expect(!MeshPlaintextNoticeSettings.isDismissed(in: defaults))
    }
}
