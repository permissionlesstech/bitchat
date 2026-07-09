import Testing
import Combine
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
    func noRelays_resubscribesWhenDirectoryRefreshes() async throws {
        var relays: [String] = []
        var subscribeCount = 0
        let directorySubject = PassthroughSubject<Void, Never>()
        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in relays },
            subscribe: { _, _, _, _, _ in
                subscribeCount += 1
            },
            unsubscribe: { _ in },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in try NostrIdentity.generate() },
            now: { Date() },
            relayDirectoryUpdates: directorySubject.eraseToAnyPublisher()
        )

        let manager = LocationNotesManager(geohash: "u4pruydq", dependencies: deps)
        #expect(manager.state == .noRelays)
        #expect(subscribeCount == 0)

        // Directory loads later (e.g. remote fetch finished after Tor came up).
        relays = ["wss://relay.one"]
        directorySubject.send(())

        let deadline = Date().addingTimeInterval(1.0)
        while manager.state == .noRelays && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(subscribeCount == 1)
        #expect(manager.state == .loading)
        #expect(manager.errorMessage == nil)
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

    @Test
    func ingestDropsExpiredNotesAndKeepsUnexpiredOnes() throws {
        var storedHandler: ((NostrEvent) -> Void)?
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { _, _, _, handler, _ in
                storedHandler = handler
            },
            unsubscribe: { _ in },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in throw TestError.shouldNotDerive },
            now: { now }
        )

        let manager = LocationNotesManager(geohash: "u4pruydq", dependencies: deps)
        let identity = try NostrIdentity.generate()

        let expired = NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: now.addingTimeInterval(-3600),
            kind: .textNote,
            tags: [["g", "u4pruydq"], ["expiration", String(Int(now.timeIntervalSince1970) - 60)]],
            content: "gone"
        )
        storedHandler?(try expired.sign(with: identity.schnorrSigningKey()))

        let live = NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: now.addingTimeInterval(-3600),
            kind: .textNote,
            tags: [["g", "u4pruydq"], ["expiration", String(Int(now.timeIntervalSince1970) + 3600)]],
            content: "still here"
        )
        storedHandler?(try live.sign(with: identity.schnorrSigningKey()))

        #expect(manager.notes.count == 1)
        #expect(manager.notes.first?.content == "still here")
        #expect(manager.notes.first?.expiresAt == Date(timeIntervalSince1970: TimeInterval(Int(now.timeIntervalSince1970) + 3600)))
    }

    @Test
    func postDrop_sendsExpiringNoteToGeoRelays() throws {
        var sentEvents: [NostrEvent] = []
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = try NostrIdentity.generate()
        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { _, _, _, _, _ in },
            unsubscribe: { _ in },
            sendEvent: { event, _ in sentEvents.append(event) },
            deriveIdentity: { _ in identity },
            now: { now }
        )

        let posted = LocationNotesManager.postDrop(
            content: "  the coffee here is great  ",
            nickname: "scout",
            geohash: "u4pruydq",
            dependencies: deps
        )

        #expect(posted)
        #expect(sentEvents.count == 1)
        let event = try #require(sentEvents.first)
        #expect(event.kind == NostrProtocol.EventKind.textNote.rawValue)
        #expect(event.content == "the coffee here is great")
        #expect(event.tags.contains(["g", "u4pruydq"]))
        let expiration = event.tags.first { $0.first == "expiration" }?.last
        let expected = Int(now.addingTimeInterval(TransportConfig.locationDropExpirySeconds).timeIntervalSince1970)
        #expect(expiration == String(expected))
    }

    @Test
    func postDrop_failsWithoutRelays() {
        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in [] },
            subscribe: { _, _, _, _, _ in },
            unsubscribe: { _ in },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in throw TestError.shouldNotDerive },
            now: { Date() }
        )

        #expect(!LocationNotesManager.postDrop(content: "hi", nickname: "x", geohash: "u4pruydq", dependencies: deps))
    }

    @Test
    func pruneExpiredNotes_dropsNotesWhoseExpiryPassed() throws {
        var storedHandler: ((NostrEvent) -> Void)?
        var currentNow = Date(timeIntervalSince1970: 1_700_000_000)
        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { _, _, _, handler, _ in
                storedHandler = handler
            },
            unsubscribe: { _ in },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in throw TestError.shouldNotDerive },
            now: { currentNow }
        )

        let manager = LocationNotesManager(geohash: "u4pruydq", dependencies: deps)
        let identity = try NostrIdentity.generate()
        let note = NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: currentNow,
            kind: .textNote,
            tags: [["g", "u4pruydq"], ["expiration", String(Int(currentNow.timeIntervalSince1970) + 60)]],
            content: "short lived"
        )
        storedHandler?(try note.sign(with: identity.schnorrSigningKey()))
        #expect(manager.notes.count == 1)

        currentNow = currentNow.addingTimeInterval(120)
        manager.pruneExpiredNotes()

        #expect(manager.notes.isEmpty)
    }

    @Test
    func eoseWithoutConnectedRelays_showsConnectingInsteadOfEmpty() {
        var storedEOSE: (() -> Void)?
        var deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { _, _, _, _, eose in storedEOSE = eose },
            unsubscribe: { _ in },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in throw TestError.shouldNotDerive },
            now: { Date() }
        )
        deps.anyRelayConnected = { _ in false }

        let manager = LocationNotesManager(geohash: "u4pruydq", dependencies: deps)
        storedEOSE?()

        #expect(manager.state == .connecting)
        #expect(manager.initialLoadComplete)
    }

    @Test
    func eoseWithConnectedRelayAndNoNotes_isReadyEmpty() {
        var storedEOSE: (() -> Void)?
        var deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { _, _, _, _, eose in storedEOSE = eose },
            unsubscribe: { _ in },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in throw TestError.shouldNotDerive },
            now: { Date() }
        )
        deps.anyRelayConnected = { _ in true }

        let manager = LocationNotesManager(geohash: "u4pruydq", dependencies: deps)
        storedEOSE?()

        #expect(manager.state == .ready)
    }

    @Test
    func connectingState_retriesOnceARelayComesUp() {
        var storedEOSE: (() -> Void)?
        var subscribeCount = 0
        var relayUp = false
        var deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { _, _, _, _, eose in
                subscribeCount += 1
                storedEOSE = eose
            },
            unsubscribe: { _ in },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in throw TestError.shouldNotDerive },
            now: { Date() }
        )
        deps.anyRelayConnected = { _ in relayUp }

        let manager = LocationNotesManager(geohash: "u4pruydq", dependencies: deps)
        #expect(subscribeCount == 1)
        storedEOSE?()
        #expect(manager.state == .connecting)

        // Relay still down: no retry.
        manager.retryIfRelaysAvailable(relays: ["wss://relay.one"])
        #expect(subscribeCount == 1)

        // Relay up: re-subscribes for a fresh initial fetch.
        relayUp = true
        manager.retryIfRelaysAvailable(relays: ["wss://relay.one"])
        #expect(subscribeCount == 2)
        #expect(manager.state == .loading)
    }

    private enum TestError: Error {
        case shouldNotDerive
    }
}
