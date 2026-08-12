//
// PanicWipeSettingsTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

struct PanicWipeSettingsTests {
    private func isolatedDefaults() -> (suite: String, defaults: UserDefaults) {
        let suite = "PanicWipeSettingsTests.\(UUID().uuidString)"
        return (suite, UserDefaults(suiteName: suite)!)
    }

    private func cleanup(_ suite: String) {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    /// #1509 shipped confirm-before-wipe and wrote no preference key, so every
    /// existing install lands here with nothing stored. The default has to be
    /// `.confirm` or updating silently moves those people to an instant wipe.
    @Test func defaultsToConfirmSoAnUpdateDoesNotChangeBehaviour() {
        let (suite, defaults) = isolatedDefaults()
        defer { cleanup(suite) }
        #expect(PanicWipeSettings.logoShortcutMode(in: defaults) == .confirm)
    }

    @Test func persistsInstantAndOffModes() {
        let (suite, defaults) = isolatedDefaults()
        defer { cleanup(suite) }
        PanicWipeSettings.setLogoShortcutMode(.instant, in: defaults)
        #expect(PanicWipeSettings.logoShortcutMode(in: defaults) == .instant)
        PanicWipeSettings.setLogoShortcutMode(.off, in: defaults)
        #expect(PanicWipeSettings.logoShortcutMode(in: defaults) == .off)
        PanicWipeSettings.setLogoShortcutMode(.confirm, in: defaults)
        #expect(PanicWipeSettings.logoShortcutMode(in: defaults) == .confirm)
    }

    /// A wiped device must come back with the gesture armed, not carrying the
    /// seized owner's "off" setting.
    @Test func resetRestoresTheConfirmDefault() {
        let (suite, defaults) = isolatedDefaults()
        defer { cleanup(suite) }
        PanicWipeSettings.setLogoShortcutMode(.off, in: defaults)
        PanicWipeSettings.reset(in: defaults)
        #expect(PanicWipeSettings.logoShortcutMode(in: defaults) == .confirm)
    }

    /// The two legacy keys never shipped — #1509 wrote no preference at all —
    /// so reading them would only be a way to get the default wrong.
    @Test func ignoresKeysThatNeverShipped() {
        let (suite, defaults) = isolatedDefaults()
        defer { cleanup(suite) }
        defaults.set(true, forKey: "panic.confirmLogoShortcut")
        defaults.set(false, forKey: "panic.logoShortcutEnabled")
        #expect(PanicWipeSettings.logoShortcutMode(in: defaults) == .confirm)
    }

    /// An unparseable stored value must fall back to the safe mode, not crash
    /// or leave the gesture unarmed.
    @Test func unknownStoredValueFallsBackToConfirm() {
        let (suite, defaults) = isolatedDefaults()
        defer { cleanup(suite) }
        defaults.set("stampede", forKey: "panic.logoShortcutMode")
        #expect(PanicWipeSettings.logoShortcutMode(in: defaults) == .confirm)
    }

    @Test func everyModeRoundTripsThroughItsRawValue() {
        for mode in PanicWipeSettings.LogoShortcutMode.allCases {
            #expect(PanicWipeSettings.LogoShortcutMode(rawValue: mode.rawValue) == mode)
            #expect(mode.id == mode.rawValue)
        }
    }
}
