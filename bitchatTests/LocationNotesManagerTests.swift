import XCTest
@testable import bitchat

@MainActor
final class LocationNotesManagerTests: XCTestCase {
    func testSubscribeWithoutRelaysSetsNoRelaysState() {
        var subscribeCalled = false
        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in [] },
            subscribe: { _, _, _, _, _ in
                subscribeCalled = true
            },
            unsubscribe: { _ in },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in fatalError("should not derive identity") },
            now: { Date() }
        )

        let manager = LocationNotesManager(geohash: "abcd1234", dependencies: deps)

        XCTAssertFalse(subscribeCalled)
        XCTAssertEqual(manager.state, .noRelays)
        XCTAssertTrue(manager.initialLoadComplete)
        XCTAssertEqual(manager.errorMessage, "No geo relays available near this location. Try again soon.")
    }

    func testSendWhenNoRelaysSurfacesError() {
        var sendCalled = false
        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in [] },
            subscribe: { _, _, _, _, _ in },
            unsubscribe: { _ in },
            sendEvent: { _, _ in sendCalled = true },
            deriveIdentity: { _ in throw TestError.shouldNotDerive },
            now: { Date() }
        )

        let manager = LocationNotesManager(geohash: "zzzzzzzz", dependencies: deps)
        manager.send(content: "hello", nickname: "tester")

        XCTAssertFalse(sendCalled)
        XCTAssertEqual(manager.state, .noRelays)
        XCTAssertEqual(manager.errorMessage, "No geo relays available near this location. Try again soon.")
    }

    func testSubscribeUsesGeoRelaysAndAppendsNotes() {
        var relaysCaptured: [String] = []
        var storedHandler: ((NostrEvent) -> Void)?
        var storedEOSE: (() -> Void)?
        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { filter, id, relays, handler, eose in
                XCTAssertEqual(filter.kinds, [1])
                XCTAssertFalse(id.isEmpty)
                relaysCaptured = relays
                storedHandler = handler
                storedEOSE = eose
            },
            unsubscribe: { _ in },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in throw TestError.shouldNotDerive },
            now: { Date() }
        )

        let manager = LocationNotesManager(geohash: "abcd1234", dependencies: deps)
        XCTAssertEqual(relaysCaptured, ["wss://relay.one"])
        XCTAssertEqual(manager.state, .loading)

        var event = NostrEvent(
            pubkey: "pub",
            createdAt: Date(),
            kind: .textNote,
            tags: [["g", "abcd1234"]],
            content: "hi"
        )
        event.id = "event1"
        storedHandler?(event)
        storedEOSE?()

        XCTAssertEqual(manager.state, .ready)
        XCTAssertEqual(manager.notes.count, 1)
        XCTAssertEqual(manager.notes.first?.content, "hi")
    }

    private enum TestError: Error {
        case shouldNotDerive
    }
}

@MainActor
final class LocationNotesCounterTests: XCTestCase {
    func testSubscribeWithoutRelaysMarksUnavailable() {
        var subscribeCalled = false
        let deps = LocationNotesCounterDependencies(
            relayLookup: { _, _ in [] },
            subscribe: { _, _, _, _, _ in subscribeCalled = true },
            unsubscribe: { _ in }
        )

        let counter = LocationNotesCounter(testDependencies: deps)
        counter.subscribe(geohash: "abcdefgh")

        XCTAssertFalse(subscribeCalled)
        XCTAssertFalse(counter.relayAvailable)
        XCTAssertTrue(counter.initialLoadComplete)
        XCTAssertEqual(counter.count, 0)
    }

    func testSubscribeCountsUniqueNotes() {
        var storedHandler: ((NostrEvent) -> Void)?
        var storedEOSE: (() -> Void)?
        let deps = LocationNotesCounterDependencies(
            relayLookup: { _, _ in ["wss://relay.geo"] },
            subscribe: { filter, id, relays, handler, eose in
                XCTAssertEqual(relays, ["wss://relay.geo"])
                XCTAssertEqual(filter.kinds, [1])
                XCTAssertFalse(id.isEmpty)
                storedHandler = handler
                storedEOSE = eose
            },
            unsubscribe: { _ in }
        )

        let counter = LocationNotesCounter(testDependencies: deps)
        counter.subscribe(geohash: "abcdefgh")

        var first = NostrEvent(
            pubkey: "pub",
            createdAt: Date(),
            kind: .textNote,
            tags: [["g", "abcdefgh"]],
            content: "a"
        )
        first.id = "eventA"
        storedHandler?(first)

        let duplicate = first
        storedHandler?(duplicate)

        storedEOSE?()

        XCTAssertTrue(counter.relayAvailable)
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(counter.initialLoadComplete)
    }
}
