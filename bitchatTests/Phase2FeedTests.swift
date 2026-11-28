//
// Phase2FeedTests.swift
// bitchatTests
//
// Coverage for Phase 2:
// - NIP-01 kind-0 profile metadata creation, sanitization, and size bounds
// - npub / hex pubkey normalization & global kind-1 mined notes
// - NostrFollowsStore private Keychain persistence, favorites merge, and panic wipe
// - NostrProfileStore opt-in handle, remote kind-0 batching/cooldown/EOSE, and panic wipe
// - LocationNotesManager dual-posture posting (.placePersona vs .publicHandle) & delete
// - HomeFeedManager Saved Places + Following merge, deduplication, scopes, global send, and panic wipe
// - SwiftUI smoke rendering for HomeFeedView and PublicProfileSheet
//

import Combine
import Foundation
import SwiftUI
import Testing
@testable import bitchat

struct Phase2ProtocolTests {

    @Test
    func kind0_metadataRoundTripsSanitizedFieldsAndRejectsOversizedPayload() throws {
        let identity = try NostrIdentity.generate()
        let raw = NostrProtocol.ProfileMetadata(
            name: "alice\nignored",
            displayName: "  Alice Wonder  ",
            about: "line 1\nline 2",
            nip05: "alice@example.com\r\n"
        )
        let event = try NostrProtocol.createMetadataEvent(profile: raw, senderIdentity: identity)

        #expect(event.kind == NostrProtocol.EventKind.metadata.rawValue)
        #expect(event.isValidSignature())

        let parsed = try #require(NostrProtocol.parseMetadataEvent(event))
        #expect(parsed.displayName == "Alice Wonder")
        #expect(parsed.about == "line 1\nline 2")
        #expect(parsed.nip05 == "alice@example.com")
        #expect(parsed.preferredName == "Alice Wonder")

        // Oversized untrusted kind-0 content is rejected before JSON parsing.
        let huge = try NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: Date(),
            kind: .metadata,
            tags: [],
            content: "{\"about\":\"" + String(repeating: "x", count: NostrProtocol.maximumProfileMetadataBytes) + "\"}"
        ).sign(with: identity.schnorrSigningKey())
        #expect(NostrProtocol.parseMetadataEvent(huge) == nil)
    }

    @Test
    func normalizePubkeyHex_acceptsNpubAndHexAndRejectsGarbage() throws {
        let identity = try NostrIdentity.generate()
        #expect(NostrProtocol.normalizePubkeyHex(identity.npub) == identity.publicKeyHex.lowercased())
        #expect(NostrProtocol.normalizePubkeyHex(identity.publicKeyHex.uppercased()) == identity.publicKeyHex.lowercased())
        #expect(NostrProtocol.normalizePubkeyHex("not-a-key") == nil)
        #expect(NostrProtocol.normalizePubkeyHex("deadbeef") == nil)
    }

    @Test
    func createPublicTextNote_hasNoGeohashTagAndValidSignature() throws {
        let identity = try NostrIdentity.generate()
        let event = try NostrProtocol.createPublicTextNote(
            content: "global update",
            senderIdentity: identity,
            nickname: "alice"
        )
        #expect(event.kind == NostrProtocol.EventKind.textNote.rawValue)
        #expect(event.isValidSignature())
        #expect(!event.tags.contains(where: { $0.first == "g" }))
    }
}

@MainActor
struct Phase2StoresAndHomeFeedTests {

    @Test
    func followsStore_persistsPrivatelyMergesFavoritesAndWipesOnPanic() throws {
        let keychain = PreviewKeychainManager()
        let explicitPeer = try NostrIdentity.generate()
        let favPeer = try NostrIdentity.generate()

        let favRel = FavoritesPersistenceService.FavoriteRelationship(
            peerNoisePublicKey: Data(repeating: 7, count: 32),
            peerNostrPublicKey: favPeer.npub,
            peerNickname: "mesh-friend",
            isFavorite: true,
            theyFavoritedUs: true,
            favoritedAt: Date(),
            lastUpdated: Date()
        )

        let store = NostrFollowsStore(keychain: keychain, favoritesProvider: { [favRel] })
        #expect(store.isFollowing(favPeer.publicKeyHex))
        #expect(!store.isFollowing(explicitPeer.publicKeyHex))

        #expect(store.follow(explicitPeer.npub, alias: "alice"))
        #expect(store.isFollowing(explicitPeer.publicKeyHex))
        #expect(store.isExplicitlyFollowing(explicitPeer.publicKeyHex))
        #expect(store.allFollowedPubkeys.count == 2)

        // Reload from same Keychain verifies persistence
        let reloaded = NostrFollowsStore(keychain: keychain, favoritesProvider: { [favRel] })
        #expect(reloaded.isExplicitlyFollowing(explicitPeer.publicKeyHex))
        #expect(reloaded.localAlias(for: explicitPeer.publicKeyHex) == "alice")

        // Panic wipe removes both in-memory and Keychain state
        reloaded.resetForPanic()
        #expect(reloaded.explicitFollows.isEmpty)
        #expect(reloaded.allFollowedPubkeys.isEmpty)

        let afterWipe = NostrFollowsStore(keychain: keychain, favoritesProvider: { [] })
        #expect(afterWipe.explicitFollows.isEmpty)
    }

    @Test
    func followsStore_lockedBootDefersWritesAndReplaysOnUnlock() throws {
        let keychain = MockKeychain()
        let existingPeer = try NostrIdentity.generate()
        let newPeer = try NostrIdentity.generate()

        let initial = NostrFollowsStore(keychain: keychain, favoritesProvider: { [] })
        #expect(initial.follow(existingPeer.publicKeyHex, alias: "existing"))

        // Boot while device is locked: load fails with .deviceLocked.
        keychain.simulatedGenericReadError = .deviceLocked
        let lockedStore = NostrFollowsStore(keychain: keychain, favoritesProvider: { [] })
        #expect(lockedStore.explicitFollows.isEmpty)

        // Mutating while locked must NOT overwrite existing Keychain entry.
        #expect(lockedStore.follow(newPeer.publicKeyHex, alias: "added-while-locked"))

        keychain.simulatedGenericReadError = nil
        let rawBeforeReplay = NostrFollowsStore(keychain: keychain, favoritesProvider: { [] })
        #expect(rawBeforeReplay.explicitFollows.map(\.pubkeyHex) == [existingPeer.publicKeyHex])

        // Unlocking and retrying loads existing follow, replays queued follow, and persists both.
        lockedStore.retryDeferredLoad()
        #expect(Set(lockedStore.explicitFollows.map(\.pubkeyHex)) == [existingPeer.publicKeyHex, newPeer.publicKeyHex])

        let afterReplay = NostrFollowsStore(keychain: keychain, favoritesProvider: { [] })
        #expect(Set(afterReplay.explicitFollows.map(\.pubkeyHex)) == [existingPeer.publicKeyHex, newPeer.publicKeyHex])
    }

    @Test
    func profileStore_clearsCooldownWhenEOSEFiresBeforeTorConnects() throws {
        let keychain = MockKeychain()
        let remote = try NostrIdentity.generate()
        var isConnected = false
        var subscribeCount = 0
        var lastEOSE: (() -> Void)?

        let deps = NostrProfileStoreDependencies(
            subscribe: { _, _, _, onEOSE in
                subscribeCount += 1
                lastEOSE = onEOSE
            },
            unsubscribe: { _ in },
            sendEvent: { _ in },
            currentIdentity: { nil },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            isAnyDefaultRelayConnected: { isConnected }
        )

        let store = NostrProfileStore(keychain: keychain, dependencies: deps)
        store.ensureProfiles(for: [remote.publicKeyHex])
        #expect(subscribeCount == 1)

        // 10s EOSE fallback fires while Tor/relays are still disconnected.
        lastEOSE?()

        // Once relays connect, cooldown must NOT block re-fetching the missing profile.
        isConnected = true
        store.ensureProfiles(for: [remote.publicKeyHex])
        #expect(subscribeCount == 2)
        store.resetForPanic()
    }

    @Test
    func homeFeedManager_prunesExpiredFollowingPostsWithoutResurrectingPlacePosts() throws {
        var currentNow = Date(timeIntervalSince1970: 1_700_000_000)
        let author = try NostrIdentity.generate()
        var placeHandler: ((NostrEvent) -> Void)?
        var followingHandler: ((NostrEvent) -> Void)?
        var placeManager: LocationNotesManager?

        let homeDeps = HomeFeedDependencies(
            acquirePlaceManager: { gh in
                let mgr = LocationNotesManager(geohash: gh, dependencies: LocationNotesDependencies(
                    relayLookup: { _, _ in ["wss://geo.relay"] },
                    subscribe: { _, _, _, onEvent, onEOSE in
                        placeHandler = onEvent
                        onEOSE?()
                    },
                    unsubscribe: { _ in },
                    sendEvent: { _, _ in },
                    deriveIdentity: { _ in try NostrIdentity.generate() },
                    now: { currentNow }
                ))
                placeManager = mgr
                return mgr
            },
            releasePlaceManager: { $0?.cancel() },
            subscribeDefaultRelays: { _, _, onEvent, onEOSE in
                followingHandler = onEvent
                onEOSE?()
            },
            unsubscribe: { _ in },
            sendDefaultRelays: { _ in },
            publicIdentity: { nil },
            ensureProfiles: { _ in },
            now: { currentNow }
        )

        let feed = HomeFeedManager(dependencies: homeDeps)
        feed.activate(bookmarks: ["9q8yy"], followedPubkeys: [author.publicKeyHex])

        let expiring = try NostrProtocol.createGeohashTextNote(
            content: "short-lived drop",
            geohash: "9q8yy",
            senderIdentity: author,
            nickname: "alice",
            expiresAt: currentNow.addingTimeInterval(60),
            createdAt: currentNow
        )
        placeHandler?(expiring)
        followingHandler?(expiring)
        #expect(feed.items.count == 1)

        // Advance past expiration: place manager prunes AND HomeFeedManager prunes Following cache.
        currentNow = currentNow.addingTimeInterval(120)
        placeManager?.pruneExpiredNotes()
        feed.pruneExpiredFollowingNotes()
        #expect(feed.items.isEmpty)
        feed.resetForPanic()
    }

    @Test
    func profileStore_defaultsOffPublishesKind0BatchesRemoteAndWipesOnPanic() throws {
        let keychain = PreviewKeychainManager()
        let me = try NostrIdentity.generate()
        let remote = try NostrIdentity.generate()
        var sentEvents: [NostrEvent] = []
        var subscribedIDs: [String] = []
        var unsubscribedIDs: [String] = []
        var remoteHandler: ((NostrEvent) -> Void)?
        var remoteEOSE: (() -> Void)?

        let deps = NostrProfileStoreDependencies(
            subscribe: { filter, id, onEvent, onEOSE in
                #expect(filter.kinds == [0])
                subscribedIDs.append(id)
                remoteHandler = onEvent
                remoteEOSE = onEOSE
            },
            unsubscribe: { unsubscribedIDs.append($0) },
            sendEvent: { sentEvents.append($0) },
            currentIdentity: { me },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let store = NostrProfileStore(keychain: keychain, dependencies: deps)
        #expect(!store.isPublicHandleEnabled)

        // Enable and publish kind 0
        let saved = store.saveAndPublishOwnProfile(.init(
            isEnabled: true,
            displayName: "Jack",
            about: "building bitchat",
            nip05: "jack@bitchat.free"
        ))
        #expect(saved)
        #expect(sentEvents.count == 1)
        #expect(sentEvents[0].kind == 0)
        #expect(store.displayName(for: me.publicKeyHex, fallbackNickname: nil) == "Jack")

        // Batch fetch remote profile, obey cooldown, auto-close on EOSE
        store.ensureProfiles(for: [remote.publicKeyHex])
        store.ensureProfiles(for: [remote.publicKeyHex]) // within cooldown -> skipped
        #expect(subscribedIDs.count == 1)

        let remoteMeta = try NostrProtocol.createMetadataEvent(
            profile: .init(name: "bob", displayName: "Bob Builder", about: nil, nip05: "bob@example.com"),
            senderIdentity: remote,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        remoteHandler?(remoteMeta)
        remoteEOSE?()

        #expect(unsubscribedIDs == subscribedIDs)
        #expect(store.displayName(for: remote.publicKeyHex, fallbackNickname: "fallback") == "Bob Builder")
        #expect(store.profile(for: remote.publicKeyHex)?.nip05 == "bob@example.com")

        // Panic wipe clears cache and Keychain profile
        store.resetForPanic()
        #expect(!store.isPublicHandleEnabled)
        #expect(store.profiles.isEmpty)
        let afterWipe = NostrProfileStore(keychain: keychain, dependencies: deps)
        #expect(!afterWipe.isPublicHandleEnabled)
    }

    @Test
    func locationNotesManager_publicHandleMirrorsToDefaultRelaysAndSupportsDelete() async throws {
        let placeID = try NostrIdentity.generate()
        let globalID = try NostrIdentity.generate()
        var geoSent: [NostrEvent] = []
        var defaultSent: [NostrEvent] = []

        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://geo.relay"] },
            subscribe: { _, _, _, _, _ in },
            unsubscribe: { _ in },
            sendEvent: { event, _ in geoSent.append(event) },
            deriveIdentity: { _ in placeID },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            publicIdentity: { globalID },
            sendToDefaultRelays: { defaultSent.append($0) }
        )

        let manager = LocationNotesManager(geohash: "9q8yy", dependencies: deps)
        #expect(manager.sendFeedPost(
            content: "hello from global handle",
            nickname: "Jack",
            identityMode: .publicHandle
        ))

        #expect(geoSent.count == 1)
        #expect(defaultSent.count == 1)
        #expect(geoSent[0].pubkey == globalID.publicKeyHex)
        let echoed = try #require(manager.notes.first)
        #expect(manager.isOwnNote(echoed))

        // Delete retracts on BOTH geo relays and default relays
        #expect(manager.delete(note: echoed))
        #expect(geoSent.count == 2)
        #expect(defaultSent.count == 2)
        #expect(geoSent[1].kind == NostrProtocol.EventKind.deletion.rawValue)
        #expect(defaultSent[1].kind == NostrProtocol.EventKind.deletion.rawValue)
        #expect(manager.notes.isEmpty)
    }

    @Test
    func homeFeedManager_mergesDeduplicatesScopesAndResetsOnPanic() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let me = try NostrIdentity.generate()
        let followedAuthor = try NostrIdentity.generate()
        let localStranger = try NostrIdentity.generate()

        var placeHandlers: [String: (NostrEvent) -> Void] = [:]
        var followingHandler: ((NostrEvent) -> Void)?
        var sentGlobal: [NostrEvent] = []
        var releasedCount = 0
        var unsubscribedIDs: [String] = []

        let homeDeps = HomeFeedDependencies(
            acquirePlaceManager: { gh in
                let placeDeps = LocationNotesDependencies(
                    relayLookup: { _, _ in ["wss://geo.relay"] },
                    subscribe: { _, _, _, onEvent, onEOSE in
                        placeHandlers[gh] = onEvent
                        onEOSE?()
                    },
                    unsubscribe: { _ in },
                    sendEvent: { _, _ in },
                    deriveIdentity: { _ in try NostrIdentity.generate() },
                    now: { now }
                )
                return LocationNotesManager(geohash: gh, dependencies: placeDeps)
            },
            releasePlaceManager: { manager in
                if manager != nil {
                    releasedCount += 1
                    manager?.cancel()
                }
            },
            subscribeDefaultRelays: { _, _, onEvent, onEOSE in
                followingHandler = onEvent
                onEOSE?()
            },
            unsubscribe: { unsubscribedIDs.append($0) },
            sendDefaultRelays: { sentGlobal.append($0) },
            publicIdentity: { me },
            ensureProfiles: { _ in },
            now: { now }
        )

        let feed = HomeFeedManager(dependencies: homeDeps)
        feed.activate(bookmarks: ["9q8yy"], followedPubkeys: [followedAuthor.publicKeyHex])

        // 1. Local stranger posts in Saved Place #9q8yy
        let localNote = try NostrProtocol.createGeohashTextNote(
            content: "sf fog rolling in",
            geohash: "9q8yy",
            senderIdentity: localStranger,
            nickname: "local",
            createdAt: now.addingTimeInterval(-120)
        )
        // 2. Followed author posts in #9q8yy (arrives via BOTH place relay and following relay)
        let crossPost = try NostrProtocol.createGeohashTextNote(
            content: "coffee at mission",
            geohash: "9q8yy",
            senderIdentity: followedAuthor,
            nickname: "friend",
            createdAt: now.addingTimeInterval(-60)
        )
        // 3. Followed author posts globally (no geohash)
        let globalPost = try NostrProtocol.createPublicTextNote(
            content: "global thought",
            senderIdentity: followedAuthor,
            nickname: "friend",
            createdAt: now
        )

        placeHandlers["9q8yy"]?(localNote)
        placeHandlers["9q8yy"]?(crossPost)
        followingHandler?(crossPost)
        followingHandler?(globalPost)

        // Deduplicated to 3 items total
        #expect(feed.items.count == 3)

        // Cross-post carries BOTH savedPlaceGeohash and isFromFollowedAuthor
        let mergedCross = try #require(feed.items.first(where: { $0.id == crossPost.id }))
        #expect(mergedCross.savedPlaceGeohash == "9q8yy")
        #expect(mergedCross.isFromFollowedAuthor)

        // Scope filters work accurately
        #expect(feed.filteredItems(scope: .savedPlaces, sort: .latest, filter: .all).count == 2)
        #expect(feed.filteredItems(scope: .following, sort: .latest, filter: .all).count == 2)

        // Global post send works
        #expect(feed.sendGlobalPost(content: "my global post", nickname: "me"))
        #expect(sentGlobal.count == 1)
        #expect(feed.items.contains(where: { $0.note.content == "my global post" }))

        // Panic wipe tears down subscriptions, releases managers, and clears state
        feed.resetForPanic()
        #expect(feed.items.isEmpty)
        #expect(releasedCount >= 1)
        #expect(!unsubscribedIDs.isEmpty)
    }

    @Test
    func homeFeedAndPublicProfileViewsRenderWithoutCrashing() {
        let locationManager = LocationChannelManager(storage: UserDefaults(suiteName: "HomeFeedSmoke-\(UUID().uuidString)") ?? .standard)
        let locationModel = LocationChannelsModel(manager: locationManager)
        let homeDeps = HomeFeedDependencies(
            acquirePlaceManager: { LocationNotesManager(geohash: $0, dependencies: LocationNotesDependencies(
                relayLookup: { _, _ in [] },
                subscribe: { _, _, _, _, _ in },
                unsubscribe: { _ in },
                sendEvent: { _, _ in },
                deriveIdentity: { _ in try NostrIdentity.generate() },
                now: Date.init
            )) },
            releasePlaceManager: { _ in },
            subscribeDefaultRelays: { _, _, _, onEOSE in onEOSE?() },
            unsubscribe: { _ in },
            sendDefaultRelays: { _ in },
            publicIdentity: { nil },
            ensureProfiles: { _ in },
            now: Date.init
        )
        let feedManager = HomeFeedManager(dependencies: homeDeps)

        let homeView = HomeFeedView(
            senderNickname: "tester",
            onSelectPlace: { _, _ in },
            onExplorePlaces: {},
            onOpenProfileSheet: {},
            feedManager: feedManager
        )
        .environmentObject(locationModel)

        let profileSheet = PublicProfileSheet(defaultNickname: "tester")

        #expect(String(describing: type(of: homeView)).contains("HomeFeedView"))
        #expect(String(describing: type(of: profileSheet)).contains("PublicProfileSheet"))
    }
}
