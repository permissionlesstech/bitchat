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

    @Test func defaultsToInstantWipe() {
        let (suite, defaults) = isolatedDefaults()
        defer { cleanup(suite) }
        #expect(PanicWipeSettings.logoShortcutMode(in: defaults) == .instant)
    }

    @Test func persistsConfirmAndOffModes() {
        let (suite, defaults) = isolatedDefaults()
        defer { cleanup(suite) }
        PanicWipeSettings.setLogoShortcutMode(.confirm, in: defaults)
        #expect(PanicWipeSettings.logoShortcutMode(in: defaults) == .confirm)
        PanicWipeSettings.setLogoShortcutMode(.off, in: defaults)
        #expect(PanicWipeSettings.logoShortcutMode(in: defaults) == .off)
    }

    @Test func resetRestoresInstantDefault() {
        let (suite, defaults) = isolatedDefaults()
        defer { cleanup(suite) }
        PanicWipeSettings.setLogoShortcutMode(.off, in: defaults)
        PanicWipeSettings.reset(in: defaults)
        #expect(PanicWipeSettings.logoShortcutMode(in: defaults) == .instant)
    }

    @Test func migratesLegacyConfirmFlag() {
        let (suite, defaults) = isolatedDefaults()
        defer { cleanup(suite) }
        defaults.set(true, forKey: "panic.confirmLogoShortcut")
        #expect(PanicWipeSettings.logoShortcutMode(in: defaults) == .confirm)
    }

    @Test func migratesLegacyDisabledFlag() {
        let (suite, defaults) = isolatedDefaults()
        defer { cleanup(suite) }
        defaults.set(false, forKey: "panic.logoShortcutEnabled")
        #expect(PanicWipeSettings.logoShortcutMode(in: defaults) == .off)
    }
}
