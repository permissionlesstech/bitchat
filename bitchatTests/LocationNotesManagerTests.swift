import Testing
import Foundation
@testable import bitchat

@MainActor
struct LocationNotesManagerTests {
    @Test
    func subscribeWithoutRelays_setsNoRelaysState() {
        var subscribeCalled = false
        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in [] },
            subscribe: { _, _, _, _, _ in
                subscribeCalled = true
            },
            unsubscribe: { _ in },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in try NostrIdentity.generate() },
            now: { Date() }
        )

        let manager = LocationNotesManager(geohash: "u4pruydq", dependencies: deps)

        #expect(subscribeCalled == false)
        #expect(manager.state == .noRelays)
        #expect(manager.initialLoadComplete)
        #expect(manager.errorMessage == String(localized: "location_notes.error.no_relays"))
    }

    @Test
    func sendWithoutRelays_surfacesNoRelaysError() {
        var sendCalled = false
        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in [] },
            subscribe: { _, _, _, _, _ in },
            unsubscribe: { _ in },
            sendEvent: { _, _ in sendCalled = true },
            deriveIdentity: { _ in throw TestError.shouldNotDerive },
            now: { Date() }
        )

        let manager = LocationNotesManager(geohash: "u4pruydq", dependencies: deps)
        manager.send(content: "hello", nickname: "tester")

        #expect(sendCalled == false)
        #expect(manager.state == .noRelays)
        #expect(manager.errorMessage == String(localized: "location_notes.error.no_relays"))
    }

    @Test func subscribeUsesGeoRelaysAndAppendsNotes() throws {
        var relaysCaptured: [String] = []
        var storedHandler: ((NostrEvent) -> Void)?
        var storedEOSE: (() -> Void)?
        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { filter, id, relays, handler, eose in
                #expect(filter.kinds == [1])
                #expect(!id.isEmpty)
                relaysCaptured = relays
                storedHandler = handler
                storedEOSE = eose
            },
            unsubscribe: { _ in },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in throw TestError.shouldNotDerive },
            now: { Date() }
        )

        let manager = LocationNotesManager(geohash: "u4pruydq", dependencies: deps)
        #expect(relaysCaptured == ["wss://relay.one"])
        #expect(manager.state == .loading)

        let identity = try NostrIdentity.generate()
        let event = NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: Date(),
            kind: .textNote,
            tags: [["g", "u4pruydq"]],
            content: "hi"
        )
        let signed = try event.sign(with: identity.schnorrSigningKey())
        storedHandler?(signed)
        storedEOSE?()

        #expect(manager.state == .ready)
        #expect(manager.notes.count == 1)
        #expect(manager.notes.first?.content == "hi")
    }

    @Test
    func setGeohash_invalidValueIsIgnored() {
        var subscribeCount = 0
        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { _, _, _, _, _ in
                subscribeCount += 1
            },
            unsubscribe: { _ in },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in try NostrIdentity.generate() },
            now: { Date() }
        )

        let manager = LocationNotesManager(geohash: "u4pruydq", dependencies: deps)
        manager.setGeohash("not-valid")

        #expect(manager.geohash == "u4pruydq")
        #expect(subscribeCount == 1)
    }

    @Test
    func refreshAndCancel_manageSubscriptions() {
        var subscribeIDs: [String] = []
        var unsubscribedIDs: [String] = []
        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { _, id, _, _, _ in
                subscribeIDs.append(id)
            },
            unsubscribe: { id in
                unsubscribedIDs.append(id)
            },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in try NostrIdentity.generate() },
            now: { Date() }
        )

        let manager = LocationNotesManager(geohash: "u4pruydq", dependencies: deps)
        manager.refresh()
        manager.cancel()

        #expect(subscribeIDs.count == 2)
        #expect(unsubscribedIDs.count == 2)
        #expect(manager.state == .idle)
        #expect(manager.errorMessage == nil)
    }

    @Test
    func send_successCreatesLocalEchoAndClearsError() throws {
        var sentEvents: [NostrEvent] = []
        let identity = try NostrIdentity.generate()
        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { _, _, _, _, _ in },
            unsubscribe: { _ in },
            sendEvent: { event, _ in
                sentEvents.append(event)
            },
            deriveIdentity: { _ in identity },
            now: { Date(timeIntervalSince1970: 123_456) }
        )

        let manager = LocationNotesManager(geohash: "u4pruydq", dependencies: deps)
        manager.send(content: "  hello note  ", nickname: "Builder")

        #expect(sentEvents.count == 1)
        #expect(manager.state == .ready)
        #expect(manager.errorMessage == nil)
        #expect(manager.notes.first?.content == "hello note")
        #expect(manager.notes.first?.displayName.hasPrefix("Builder#") == true)
    }

    @Test
    func send_failureFormatsErrorMessageAndClearErrorRemovesIt() {
        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { _, _, _, _, _ in },
            unsubscribe: { _ in },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in throw TestError.shouldNotDerive },
            now: { Date() }
        )

        let manager = LocationNotesManager(geohash: "u4pruydq", dependencies: deps)
        manager.send(content: "hello", nickname: "Builder")

        #expect(manager.errorMessage?.isEmpty == false)

        manager.clearError()

        #expect(manager.errorMessage == nil)
    }

    private enum TestError: Error {
        case shouldNotDerive
    }
}
