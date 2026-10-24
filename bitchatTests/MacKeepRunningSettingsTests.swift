//
// MacKeepRunningSettingsTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(macOS)

import Foundation
import Testing
@testable import bitchat

struct MacKeepRunningSettingsTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "MacKeepRunningSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Closing the last window quits by default")
    func defaultQuitsOnLastWindowClose() {
        let defaults = isolatedDefaults()
        #expect(!MacKeepRunningSettings.enabled(in: defaults))
        #expect(MacKeepRunningSettings.shouldTerminateAfterLastWindowClosed(in: defaults))
    }

    @Test("Opt-in keeps the process alive after the last window closes")
    func optInSurvivesLastWindowClose() {
        let defaults = isolatedDefaults()
        MacKeepRunningSettings.setEnabled(true, in: defaults)
        #expect(MacKeepRunningSettings.enabled(in: defaults))
        #expect(!MacKeepRunningSettings.shouldTerminateAfterLastWindowClosed(in: defaults))
    }

    @Test("Reset restores quit-on-close")
    func resetRestoresDefault() {
        let defaults = isolatedDefaults()
        MacKeepRunningSettings.setEnabled(true, in: defaults)
        MacKeepRunningSettings.reset(in: defaults)
        #expect(MacKeepRunningSettings.shouldTerminateAfterLastWindowClosed(in: defaults))
    }
}

#endif
