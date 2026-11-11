//
// PTTSettingsTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

/// Live push-to-talk streams a hold to other people before it is released and
/// plays strangers' voices out loud, so it must be something people opt into.
/// The preference is injected rather than read from shared preferences, so
/// these run in parallel with suites that use the default store.
struct PTTSettingsTests {

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "bitchat.tests.ptt.\(UUID().uuidString)")!
    }

    @Test func liveVoiceIsOffByDefault() {
        // A fresh install must not stream holds or auto-play inbound bursts.
        #expect(!PTTSettings.liveVoiceEnabled(in: isolatedDefaults()))
    }

    @Test func theSettingRoundTrips() {
        let defaults = isolatedDefaults()

        PTTSettings.setLiveVoiceEnabled(true, in: defaults)
        #expect(PTTSettings.liveVoiceEnabled(in: defaults))

        PTTSettings.setLiveVoiceEnabled(false, in: defaults)
        #expect(!PTTSettings.liveVoiceEnabled(in: defaults))
    }

    @Test func panicResetRestoresTheOffDefault() {
        let defaults = isolatedDefaults()
        PTTSettings.setLiveVoiceEnabled(true, in: defaults)

        // Panic wipe restores the safe default rather than the last choice.
        PTTSettings.reset(in: defaults)
        #expect(!PTTSettings.liveVoiceEnabled(in: defaults))
    }
}
