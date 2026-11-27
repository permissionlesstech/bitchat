import Foundation
import Testing
@testable import bitchat

/// Verifies off-main Tor preference reads used by background tasks like geo-relay
/// directory refresh. Everyday Mode defaults to direct (Tor off) for instant
/// cold start; Stealth Mode and explicit `true` enable Tor.
struct TorPreferenceReadTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "bitchat.tests.tor.\(UUID().uuidString)")!
    }

    @Test func defaultsToOffInEverydayModeWhenNothingHasBeenStored() {
        #expect(!NetworkActivationService.persistedTorPreference(in: makeDefaults()))
    }

    @Test func defaultsToOnInStealthModeWhenExplicitTorPreferenceIsUnset() {
        let defaults = makeDefaults()
        defaults.set(PrivacyMode.stealth.rawValue, forKey: PrivacyModeSettings.modeKey)
        #expect(NetworkActivationService.persistedTorPreference(in: defaults))
    }

    @Test func reflectsTheStoredPreference() {
        let defaults = makeDefaults()

        defaults.set(false, forKey: NetworkActivationService.torPreferenceKey)
        #expect(!NetworkActivationService.persistedTorPreference(in: defaults))

        defaults.set(true, forKey: NetworkActivationService.torPreferenceKey)
        #expect(NetworkActivationService.persistedTorPreference(in: defaults))
    }

    @Test func nonBooleanStoredValueFallsBackToPrivacyModeDefault() {
        let defaults = makeDefaults()
        defaults.set("nonsense", forKey: NetworkActivationService.torPreferenceKey)
        #expect(!NetworkActivationService.persistedTorPreference(in: defaults))

        defaults.set(PrivacyMode.stealth.rawValue, forKey: PrivacyModeSettings.modeKey)
        #expect(NetworkActivationService.persistedTorPreference(in: defaults))
    }
}
