import Foundation
import Testing
@testable import bitchat

/// The geo-relay directory refresh runs off the main actor and has to decide
/// whether waiting for Tor is meaningful. It previously waited unconditionally,
/// so with Tor switched off — and `TorManager` therefore shut down — every
/// refresh spent the full bootstrap timeout and the directory froze on its
/// cached copy.
struct TorPreferenceReadTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "bitchat.tests.tor.\(UUID().uuidString)")!
    }

    @Test func defaultsToOnWhenNothingHasBeenStored() {
        // Fail safe: an unwritten preference must not read as "Tor off", which
        // would let a fetch go direct.
        #expect(NetworkActivationService.persistedTorPreference(in: makeDefaults()))
    }

    @Test func reflectsTheStoredPreference() {
        let defaults = makeDefaults()

        defaults.set(false, forKey: NetworkActivationService.torPreferenceKey)
        #expect(!NetworkActivationService.persistedTorPreference(in: defaults))

        defaults.set(true, forKey: NetworkActivationService.torPreferenceKey)
        #expect(NetworkActivationService.persistedTorPreference(in: defaults))
    }

    @Test func nonBooleanStoredValueReadsAsOn() {
        let defaults = makeDefaults()
        defaults.set("nonsense", forKey: NetworkActivationService.torPreferenceKey)

        // Same fail-safe direction: anything unrecognized means keep using Tor.
        #expect(NetworkActivationService.persistedTorPreference(in: defaults))
    }
}
