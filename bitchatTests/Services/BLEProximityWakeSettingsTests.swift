//
// BLEProximityWakeSettingsTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

struct BLEProximityWakeSettingsTests {
    private var defaults: UserDefaults {
        UserDefaults(suiteName: "BLEProximityWakeSettingsTests.\(UUID().uuidString)")!
    }

    @Test
    func defaultsToEnabled() {
        #expect(BLEProximityWakeSettings.enabled(in: defaults))
    }

    @Test
    func persistsDisabledPreference() {
        let defaults = self.defaults
        BLEProximityWakeSettings.setEnabled(false, in: defaults)
        #expect(!BLEProximityWakeSettings.enabled(in: defaults))
    }

    @Test
    func resetRestoresDefaultEnabled() {
        let defaults = self.defaults
        BLEProximityWakeSettings.setEnabled(false, in: defaults)
        BLEProximityWakeSettings.reset(in: defaults)
        #expect(BLEProximityWakeSettings.enabled(in: defaults))
    }

    @Test
    func standardStoreChangePostsNotification() async {
        let previous = BLEProximityWakeSettings.enabled
        defer { BLEProximityWakeSettings.enabled = previous }

        await confirmation("didChangeNotification fires for standard store") { confirm in
            let observer = NotificationCenter.default.addObserver(
                forName: BLEProximityWakeSettings.didChangeNotification,
                object: nil,
                queue: nil
            ) { _ in
                confirm()
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            BLEProximityWakeSettings.enabled = !previous
        }
    }
}
