import Foundation
import Testing
@testable import bitchat

/// The built-in relay set is four well-known hostnames, so a filter blocking
/// four names ends internet-delivered private messages. These cover the
/// hand-added relays that make that recoverable without shipping a build.
struct NostrRelaySettingsTests {
    /// Each case gets its own suite so nothing touches the real preferences or
    /// races another case.
    private func makeDefaults() -> UserDefaults {
        let suite = "bitchat.tests.relays.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private let builtIn: Set<String> = [
        "wss://relay.damus.io",
        "wss://nos.lol"
    ]

    @Test func addNormalizesABareHostname() {
        let defaults = makeDefaults()

        // A bare hostname is how relays are usually quoted; wss is the only
        // sensible assumption.
        let result = NostrRelaySettings.add("relay.example.com", builtIn: builtIn, in: defaults)

        #expect(result == .success("wss://relay.example.com"))
        #expect(NostrRelaySettings.customRelays(in: defaults) == ["wss://relay.example.com"])
    }

    @Test func addAcceptsAnOnionAddress() {
        let defaults = makeDefaults()

        // The reason this feature exists: an onion relay is not blockable by
        // hostname or SNI filtering.
        let result = NostrRelaySettings.add(
            "wss://exampleonionaddressxyz234567.onion",
            builtIn: builtIn,
            in: defaults
        )

        #expect(result == .success("wss://exampleonionaddressxyz234567.onion"))
    }

    @Test func addRejectsMalformedInput() {
        let defaults = makeDefaults()

        #expect(NostrRelaySettings.add("", builtIn: builtIn, in: defaults) == .failure(.malformed))
        #expect(NostrRelaySettings.add("   ", builtIn: builtIn, in: defaults) == .failure(.malformed))
        // A scheme the relay layer cannot dial must not be stored.
        #expect(NostrRelaySettings.add("ftp://relay.example.com", builtIn: builtIn, in: defaults) == .failure(.malformed))
        #expect(NostrRelaySettings.customRelays(in: defaults).isEmpty)
    }

    @Test func addRejectsDuplicatesAndBuiltIns() {
        let defaults = makeDefaults()
        #expect(NostrRelaySettings.add("wss://relay.example.com", builtIn: builtIn, in: defaults) == .success("wss://relay.example.com"))

        // Same relay written differently still normalizes to the same URL.
        #expect(NostrRelaySettings.add("relay.example.com", builtIn: builtIn, in: defaults) == .failure(.alreadyPresent))
        #expect(NostrRelaySettings.add("WSS://Relay.Example.com", builtIn: builtIn, in: defaults) == .failure(.alreadyPresent))
        // Re-adding a built-in would double-count it in the target list.
        #expect(NostrRelaySettings.add("wss://nos.lol", builtIn: builtIn, in: defaults) == .failure(.alreadyPresent))

        #expect(NostrRelaySettings.customRelays(in: defaults) == ["wss://relay.example.com"])
    }

    @Test func addStopsAtTheLimit() {
        let defaults = makeDefaults()
        for index in 0..<NostrRelaySettings.maxCustomRelays {
            #expect(NostrRelaySettings.add("relay\(index).example.com", builtIn: builtIn, in: defaults) == .success("wss://relay\(index).example.com"))
        }

        // Unbounded growth would fan every send out across dozens of sockets.
        #expect(NostrRelaySettings.add("one.too.many.example.com", builtIn: builtIn, in: defaults) == .failure(.limitReached))
        #expect(NostrRelaySettings.customRelays(in: defaults).count == NostrRelaySettings.maxCustomRelays)
    }

    @Test func addPreservesInsertionOrder() {
        let defaults = makeDefaults()
        NostrRelaySettings.add("b.example.com", builtIn: builtIn, in: defaults)
        NostrRelaySettings.add("a.example.com", builtIn: builtIn, in: defaults)

        #expect(NostrRelaySettings.customRelays(in: defaults) == ["wss://b.example.com", "wss://a.example.com"])
    }

    @Test func removeTakesAnyEquivalentSpelling() {
        let defaults = makeDefaults()
        NostrRelaySettings.add("wss://relay.example.com", builtIn: builtIn, in: defaults)
        NostrRelaySettings.add("wss://other.example.com", builtIn: builtIn, in: defaults)

        NostrRelaySettings.remove("Relay.Example.com", in: defaults)

        #expect(NostrRelaySettings.customRelays(in: defaults) == ["wss://other.example.com"])
    }

    @Test func resetClearsEverything() {
        let defaults = makeDefaults()
        NostrRelaySettings.add("relay.example.com", builtIn: builtIn, in: defaults)

        // Panic wipe: an added relay names an operator someone chose to route
        // through, which is exactly the trace a wipe must not leave.
        NostrRelaySettings.reset(in: defaults)

        #expect(NostrRelaySettings.customRelays(in: defaults).isEmpty)
    }

    @Test func readsSkipUnusableStoredValues() {
        let defaults = makeDefaults()
        // Written by an older build, or edited outside the app: it must not
        // reach the connection layer unchecked.
        defaults.set(
            ["wss://good.example.com", "ftp://bad.example.com", "", "wss://good.example.com"],
            forKey: "nostr.customRelays"
        )

        #expect(NostrRelaySettings.customRelays(in: defaults) == ["wss://good.example.com"])
    }

    @Test func builtInRelaysAreExposedNormalizedForDeduplication() {
        // The UI rejects re-adding a built-in by comparing against this set, so
        // it has to hold normalized URLs.
        let builtIn = NostrRelayManager.builtInRelayURLs
        #expect(!builtIn.isEmpty)
        for url in builtIn {
            #expect(NostrRelayURL.normalized(url) == url)
        }
    }
}
