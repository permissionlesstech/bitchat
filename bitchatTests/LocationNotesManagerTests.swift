import Testing
import Foundation
@testable import bitchat

@MainActor
struct LocationNotesManagerTests {
//    func testSubscribeWithoutRelaysSetsNoRelaysState() {
//        var subscribeCalled = false
//        let deps = LocationNotesDependencies(
//            relayLookup: { _, _ in [] },
//            subscribe: { _, _, _, _, _ in
//                subscribeCalled = true
//            },
//            unsubscribe: { _ in },
//            sendEvent: { _, _ in },
//            deriveIdentity: { _ in fatalError("should not derive identity") },
//            now: { Date() }
//        )
//
//        let manager = LocationNotesManager(geohash: "u4pruydq", dependencies: deps)
//
//        XCTAssertFalse(subscribeCalled)
//        XCTAssertEqual(manager.state, .noRelays)
//        XCTAssertTrue(manager.initialLoadComplete)
//        XCTAssertEqual(manager.errorMessage, String(localized: "location_notes.error.no_relays"))
//        // Make sure we're getting an actual translated value and not the localization key
//        XCTAssertNotEqual(manager.errorMessage, "location_notes.error.no_relays")
//    }
//
//    func testSendWhenNoRelaysSurfacesError() {
//        var sendCalled = false
//        let deps = LocationNotesDependencies(
//            relayLookup: { _, _ in [] },
//            subscribe: { _, _, _, _, _ in },
//            unsubscribe: { _ in },
//            sendEvent: { _, _ in sendCalled = true },
//            deriveIdentity: { _ in throw TestError.shouldNotDerive },
//            now: { Date() }
//        )
//
//        let manager = LocationNotesManager(geohash: "zzzzzzzz", dependencies: deps)
//        manager.send(content: "hello", nickname: "tester")
//
//        XCTAssertFalse(sendCalled)
//        XCTAssertEqual(manager.state, .noRelays)
//        XCTAssertEqual(manager.errorMessage, String(localized: "location_notes.error.no_relays"))
//        // Make sure we're getting an actual translated value and not the localization key
//        XCTAssertNotEqual(manager.errorMessage, "location_notes.error.no_relays")
//    }

    @Test func subscribeUsesGeoRelaysAndAppendsNotes() {
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

        var event = NostrEvent(
            pubkey: "pub",
            createdAt: Date(),
            kind: .textNote,
            tags: [["g", "u4pruydq"]],
            content: "hi"
        )
        event.id = "event1"
        storedHandler?(event)
        storedEOSE?()

        #expect(manager.state == .ready)
        #expect(manager.notes.count == 1)
        #expect(manager.notes.first?.content == "hi")
    }

    private enum TestError: Error {
        case shouldNotDerive
    }
}

@MainActor
struct LocationNotesCounterTests {
    @Test func subscribeWithoutRelaysMarksUnavailable() {
        var subscribeCalled = false
        let deps = LocationNotesCounterDependencies(
            relayLookup: { _, _ in [] },
            subscribe: { _, _, _, _, _ in subscribeCalled = true },
            unsubscribe: { _ in }
        )

        let counter = LocationNotesCounter(testDependencies: deps)
        counter.subscribe(geohash: "u4pruydq")

        #expect(!subscribeCalled)
        #expect(!counter.relayAvailable)
        #expect(counter.initialLoadComplete)
        #expect(counter.count == 0)
    }

    @Test func subscribeCountsUniqueNotes() {
        var storedHandler: ((NostrEvent) -> Void)?
        var storedEOSE: (() -> Void)?
        let deps = LocationNotesCounterDependencies(
            relayLookup: { _, _ in ["wss://relay.geo"] },
            subscribe: { filter, id, relays, handler, eose in
                #expect(relays == ["wss://relay.geo"])
                #expect(filter.kinds == [1])
                #expect(!id.isEmpty)
                storedHandler = handler
                storedEOSE = eose
            },
            unsubscribe: { _ in }
        )

        let counter = LocationNotesCounter(testDependencies: deps)
        counter.subscribe(geohash: "u4pruydq")

        var first = NostrEvent(
            pubkey: "pub",
            createdAt: Date(),
            kind: .textNote,
            tags: [["g", "u4pruydq"]],
            content: "a"
        )
        first.id = "eventA"
        storedHandler?(first)

        let duplicate = first
        storedHandler?(duplicate)

        storedEOSE?()

        #expect(counter.relayAvailable)
        #expect(counter.count == 1)
        #expect(counter.initialLoadComplete)
    }
}
