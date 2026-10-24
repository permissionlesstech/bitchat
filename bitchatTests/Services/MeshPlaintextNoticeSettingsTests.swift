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

    @Test func resetPostsSettingsChangedNotification() {
        let defaults = isolatedDefaults()
        var received = false
        let token = NotificationCenter.default.addObserver(
            forName: .meshPlaintextNoticeSettingsChanged,
            object: nil,
            queue: nil
        ) { _ in
            received = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        MeshPlaintextNoticeSettings.setDismissed(true, in: defaults)
        MeshPlaintextNoticeSettings.reset(in: defaults)

        #expect(received)
        #expect(!MeshPlaintextNoticeSettings.isDismissed(in: defaults))
    }

    @Test func hiddenOnAnEmptyMeshTimeline() {
        #expect(MeshPlaintextNoticeSettings.shouldShow(dismissed: false, isPublicMesh: true, timelineEmpty: true) == false)
        #expect(MeshPlaintextNoticeSettings.shouldShow(dismissed: false, isPublicMesh: true, timelineEmpty: false) == true)
        #expect(MeshPlaintextNoticeSettings.shouldShow(dismissed: true, isPublicMesh: true, timelineEmpty: false) == false)
        #expect(MeshPlaintextNoticeSettings.shouldShow(dismissed: false, isPublicMesh: false, timelineEmpty: false) == false)
    }
}
