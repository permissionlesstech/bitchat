import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("Share extension handoff", .serialized)
struct SharedContentHandoffTests {
    private func makeStore() -> (suite: String, defaults: UserDefaults, store: SharedContentStore) {
        let suite = "SharedContentHandoffTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (suite, defaults, SharedContentStore(defaults: defaults))
    }

    @Test("A staged share survives an inactive app and a late open")
    func stagedShareSurvivesLateOpen() throws {
        let context = makeStore()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let stagedAt = Date(timeIntervalSince1970: 1_000_000)
        let payload = SharedContentPayload.text("review me later", createdAt: stagedAt)

        try context.store.stage(payload, now: stagedAt)

        #expect(context.store.pending(now: stagedAt.addingTimeInterval(60 * 60)) == payload)
        #expect(context.defaults.data(forKey: SharedContentStore.storageKey) != nil)
    }

    @Test("Malformed, oversized, unsupported, and expired payloads are rejected and cleared")
    func invalidPayloadsAreRejectedAndCleared() throws {
        let context = makeStore()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let now = Date(timeIntervalSince1970: 2_000_000)

        context.defaults.set(Data("not-json".utf8), forKey: SharedContentStore.storageKey)
        #expect(context.store.pending(now: now) == nil)
        #expect(context.defaults.object(forKey: SharedContentStore.storageKey) == nil)

        context.defaults.set(
            Data(repeating: 0x41, count: SharedContentPayload.maxEnvelopeBytes + 1),
            forKey: SharedContentStore.storageKey
        )
        #expect(context.store.pending(now: now) == nil)
        #expect(context.defaults.object(forKey: SharedContentStore.storageKey) == nil)

        let oversized = SharedContentPayload.text(
            String(repeating: "x", count: SharedContentPayload.maxContentBytes + 1),
            createdAt: now
        )
        #expect(throws: SharedContentHandoffError.contentTooLarge) {
            try context.store.stage(oversized, now: now)
        }
        #expect(context.defaults.object(forKey: SharedContentStore.storageKey) == nil)

        let unsupportedURL = SharedContentPayload(
            kind: .url,
            content: "file:///private/tmp/secret.txt",
            createdAt: now
        )
        #expect(throws: SharedContentHandoffError.unsupportedURL) {
            try context.store.stage(unsupportedURL, now: now)
        }

        let misleadingControl = SharedContentPayload.text("safe\u{202E}txt", createdAt: now)
        #expect(throws: SharedContentHandoffError.invalidCharacters) {
            try context.store.stage(misleadingControl, now: now)
        }

        let expired = SharedContentPayload.text(
            "too old",
            createdAt: now.addingTimeInterval(-SharedContentPayload.retentionSeconds - 1)
        )
        context.defaults.set(try JSONEncoder().encode(expired), forKey: SharedContentStore.storageKey)
        #expect(context.store.pending(now: now) == nil)
        #expect(context.defaults.object(forKey: SharedContentStore.storageKey) == nil)
    }

    @Test("Mesh, geohash, and stale private selections resolve to explicit destinations")
    func destinationsAreExplicit() {
        let geohashChannel = ChannelID.location(
            GeohashChannel(level: .city, geohash: "9Q8YY")
        )
        let stalePeer = PeerID(str: "0011223344556677")

        #expect(SharedContentDestination.resolve(
            selectedPrivatePeerID: nil,
            privateDisplayName: nil,
            activeChannel: .mesh
        ) == .mesh)
        #expect(SharedContentDestination.resolve(
            selectedPrivatePeerID: nil,
            privateDisplayName: nil,
            activeChannel: geohashChannel
        ) == .geohash("9q8yy"))
        #expect(SharedContentDestination.resolve(
            selectedPrivatePeerID: stalePeer,
            privateDisplayName: "alice",
            activeChannel: geohashChannel
        ) == .privateConversation(peerID: stalePeer, displayName: "alice"))
    }

    @Test("A destination change requires a new confirmation and never consumes on the stale tap")
    @MainActor
    func staleDestinationCannotBeConfirmed() throws {
        let context = makeStore()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let now = Date(timeIntervalSince1970: 3_000_000)
        let payload = SharedContentPayload.text("do not auto-send", createdAt: now)
        let peer = PeerID(str: "8899aabbccddeeff")
        let privateDestination = SharedContentDestination.privateConversation(
            peerID: peer,
            displayName: "alice"
        )
        let model = SharedContentImportModel(store: context.store)
        try context.store.stage(payload, now: now)
        model.refresh(destination: privateDestination, now: now)

        #expect(model.confirm(destination: .mesh, now: now) == nil)
        #expect(model.offer?.destination == .mesh)
        #expect(context.store.pending(now: now) == payload)

        #expect(model.confirm(destination: .mesh, now: now) == payload.content)
        #expect(model.offer == nil)
        #expect(context.store.pending(now: now) == nil)
    }

    @Test("Confirmation consumes once and cancellation explicitly clears without producing composer text")
    @MainActor
    func oneTimeConfirmationAndCancellation() throws {
        let context = makeStore()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let now = Date(timeIntervalSince1970: 4_000_000)
        let model = SharedContentImportModel(store: context.store)

        let first = SharedContentPayload.text("confirmed", createdAt: now)
        try context.store.stage(first, now: now)
        model.refresh(destination: .geohash("u4pruy"), now: now)
        #expect(model.confirm(destination: .geohash("u4pruy"), now: now) == "confirmed")
        #expect(model.confirm(destination: .geohash("u4pruy"), now: now) == nil)

        let second = SharedContentPayload.text("cancelled", createdAt: now)
        try context.store.stage(second, now: now)
        model.refresh(destination: .mesh, now: now)
        model.cancel(destination: .mesh, now: now)
        #expect(model.offer == nil)
        #expect(context.store.pending(now: now) == nil)

        let third = SharedContentPayload.text("panic-wiped", createdAt: now)
        try context.store.stage(third, now: now)
        model.refresh(destination: .mesh, now: now)
        model.discardAll()
        #expect(model.offer == nil)
        #expect(context.store.pending(now: now) == nil)
    }

    @Test("Cancelling an old review never deletes a newer staged share")
    @MainActor
    func cancellationPreservesNewerShare() throws {
        let context = makeStore()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let now = Date(timeIntervalSince1970: 5_000_000)
        let model = SharedContentImportModel(store: context.store)
        let old = SharedContentPayload.text("old", createdAt: now)
        let newer = SharedContentPayload.text("new", createdAt: now)

        try context.store.stage(old, now: now)
        model.refresh(destination: .mesh, now: now)
        try context.store.stage(newer, now: now)
        model.cancel(destination: .mesh, now: now)

        #expect(model.offer?.payload == newer)
        #expect(context.store.pending(now: now) == newer)
    }
}
