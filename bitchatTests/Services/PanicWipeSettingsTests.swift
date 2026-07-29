import Testing
import Foundation
@testable import bitchat

struct PanicWipeSettingsTests {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "PanicWipeSettingsTests.\(UUID().uuidString)")!
    }

    @Test func defaultsToInstantWipe() {
        let defaults = isolatedDefaults()
        #expect(!PanicWipeSettings.confirmLogoShortcut(in: defaults))
    }

    @Test func persistsOptInConfirmation() {
        let defaults = isolatedDefaults()
        PanicWipeSettings.setConfirmLogoShortcut(true, in: defaults)
        #expect(PanicWipeSettings.confirmLogoShortcut(in: defaults))
    }

    @Test func resetRestoresInstantDefault() {
        let defaults = isolatedDefaults()
        PanicWipeSettings.setConfirmLogoShortcut(true, in: defaults)
        PanicWipeSettings.reset(in: defaults)
        #expect(!PanicWipeSettings.confirmLogoShortcut(in: defaults))
    }
}
