//
// NdrOutOfBandTransportTests.swift
// bitchatTests
//

import BitFoundation
import Foundation
import NdrFfi
import Testing
@testable import bitchat

@MainActor
final class FakeRelayManager: NostrRelayManaging {
    struct Subscription {
        let id: String
        let filter: NostrFilter
        let handler: (NostrEvent) -> Void
    }

    struct PendingPublish {
        let eventID: String
        let completion: (Bool) -> Void
    }

    private(set) var subscriptions: [Subscription] = []
    private(set) var unsubscribedIDs: [String] = []
    private(set) var sentEvents: [NostrEvent] = []
    private(set) var pendingPublishes: [PendingPublish] = []
    private var activeSubscriptionIDs = Set<String>()
    var automaticallyCompletePublishes = true
    var publishAccepted = true
    var subscriptionRegistrationSucceeds = true

    var activeSubscriptions: [Subscription] {
        activeSubscriptionIDs.compactMap { id in
            subscriptions.last(where: { $0.id == id })
        }
    }

    func resetSentEvents() {
        sentEvents.removeAll()
    }

    func subscribe(
        filter: NostrFilter,
        id: String,
        relayUrls: [String]?,
        handler: @escaping (NostrEvent) -> Void,
        onEOSE: (() -> Void)?
    ) -> Bool {
        guard subscriptionRegistrationSucceeds else { return false }
        subscriptions.append(
            Subscription(id: id, filter: filter, handler: handler)
        )
        activeSubscriptionIDs.insert(id)
        return true
    }

    func unsubscribe(id: String) {
        unsubscribedIDs.append(id)
        activeSubscriptionIDs.remove(id)
    }

    func sendEventImmediately(
        _ event: NostrEvent,
        to relayUrls: [String]?,
        completion: @escaping (Bool) -> Void
    ) {
        sentEvents.append(event)
        if automaticallyCompletePublishes {
            completion(publishAccepted)
        } else {
            pendingPublishes.append(
                PendingPublish(eventID: event.id, completion: completion)
            )
        }
    }

    func completeNextPublish(accepted: Bool) {
        guard !pendingPublishes.isEmpty else { return }
        pendingPublishes.removeFirst().completion(accepted)
    }

    func deliver(_ event: NostrEvent, to subscriptionID: String) {
        guard activeSubscriptionIDs.contains(subscriptionID),
              let subscription = subscriptions.last(where: {
                  $0.id == subscriptionID
              })
        else {
            return
        }
        subscription.handler(event)
    }

    @discardableResult
    func deliverMatching(_ event: NostrEvent) -> Bool {
        guard let subscription = activeSubscriptions.first(where: {
            ($0.filter.kinds?.contains(event.kind) ?? true)
                && ($0.filter.authors?.contains(event.pubkey) ?? true)
        }) else {
            return false
        }
        subscription.handler(event)
        return true
    }
}

@MainActor
private final class FakeNdrRetryScheduler {
    struct Scheduled {
        let delay: TimeInterval
        let operation: @MainActor () -> Void
    }

    private(set) var scheduled: [Scheduled] = []
    private(set) var requestedDelays: [TimeInterval] = []

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @MainActor () -> Void
    ) {
        requestedDelays.append(delay)
        scheduled.append(
            Scheduled(delay: delay, operation: operation)
        )
    }

    func runNext() {
        guard !scheduled.isEmpty else { return }
        scheduled.removeFirst().operation()
    }
}

@MainActor
private final class ControllableNdrSessionMarkerStore:
    NdrSessionMarkerStoring
{
    enum Failure: Error {
        case mark
        case clear
    }

    var failMark = false
    var failClear = false
    private var identities = Set<String>()

    func contains(identityPubkeyHex: String) throws -> Bool {
        identities.contains(identityPubkeyHex.lowercased())
    }

    func mark(identityPubkeyHex: String) throws {
        guard !failMark else { throw Failure.mark }
        identities.insert(identityPubkeyHex.lowercased())
    }

    func clear() throws {
        guard !failClear else { throw Failure.clear }
        identities.removeAll()
    }
}

private final class NdrDeliveryLifecycleOwner {}

@Suite(.serialized)
struct NdrOutOfBandTransportTests {
    @Test("Double-ratchet bootstrap uses the coordinated wire value")
    func wireValueIsCoordinated() {
        #expect(NoisePayloadType.ndrEvent.rawValue == 0x22)
        #expect(NoisePayloadType.decoded(rawValue: 0x22) == .ndrEvent)
        #expect(NoisePayloadType.decoded(rawValue: 0x12) == .vouch)
    }

    @Test("Double-ratchet rollout remains dark until coordination completes")
    @MainActor
    func rolloutGateIsDisabledByDefaultAndFailsClosed() throws {
        #expect(!DoubleRatchetFeature.isEnabled)
        #expect(!PeerCapabilities.localSupported.contains(.doubleRatchet))
        let identity = try NostrIdentity.generate()
        var requestedStorage = false
        let service = NdrNostrService(
            relayManager: FakeRelayManager(),
            rolloutEnabled: false,
            storageDirectoryProvider: {
                requestedStorage = true
                return try makeTempDir(label: "ndr-disabled-rollout")
            }
        )

        service.configureIfNeeded(identity: identity)

        #expect(!service.isConfigured)
        #expect(service.currentInviteEventJson() == nil)
        #expect(!requestedStorage)
    }

    @Test("A failed runtime open stays fail-closed until identity change")
    @MainActor
    func configurationFailureRequiresExplicitRecoveryBoundary() throws {
        enum StorageFailure: Error { case unavailable }

        let first = try NostrIdentity.generate()
        let second = try NostrIdentity.generate()
        let storage = try makeTempDir(label: "configuration-failure")
        var storageAvailable = false
        let service = NdrNostrService(
            relayManager: FakeRelayManager(),
            rolloutEnabled: true,
            storageDirectoryProvider: {
                guard storageAvailable else {
                    throw StorageFailure.unavailable
                }
                return storage
            }
        )

        service.configureIfNeeded(identity: first)
        storageAvailable = true
        service.configureIfNeeded(identity: first)
        #expect(
            service.send("blocked", to: second.publicKeyHex) == .failed
        )

        service.configureIfNeeded(identity: second)
        #expect(service.isConfigured)
        #expect(service.configuredPubkeyHex == second.publicKeyHex)
        #expect(service.send("no session", to: first.publicKeyHex) == .noSession)
    }

    @Test("Missing Application Support storage fails closed")
    @MainActor
    func missingApplicationSupportNeverFallsBackToTemporaryStorage() {
        do {
            _ = try NdrNostrService.ndrStorageDirectory(
                applicationSupportDirectory: nil
            )
            Issue.record("Expected missing Application Support to fail")
        } catch {
            #expect(
                error as? NdrStorageDirectoryError
                    == .applicationSupportUnavailable
            )
        }
    }

    @Test("An invite is bound to the authenticated favorite identity")
    @MainActor
    func inviteRejectsUnexpectedPeer() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let unexpected = try NostrIdentity.generate()
        let aliceService = try makeService(label: "invite-alice")
        let bobService = try makeService(label: "invite-bob")
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)

        let invite = try #require(aliceService.currentInviteEventJson())
        let responses = bobService.processOutOfBandEventJson(
            invite,
            expectedPeerPubkeyHex: unexpected.publicKeyHex,
            persistEstablishedBinding: { true }
        )

        #expect(responses.isEmpty)
        #expect(!bobService.hasActiveSession(with: alice.publicKeyHex))
    }

    @Test("A response is accepted only on its authenticated Noise route")
    @MainActor
    func responseRejectsUnexpectedPeerAndRelayInjection() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let unexpected = try NostrIdentity.generate()
        let aliceService = try makeService(label: "response-alice")
        let bobService = try makeService(label: "response-bob")
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)

        let invite = try #require(aliceService.currentInviteEventJson())
        let response = try #require(
            bobService.processOutOfBandEventJson(
                invite,
                expectedPeerPubkeyHex: alice.publicKeyHex,
                persistEstablishedBinding: { true }
            ).first(where: {
                (try? extractNostrKind(json: $0.eventJson)) == 1059
            })
        )

        let rejected = aliceService.processOutOfBandEventJson(
            response.eventJson,
            expectedPeerPubkeyHex: unexpected.publicKeyHex,
            persistEstablishedBinding: { true }
        )
        #expect(rejected.isEmpty)
        #expect(!aliceService.hasActiveSession(with: bob.publicKeyHex))

        let relayInjected = try JSONDecoder().decode(
            NostrEvent.self,
            from: Data(response.eventJson.utf8)
        )
        aliceService.processInboundRelayEvent(relayInjected)
        #expect(!aliceService.hasActiveSession(with: bob.publicKeyHex))
    }

    @Test("Decrypted events require exact pairwise sender attribution")
    @MainActor
    func decryptedEventRejectsClaimedSenderMismatch() throws {
        let authenticated = try NostrIdentity.generate()
        let claimed = try NostrIdentity.generate()
        let inner = try makeInnerMessageEvent(
            identity: authenticated,
            content: "bitchat1:matching"
        )
        let forged = try makeInnerMessageEvent(
            identity: claimed,
            content: "bitchat1:forged"
        )

        let matching = makeDeliveryAction(
            inner,
            authenticatedSender: authenticated.publicKeyHex
        )
        #expect(inner.sig == nil)
        #expect(
            NdrNostrService.validatedDecryptedMessage(from: matching)?
                .event.pubkey == authenticated.publicKeyHex
        )
        #expect(
            NdrNostrService.validatedDecryptedMessage(
                from: makeDeliveryAction(
                    forged,
                    authenticatedSender: authenticated.publicKeyHex
                )
            ) == nil
        )
        var invalidID = inner
        invalidID.id = String(repeating: "c", count: 64)
        #expect(
            NdrNostrService.validatedDecryptedMessage(
                from: makeDeliveryAction(
                    invalidID,
                    authenticatedSender: authenticated.publicKeyHex
                )
            ) == nil
        )
        #expect(
            !NdrNostrService.isExpiredDelivery(
                makeDeliveryAction(
                    inner,
                    authenticatedSender: authenticated.publicKeyHex
                ),
                now: Date(timeIntervalSince1970: 100)
            )
        )
        #expect(
            NdrNostrService.isExpiredDelivery(
                makeDeliveryAction(
                    inner,
                    authenticatedSender: authenticated.publicKeyHex,
                    expiresAtSeconds: 100
                ),
                now: Date(timeIntervalSince1970: 100)
            )
        )
        #expect(
            NdrNostrService.validatedDecryptedMessage(
                from: makeDeliveryAction(
                    inner,
                    authenticatedSender: authenticated.publicKeyHex,
                    innerEventID: String(repeating: "b", count: 64)
                )
            ) == nil
        )
    }

    @Test("A failed BLE handoff leaves its response durable for retry")
    @MainActor
    func failedOutOfBandHandoffRetriesUntilAccepted() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let aliceService = try makeService(label: "oob-retry-alice")
        let bobService = try makeService(label: "oob-retry-bob")
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)

        let invite = try #require(aliceService.currentInviteEventJson())
        let first = try #require(
            bobService.processOutOfBandEventJson(
                invite,
                expectedPeerPubkeyHex: alice.publicKeyHex,
                persistEstablishedBinding: { true }
            ).first
        )
        bobService.completeOutOfBandAction(first, succeeded: false)

        let retried = try #require(
            bobService.pendingOutOfBandActions(
                forAuthenticatedPeerPubkeyHex: alice.publicKeyHex,
                releaseDeferred: true
            ).first
        )
        #expect(retried.eventJson == first.eventJson)
        #expect(retried.peerPubkeyHex == alice.publicKeyHex)

        bobService.completeOutOfBandAction(retried, succeeded: true)
        #expect(
            bobService.pendingOutOfBandActions(
                forAuthenticatedPeerPubkeyHex: alice.publicKeyHex
            ).isEmpty
        )
    }

    @Test("Relay bootstrap waits for authenticated OOB handoff")
    @MainActor
    func bootstrapPublishWaitsForOutOfBandAck() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let bobRelay = FakeRelayManager()
        let aliceService = try makeService(label: "oob-order-alice")
        let bobService = try makeService(
            label: "oob-order-bob",
            relay: bobRelay
        )
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)

        let invite = try #require(aliceService.currentInviteEventJson())
        let first = try #require(
            bobService.processOutOfBandEventJson(
                invite,
                expectedPeerPubkeyHex: alice.publicKeyHex,
                persistEstablishedBinding: { true }
            ).first
        )
        #expect(bobRelay.sentEvents.filter { $0.kind == 1060 }.isEmpty)

        bobService.completeOutOfBandAction(first, succeeded: false)
        #expect(bobRelay.sentEvents.filter { $0.kind == 1060 }.isEmpty)

        let retried = try #require(
            bobService.pendingOutOfBandActions(
                forAuthenticatedPeerPubkeyHex: alice.publicKeyHex,
                releaseDeferred: true
            ).first
        )
        bobService.completeOutOfBandAction(retried, succeeded: true)

        #expect(bobRelay.sentEvents.filter { $0.kind == 1060 }.count == 1)
    }

    @Test("A half-ready session suppresses a second invite")
    @MainActor
    func acceptedInviteCreatesPairwiseRecordBeforeRelayBootstrap() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let aliceService = try makeService(label: "half-ready-alice")
        let bobService = try makeService(label: "half-ready-bob")
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)

        let invite = try #require(aliceService.currentInviteEventJson())
        let responses = bobService.processOutOfBandEventJson(
            invite,
            expectedPeerPubkeyHex: alice.publicKeyHex,
            persistEstablishedBinding: { true }
        )

        let response = try #require(responses.first)
        bobService.completeOutOfBandAction(response, succeeded: true)
        _ = aliceService.processOutOfBandEventJson(
            response.eventJson,
            expectedPeerPubkeyHex: bob.publicKeyHex,
            persistEstablishedBinding: { true }
        )

        #expect(aliceService.hasPairwiseSession(with: bob.publicKeyHex))
        #expect(!aliceService.hasActiveSession(with: bob.publicKeyHex))
    }

    @Test("An OOB response blocks only its own session")
    @MainActor
    func pendingOutOfBandDoesNotBlockAnotherPeerPublish() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let carol = try NostrIdentity.generate()
        let aliceRelay = FakeRelayManager()
        let bobRelay = FakeRelayManager()
        let aliceService = try makeService(
            label: "oob-isolation-alice",
            relay: aliceRelay
        )
        let bobService = try makeService(
            label: "oob-isolation-bob",
            relay: bobRelay
        )
        let carolService = try makeService(label: "oob-isolation-carol")
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)
        carolService.configureIfNeeded(identity: carol)
        try establishPairwiseSessions(
            aliceService,
            bobService,
            firstIdentity: alice,
            secondIdentity: bob,
            firstRelay: aliceRelay,
            secondRelay: bobRelay
        )

        aliceRelay.resetSentEvents()
        let carolInvite = try #require(
            carolService.currentInviteEventJson()
        )
        let pendingCarolResponse =
            aliceService.processOutOfBandEventJson(
                carolInvite,
                expectedPeerPubkeyHex: carol.publicKeyHex,
                persistEstablishedBinding: { true }
            )
        #expect(!pendingCarolResponse.isEmpty)
        #expect(aliceRelay.sentEvents.isEmpty)

        guard case .sent = aliceService.send(
            "bitchat1:unrelated-session",
            to: bob.publicKeyHex
        ) else {
            Issue.record("Expected established Bob session to send")
            return
        }
        #expect(aliceRelay.sentEvents.filter { $0.kind == 1060 }.count == 1)
    }

    @Test("Retiring one peer preserves unrelated pairwise sessions")
    @MainActor
    func peerRetirementIsTargetedAndIdempotent() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let carol = try NostrIdentity.generate()
        let aliceRelay = FakeRelayManager()
        let bobRelay = FakeRelayManager()
        let carolRelay = FakeRelayManager()
        let aliceService = try makeService(
            label: "retire-alice",
            relay: aliceRelay
        )
        let bobService = try makeService(
            label: "retire-bob",
            relay: bobRelay
        )
        let carolService = try makeService(
            label: "retire-carol",
            relay: carolRelay
        )
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)
        carolService.configureIfNeeded(identity: carol)
        try establishPairwiseSessions(
            aliceService,
            bobService,
            firstIdentity: alice,
            secondIdentity: bob,
            firstRelay: aliceRelay,
            secondRelay: bobRelay
        )
        try establishPairwiseSessions(
            aliceService,
            carolService,
            firstIdentity: alice,
            secondIdentity: carol,
            firstRelay: aliceRelay,
            secondRelay: carolRelay
        )

        #expect(aliceService.hasActiveSession(with: bob.publicKeyHex))
        #expect(aliceService.hasActiveSession(with: carol.publicKeyHex))
        #expect(aliceService.retirePeer(bob.publicKeyHex))
        #expect(!aliceService.hasPairwiseSession(with: bob.publicKeyHex))
        #expect(aliceService.hasActiveSession(with: carol.publicKeyHex))
        #expect(aliceService.retirePeer(bob.publicKeyHex))
        #expect(aliceService.currentInviteEventJson() != nil)
    }

    @Test("A favorite Nostr rebind retires only the old pairwise peer")
    @MainActor
    func favoriteIdentityRebindRetiresOldPeerBeforeNewInvite() throws {
        let relay = FakeRelayManager()
        let storage = try makeTempDir(label: "favorite-rebind-local")
        let service = NdrNostrService(
            relayManager: relay,
            rolloutEnabled: true,
            storageDirectoryProvider: { storage }
        )
        let (viewModel, transport, favoritesService) =
            makeViewModel(ndrService: service)
        let local = try #require(
            try viewModel.idBridge.getCurrentNostrIdentity()
        )
        let oldPeer = try NostrIdentity.generate()
        let newPeer = try NostrIdentity.generate()
        let oldPeerRelay = FakeRelayManager()
        let oldPeerService = try makeService(
            label: "favorite-rebind-old-peer",
            relay: oldPeerRelay
        )
        service.configureIfNeeded(identity: local)
        oldPeerService.configureIfNeeded(identity: oldPeer)
        try establishPairwiseSessions(
            service,
            oldPeerService,
            firstIdentity: local,
            secondIdentity: oldPeer,
            firstRelay: relay,
            secondRelay: oldPeerRelay
        )

        let noiseKey = try #require(
            Data(hexString: oldPeer.publicKeyHex)
        )
        let peerID = PeerID(str: "32435465768798a9")
        installMutualFavorite(
            in: favoritesService,
            noiseKey: noiseKey,
            nostrIdentity: oldPeer
        )
        defer {
            removeFavorite(in: favoritesService, noiseKey: noiseKey)
        }
        transport.authenticatedPeerTransportStates[peerID] =
            AuthenticatedPeerTransportState(
                capabilities: [.doubleRatchet],
                sessionGeneration: UUID(),
                noisePublicKey: noiseKey
            )

        viewModel.bootstrapDoubleRatchetIfNeeded(for: peerID)
        #expect(
            viewModel.ndrPeerPubkeyByNoiseKey[noiseKey]
                == oldPeer.publicKeyHex
        )
        #expect(service.hasActiveSession(with: oldPeer.publicKeyHex))

        favoritesService.updatePeerFavoritedUs(
            peerNoisePublicKey: noiseKey,
            favorited: true,
            peerNostrPublicKey: newPeer.npub
        )
        viewModel.bootstrapDoubleRatchetIfNeeded(for: peerID)

        #expect(
            viewModel.ndrPeerPubkeyByNoiseKey[noiseKey]
                == newPeer.publicKeyHex
        )
        #expect(!service.hasPairwiseSession(with: oldPeer.publicKeyHex))
        #expect(favoritesService.isNdrRequired(for: noiseKey))
        #expect(transport.sentNdrEvents.count == 1)
    }

    @Test("A failed durable favorite commit stays journaled after native retirement")
    @MainActor
    func favoriteRebindCommitFailureStaysFailClosed() throws {
        let relay = FakeRelayManager()
        let service = try makeService(
            label: "favorite-rebind-commit-failure",
            relay: relay
        )
        let favoritesKeychain = MockKeychain()
        let favoritesService = FavoritesPersistenceService(
            keychain: favoritesKeychain
        )
        let (viewModel, transport, _) = makeViewModel(
            ndrService: service,
            favoritesService: favoritesService
        )
        let local = try #require(
            try viewModel.idBridge.getCurrentNostrIdentity()
        )
        let oldPeer = try NostrIdentity.generate()
        let newPeer = try NostrIdentity.generate()
        let oldPeerRelay = FakeRelayManager()
        let oldPeerService = try makeService(
            label: "favorite-rebind-commit-failure-peer",
            relay: oldPeerRelay
        )
        service.configureIfNeeded(identity: local)
        oldPeerService.configureIfNeeded(identity: oldPeer)
        try establishPairwiseSessions(
            service,
            oldPeerService,
            firstIdentity: local,
            secondIdentity: oldPeer,
            firstRelay: relay,
            secondRelay: oldPeerRelay
        )

        let noiseKey = Data(repeating: 0xd1, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        installMutualFavorite(
            in: favoritesService,
            noiseKey: noiseKey,
            nostrIdentity: oldPeer
        )
        transport.authenticatedPeerTransportStates[peerID] =
            AuthenticatedPeerTransportState(
                capabilities: [.doubleRatchet],
                sessionGeneration: UUID(),
                noisePublicKey: noiseKey
            )
        viewModel.bootstrapDoubleRatchetIfNeeded(for: peerID)
        #expect(favoritesService.isNdrRequired(for: noiseKey))

        favoritesKeychain.simulatedGenericSaveFailureKeys.insert(
            "chat.bitchat.favorites"
        )
        favoritesService.updatePeerFavoritedUs(
            peerNoisePublicKey: noiseKey,
            favorited: true,
            peerNostrPublicKey: newPeer.npub
        )

        #expect(
            favoritesService.getFavoriteStatus(for: noiseKey)?
                .peerNostrPublicKey == oldPeer.npub
        )
        #expect(!service.hasPairwiseSession(with: oldPeer.publicKeyHex))
        #expect(
            favoritesService.isNdrFallbackBlocked(for: peerID)
        )
        #expect(
            !favoritesService.canUseNdrBinding(for: peerID)
        )
        #expect(
            favoritesKeychain.load(
                key:
                    "chat.bitchat.favorites.ndr-rebind-journal",
                service: "chat.bitchat.favorites"
            ) != nil
        )

        let replacementPeerService = try makeService(
            label: "favorite-rebind-commit-failure-replacement"
        )
        replacementPeerService.configureIfNeeded(identity: newPeer)
        let replacementInvite = try #require(
            replacementPeerService.currentInviteEventJson()
        )
        let sentOobCount = transport.sentNdrEvents.count

        viewModel.handleNdrEventPayload(
            from: peerID,
            payload: Data(replacementInvite.utf8)
        )

        #expect(transport.sentNdrEvents.count == sentOobCount)
        #expect(
            !service.hasPairwiseSession(with: newPeer.publicKeyHex)
        )
    }

    @Test("Unreadable binding state rejects authenticated OOB bootstrap")
    @MainActor
    func unreadableFavoriteBindingStateRejectsOutOfBandInvite() throws {
        let favoritesKeychain = MockKeychain()
        favoritesKeychain.simulatedGenericReadError = .accessDenied
        let favoritesService = FavoritesPersistenceService(
            keychain: favoritesKeychain
        )
        favoritesKeychain.simulatedGenericReadError = nil

        let localService = try makeService(
            label: "unreadable-binding-oob-local"
        )
        let (viewModel, transport, _) = makeViewModel(
            ndrService: localService,
            favoritesService: favoritesService
        )
        let remoteIdentity = try NostrIdentity.generate()
        let remoteService = try makeService(
            label: "unreadable-binding-oob-remote"
        )
        remoteService.configureIfNeeded(identity: remoteIdentity)
        let noiseKey = Data(repeating: 0xd3, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        installMutualFavorite(
            in: favoritesService,
            noiseKey: noiseKey,
            nostrIdentity: remoteIdentity
        )
        transport.authenticatedPeerTransportStates[peerID] =
            AuthenticatedPeerTransportState(
                capabilities: [.doubleRatchet],
                sessionGeneration: UUID(),
                noisePublicKey: noiseKey
            )
        let invite = try #require(
            remoteService.currentInviteEventJson()
        )

        viewModel.handleNdrEventPayload(
            from: peerID,
            payload: Data(invite.utf8)
        )

        #expect(transport.sentNdrEvents.isEmpty)
        #expect(
            !localService.hasPairwiseSession(
                with: remoteIdentity.publicKeyHex
            )
        )
    }

    @Test(
        "A durable pin still journals and retires while rollout is disabled"
    )
    @MainActor
    func pinnedFavoriteRebindRetiresAcrossGateOffAndReenable()
        throws
    {
        let storage = try makeTempDir(label: "favorite-rebind-gate-off")
        let markerStore = InMemoryNdrSessionMarkerStore()
        let nostrKeychain = MockKeychain()
        let favoritesKeychain = MockKeychain()
        let local = try #require(
            try NostrIdentityBridge(keychain: nostrKeychain)
                .getCurrentNostrIdentity()
        )
        let oldPeer = try NostrIdentity.generate()
        let newPeer = try NostrIdentity.generate()
        let noiseKey = Data(repeating: 0xd2, count: 32)
        let peerID = PeerID(publicKey: noiseKey)

        do {
            let localRelay = FakeRelayManager()
            let enabledService = NdrNostrService(
                relayManager: localRelay,
                rolloutEnabled: true,
                storageDirectoryProvider: { storage },
                sessionMarkerStore: markerStore
            )
            let favoritesService = FavoritesPersistenceService(
                keychain: favoritesKeychain
            )
            let (viewModel, transport, _) = makeViewModel(
                ndrService: enabledService,
                nostrKeychain: nostrKeychain,
                favoritesService: favoritesService
            )
            let peerRelay = FakeRelayManager()
            let peerService = try makeService(
                label: "favorite-rebind-gate-off-peer",
                relay: peerRelay
            )
            enabledService.configureIfNeeded(identity: local)
            peerService.configureIfNeeded(identity: oldPeer)
            try establishPairwiseSessions(
                enabledService,
                peerService,
                firstIdentity: local,
                secondIdentity: oldPeer,
                firstRelay: localRelay,
                secondRelay: peerRelay
            )
            installMutualFavorite(
                in: favoritesService,
                noiseKey: noiseKey,
                nostrIdentity: oldPeer
            )
            transport.authenticatedPeerTransportStates[peerID] =
                AuthenticatedPeerTransportState(
                    capabilities: [.doubleRatchet],
                    sessionGeneration: UUID(),
                    noisePublicKey: noiseKey
                )
            viewModel.bootstrapDoubleRatchetIfNeeded(for: peerID)
            #expect(favoritesService.isNdrRequired(for: noiseKey))
        }

        let disabledService = NdrNostrService(
            relayManager: FakeRelayManager(),
            rolloutEnabled: false,
            storageDirectoryProvider: { storage },
            sessionMarkerStore: markerStore
        )
        let restoredFavorites = FavoritesPersistenceService(
            keychain: favoritesKeychain
        )
        let (disabledViewModel, _, _) = makeViewModel(
            ndrService: disabledService,
            nostrKeychain: nostrKeychain,
            favoritesService: restoredFavorites
        )
        restoredFavorites.updatePeerFavoritedUs(
            peerNoisePublicKey: noiseKey,
            favorited: true,
            peerNostrPublicKey: newPeer.npub
        )

        #expect(
            restoredFavorites.getFavoriteStatus(for: noiseKey)?
                .peerNostrPublicKey == newPeer.npub
        )
        #expect(
            favoritesKeychain.load(
                key:
                    "chat.bitchat.favorites.ndr-rebind-journal",
                service: "chat.bitchat.favorites"
            ) == nil
        )

        let reenabledService = NdrNostrService(
            relayManager: FakeRelayManager(),
            rolloutEnabled: true,
            storageDirectoryProvider: { storage },
            sessionMarkerStore: markerStore
        )
        reenabledService.configureIfNeeded(identity: local)
        #expect(
            !reenabledService.hasPairwiseSession(
                with: oldPeer.publicKeyHex
            )
        )
        _ = disabledViewModel
    }

    @Test("A favorite rebind after restart retires persisted pairwise state")
    @MainActor
    func restoredFavoriteRebindRetiresOldPeerBeforeMutation() throws {
        let storage = try makeTempDir(label: "favorite-rebind-restart")
        let markerStore = InMemoryNdrSessionMarkerStore()
        let nostrKeychain = MockKeychain()
        let local = try #require(
            try NostrIdentityBridge(keychain: nostrKeychain)
                .getCurrentNostrIdentity()
        )
        let oldPeer = try NostrIdentity.generate()
        let newPeer = try NostrIdentity.generate()
        let oldPeerRelay = FakeRelayManager()
        let firstRelay = FakeRelayManager()

        do {
            let firstService = NdrNostrService(
                relayManager: firstRelay,
                rolloutEnabled: true,
                storageDirectoryProvider: { storage },
                sessionMarkerStore: markerStore
            )
            let (firstViewModel, _, _) = makeViewModel(
                ndrService: firstService,
                nostrKeychain: nostrKeychain
            )
            let oldPeerService = try makeService(
                label: "favorite-rebind-restart-peer",
                relay: oldPeerRelay
            )
            firstService.configureIfNeeded(identity: local)
            oldPeerService.configureIfNeeded(identity: oldPeer)
            try establishPairwiseSessions(
                firstService,
                oldPeerService,
                firstIdentity: local,
                secondIdentity: oldPeer,
                firstRelay: firstRelay,
                secondRelay: oldPeerRelay
            )
            #expect(
                firstService.hasActiveSession(
                    with: oldPeer.publicKeyHex
                )
            )
            _ = firstViewModel
        }

        let restoredService = NdrNostrService(
            relayManager: FakeRelayManager(),
            rolloutEnabled: true,
            storageDirectoryProvider: { storage },
            sessionMarkerStore: markerStore
        )
        let (restoredViewModel, restoredTransport, favoritesService) =
            makeViewModel(
            ndrService: restoredService,
            nostrKeychain: nostrKeychain
        )
        let noiseKey = Data((33..<65).map(UInt8.init))
        installMutualFavorite(
            in: favoritesService,
            noiseKey: noiseKey,
            nostrIdentity: oldPeer
        )
        defer {
            removeFavorite(in: favoritesService, noiseKey: noiseKey)
        }
        #expect(restoredViewModel.ndrPeerPubkeyByNoiseKey.isEmpty)
        #expect(restoredTransport.authenticatedPeerTransportStates.isEmpty)

        favoritesService.updatePeerFavoritedUs(
            peerNoisePublicKey: noiseKey,
            favorited: true,
            peerNostrPublicKey: newPeer.npub
        )

        #expect(
            favoritesService
                .getFavoriteStatus(for: noiseKey)?
                .peerNostrPublicKey == newPeer.npub
        )
        #expect(
            !restoredService.hasPairwiseSession(
                with: oldPeer.publicKeyHex
            )
        )
    }

    @Test("A shared old identity remains until its last Noise binding moves")
    @MainActor
    func sharedOldFavoriteBindingPreservesPairwiseSession() throws {
        let local = try NostrIdentity.generate()
        let oldPeer = try NostrIdentity.generate()
        let firstNewPeer = try NostrIdentity.generate()
        let secondNewPeer = try NostrIdentity.generate()
        let localRelay = FakeRelayManager()
        let oldPeerRelay = FakeRelayManager()
        let storage = try makeTempDir(
            label: "favorite-shared-old-local"
        )
        let markerStore = InMemoryNdrSessionMarkerStore()
        let localService = NdrNostrService(
            relayManager: localRelay,
            rolloutEnabled: true,
            storageDirectoryProvider: { storage },
            sessionMarkerStore: markerStore
        )
        let oldPeerService = try makeService(
            label: "favorite-shared-old-peer",
            relay: oldPeerRelay
        )
        localService.configureIfNeeded(identity: local)
        oldPeerService.configureIfNeeded(identity: oldPeer)
        try establishPairwiseSessions(
            localService,
            oldPeerService,
            firstIdentity: local,
            secondIdentity: oldPeer,
            firstRelay: localRelay,
            secondRelay: oldPeerRelay
        )

        let nostrKeychain = MockKeychain()
        let identityData = try JSONEncoder().encode(local)
        nostrKeychain.save(
            key: "nostr-current-identity",
            data: identityData,
            service: "chat.bitchat.nostr",
            accessible: nil
        )
        let favoritesService = FavoritesPersistenceService(
            keychain: MockKeychain()
        )
        let firstNoiseKey = Data((65..<97).map(UInt8.init))
        let secondNoiseKey = Data((97..<129).map(UInt8.init))
        // Model legacy persisted data created before one-to-one assignment
        // authorization was installed.
        installMutualFavorite(
            in: favoritesService,
            noiseKey: firstNoiseKey,
            nostrIdentity: oldPeer
        )
        installMutualFavorite(
            in: favoritesService,
            noiseKey: secondNoiseKey,
            nostrIdentity: oldPeer
        )
        let (viewModel, _, _) = makeViewModel(
            ndrService: localService,
            nostrKeychain: nostrKeychain,
            favoritesService: favoritesService
        )
        defer {
            removeFavorite(
                in: favoritesService,
                noiseKey: firstNoiseKey
            )
            removeFavorite(
                in: favoritesService,
                noiseKey: secondNoiseKey
            )
        }

        favoritesService.updatePeerFavoritedUs(
            peerNoisePublicKey: firstNoiseKey,
            favorited: true,
            peerNostrPublicKey: firstNewPeer.npub
        )

        #expect(
            favoritesService
                .getFavoriteStatus(for: firstNoiseKey)?
                .peerNostrPublicKey == firstNewPeer.npub
        )
        #expect(
            localService.hasActiveSession(with: oldPeer.publicKeyHex)
        )
        #expect(
            viewModel.ndrPeerPubkeyByNoiseKey[firstNoiseKey]
                == firstNewPeer.publicKeyHex
        )

        favoritesService.updatePeerFavoritedUs(
            peerNoisePublicKey: secondNoiseKey,
            favorited: true,
            peerNostrPublicKey: secondNewPeer.npub
        )
        #expect(
            !localService.hasPairwiseSession(
                with: oldPeer.publicKeyHex
            )
        )
        #expect(
            viewModel.ndrPeerPubkeyByNoiseKey[secondNoiseKey]
                == secondNewPeer.publicKeyHex
        )

        let restartedService = NdrNostrService(
            relayManager: FakeRelayManager(),
            rolloutEnabled: true,
            storageDirectoryProvider: { storage },
            sessionMarkerStore: markerStore
        )
        restartedService.configureIfNeeded(identity: local)
        #expect(
            !restartedService.hasPairwiseSession(
                with: oldPeer.publicKeyHex
            )
        )
    }

    @Test("A Nostr identity cannot be rebound to a second Noise key")
    @MainActor
    func favoriteRebindRejectsDuplicateNewIdentityBinding() throws {
        let service = try makeService(label: "favorite-one-to-one")
        let (viewModel, _, favoritesService) =
            makeViewModel(ndrService: service)
        let oldPeer = try NostrIdentity.generate()
        let alreadyBoundPeer = try NostrIdentity.generate()
        let firstNoiseKey = Data((129..<161).map(UInt8.init))
        let secondNoiseKey = Data((161..<193).map(UInt8.init))
        installMutualFavorite(
            in: favoritesService,
            noiseKey: firstNoiseKey,
            nostrIdentity: oldPeer
        )
        installMutualFavorite(
            in: favoritesService,
            noiseKey: secondNoiseKey,
            nostrIdentity: alreadyBoundPeer
        )
        defer {
            removeFavorite(
                in: favoritesService,
                noiseKey: firstNoiseKey
            )
            removeFavorite(
                in: favoritesService,
                noiseKey: secondNoiseKey
            )
        }

        favoritesService.updatePeerFavoritedUs(
            peerNoisePublicKey: firstNoiseKey,
            favorited: true,
            peerNostrPublicKey: alreadyBoundPeer.npub
        )

        #expect(
            favoritesService
                .getFavoriteStatus(for: firstNoiseKey)?
                .peerNostrPublicKey == oldPeer.npub
        )
        _ = viewModel
    }

    @Test("Initial favorite assignment rejects a duplicate Nostr identity")
    @MainActor
    func initialFavoriteAssignmentRejectsDuplicateIdentity() throws {
        let service = try makeService(label: "favorite-initial-duplicate")
        let (viewModel, _, favoritesService) =
            makeViewModel(ndrService: service)
        let peer = try NostrIdentity.generate()
        let firstNoiseKey = Data(repeating: 0xa1, count: 32)
        let secondNoiseKey = Data(repeating: 0xa2, count: 32)
        defer {
            removeFavorite(
                in: favoritesService,
                noiseKey: firstNoiseKey
            )
            removeFavorite(
                in: favoritesService,
                noiseKey: secondNoiseKey
            )
        }

        favoritesService.addFavorite(
            peerNoisePublicKey: firstNoiseKey,
            peerNostrPublicKey: peer.npub,
            peerNickname: "First NDR test peer"
        )
        favoritesService.addFavorite(
            peerNoisePublicKey: secondNoiseKey,
            peerNostrPublicKey: peer.npub,
            peerNickname: "Second NDR test peer"
        )

        #expect(
            favoritesService
                .getFavoriteStatus(for: firstNoiseKey)?
                .peerNostrPublicKey == peer.npub
        )
        #expect(
            favoritesService.getFavoriteStatus(for: secondNoiseKey) == nil
        )
        _ = viewModel
    }

    @Test("Nil favorite assignment rejects a duplicate Nostr identity")
    @MainActor
    func nilFavoriteAssignmentRejectsDuplicateIdentity() throws {
        let service = try makeService(label: "favorite-nil-duplicate")
        let (viewModel, _, favoritesService) =
            makeViewModel(ndrService: service)
        let peer = try NostrIdentity.generate()
        let firstNoiseKey = Data(repeating: 0xb1, count: 32)
        let secondNoiseKey = Data(repeating: 0xb2, count: 32)
        defer {
            removeFavorite(
                in: favoritesService,
                noiseKey: firstNoiseKey
            )
            removeFavorite(
                in: favoritesService,
                noiseKey: secondNoiseKey
            )
        }

        favoritesService.addFavorite(
            peerNoisePublicKey: firstNoiseKey,
            peerNostrPublicKey: peer.npub,
            peerNickname: "First NDR test peer"
        )
        favoritesService.addFavorite(
            peerNoisePublicKey: secondNoiseKey,
            peerNickname: "Second NDR test peer"
        )
        favoritesService.updatePeerFavoritedUs(
            peerNoisePublicKey: secondNoiseKey,
            favorited: true,
            peerNostrPublicKey: peer.npub
        )

        let secondRelationship =
            favoritesService.getFavoriteStatus(for: secondNoiseKey)
        #expect(secondRelationship?.peerNostrPublicKey == nil)
        #expect(secondRelationship?.theyFavoritedUs == false)
        _ = viewModel
    }

    @Test("Malformed favorite identity rebinds fail closed")
    @MainActor
    func favoriteRebindRejectsMalformedOldOrNewIdentity() throws {
        let service = try makeService(label: "favorite-malformed-rebind")
        let favoritesService = FavoritesPersistenceService(
            keychain: MockKeychain()
        )
        let malformedOldNoiseKey = Data(repeating: 0xc1, count: 32)
        // Model malformed legacy data loaded before assignment authorization.
        favoritesService.addFavorite(
            peerNoisePublicKey: malformedOldNoiseKey,
            peerNostrPublicKey: "malformed-old",
            peerNickname: "Malformed NDR test peer"
        )
        let (viewModel, _, _) =
            makeViewModel(
                ndrService: service,
                favoritesService: favoritesService
            )
        let validPeer = try NostrIdentity.generate()
        let validOldNoiseKey = Data(repeating: 0xc2, count: 32)

        installMutualFavorite(
            in: favoritesService,
            noiseKey: validOldNoiseKey,
            nostrIdentity: validPeer
        )
        defer {
            removeFavorite(
                in: favoritesService,
                noiseKey: validOldNoiseKey
            )
            removeFavorite(
                in: favoritesService,
                noiseKey: malformedOldNoiseKey
            )
        }

        favoritesService.updatePeerFavoritedUs(
            peerNoisePublicKey: validOldNoiseKey,
            favorited: true,
            peerNostrPublicKey: "malformed-new"
        )
        #expect(
            favoritesService
                .getFavoriteStatus(for: validOldNoiseKey)?
                .peerNostrPublicKey == validPeer.npub
        )

        favoritesService.updatePeerFavoritedUs(
            peerNoisePublicKey: malformedOldNoiseKey,
            favorited: true,
            peerNostrPublicKey: validPeer.npub
        )
        #expect(
            favoritesService
                .getFavoriteStatus(for: malformedOldNoiseKey)?
                .peerNostrPublicKey == "malformed-old"
        )
        _ = viewModel
    }

    @Test("A failed invite retries without a reconnect")
    @MainActor
    func failedInviteRetriesWithCurrentAuthenticatedBinding() async throws {
        let relay = FakeRelayManager()
        let retryScheduler = FakeNdrRetryScheduler()
        let storage = try makeTempDir(label: "invite-host-retry")
        let service = NdrNostrService(
            relayManager: relay,
            rolloutEnabled: true,
            storageDirectoryProvider: { storage },
            retryScheduler: retryScheduler.schedule
        )
        let (viewModel, transport, favoritesService) =
            makeViewModel(ndrService: service)
        let remote = try NostrIdentity.generate()
        let noiseKey = try #require(
            Data(hexString: remote.publicKeyHex)
        )
        let peerID = PeerID(str: "1021324354657687")
        let binding = AuthenticatedPeerTransportState(
            capabilities: [.doubleRatchet],
            sessionGeneration: UUID(),
            noisePublicKey: noiseKey
        )
        installMutualFavorite(
            in: favoritesService,
            noiseKey: noiseKey,
            nostrIdentity: remote
        )
        defer {
            removeFavorite(in: favoritesService, noiseKey: noiseKey)
        }
        transport.authenticatedPeerTransportStates[peerID] = binding
        transport.ndrSendResults = [false, true]

        viewModel.bootstrapDoubleRatchetIfNeeded(for: peerID)
        #expect(transport.sentNdrEvents.count == 1)
        viewModel.bootstrapDoubleRatchetIfNeeded(for: peerID)
        viewModel.bootstrapDoubleRatchetIfNeeded(for: peerID)
        #expect(
            transport.sentNdrEvents.count == 1,
            "repeated triggers must share one invite retry chain"
        )
        let retryScheduled = await TestHelpers.waitUntil(
            { !retryScheduler.scheduled.isEmpty },
            timeout: TestConstants.settleTimeout
        )
        #expect(retryScheduled)
        #expect(retryScheduler.requestedDelays == [0.25])

        retryScheduler.runNext()

        #expect(transport.sentNdrEvents.count == 2)
        viewModel.bootstrapDoubleRatchetIfNeeded(for: peerID)
        #expect(
            transport.sentNdrEvents.count == 2,
            "a handed-off invite stays deduplicated until the binding changes"
        )
        #expect(
            transport.sentNdrEvents.allSatisfy {
                $0.expectedTransportState == binding
            }
        )
    }

    @Test("Every failed OOB retry revalidates Noise generation and favorite")
    @MainActor
    func outOfBandRetryRejectsStaleBindingsAndRemainsDurable() async throws {
        let relay = FakeRelayManager()
        let retryScheduler = FakeNdrRetryScheduler()
        let storage = try makeTempDir(label: "oob-host-retry")
        let service = NdrNostrService(
            relayManager: relay,
            rolloutEnabled: true,
            storageDirectoryProvider: { storage },
            retryScheduler: retryScheduler.schedule
        )
        let (viewModel, transport, favoritesService) =
            makeViewModel(ndrService: service)
        let remoteIdentity = try NostrIdentity.generate()
        let remoteService = try makeService(label: "oob-host-remote")
        remoteService.configureIfNeeded(identity: remoteIdentity)
        let noiseKey = try #require(
            Data(hexString: remoteIdentity.publicKeyHex)
        )
        let peerID = PeerID(str: "2132435465768798")
        let firstBinding = AuthenticatedPeerTransportState(
            capabilities: [.doubleRatchet],
            sessionGeneration: UUID(),
            noisePublicKey: noiseKey
        )
        installMutualFavorite(
            in: favoritesService,
            noiseKey: noiseKey,
            nostrIdentity: remoteIdentity
        )
        defer {
            removeFavorite(in: favoritesService, noiseKey: noiseKey)
        }
        transport.authenticatedPeerTransportStates[peerID] = firstBinding
        transport.ndrSendResults = [false, false, true]

        let invite = try #require(
            remoteService.currentInviteEventJson()
        )
        viewModel.handleNdrEventPayload(
            from: peerID,
            payload: Data(invite.utf8)
        )
        #expect(transport.sentNdrEvents.count == 1)
        let firstRetryScheduled = await TestHelpers.waitUntil(
            { !retryScheduler.scheduled.isEmpty },
            timeout: TestConstants.settleTimeout
        )
        #expect(firstRetryScheduled)

        let secondBinding = AuthenticatedPeerTransportState(
            capabilities: [.doubleRatchet],
            sessionGeneration: UUID(),
            noisePublicKey: noiseKey
        )
        transport.authenticatedPeerTransportStates[peerID] = secondBinding
        retryScheduler.runNext()
        #expect(
            transport.sentNdrEvents.count == 1,
            "the old Noise generation must not be retried"
        )

        viewModel.bootstrapDoubleRatchetIfNeeded(for: peerID)
        #expect(transport.sentNdrEvents.count == 2)
        let secondRetryScheduled = await TestHelpers.waitUntil(
            { !retryScheduler.scheduled.isEmpty },
            timeout: TestConstants.settleTimeout
        )
        #expect(secondRetryScheduled)
        favoritesService.updatePeerFavoritedUs(
            peerNoisePublicKey: noiseKey,
            favorited: false
        )
        retryScheduler.runNext()
        #expect(
            transport.sentNdrEvents.count == 2,
            "a revoked favorite must stop the retry"
        )

        favoritesService.updatePeerFavoritedUs(
            peerNoisePublicKey: noiseKey,
            favorited: true,
            peerNostrPublicKey: remoteIdentity.npub
        )
        viewModel.bootstrapDoubleRatchetIfNeeded(for: peerID)
        #expect(transport.sentNdrEvents.count == 3)
        #expect(
            transport.sentNdrEvents.last?.expectedTransportState
                == secondBinding
        )
    }

    @Test("A relay rejection retries without waiting for reconnect")
    @MainActor
    func rejectedPublishRetriesUntilNip01Acceptance() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let aliceRelay = FakeRelayManager()
        let retryScheduler = FakeNdrRetryScheduler()
        let aliceStorage = try makeTempDir(label: "publish-retry-alice")
        let aliceService = NdrNostrService(
            relayManager: aliceRelay,
            rolloutEnabled: true,
            storageDirectoryProvider: { aliceStorage },
            retryScheduler: retryScheduler.schedule
        )
        let bobRelay = FakeRelayManager()
        let bobService = try makeService(
            label: "publish-retry-bob",
            relay: bobRelay
        )
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)
        try establishPairwiseSessions(
            aliceService,
            bobService,
            firstIdentity: alice,
            secondIdentity: bob,
            firstRelay: aliceRelay,
            secondRelay: bobRelay
        )

        aliceRelay.resetSentEvents()
        aliceRelay.automaticallyCompletePublishes = false
        let result = aliceService.send(
            "bitchat1:retry-me",
            to: bob.publicKeyHex
        )
        guard case let .sent(_, outerEventID) = result else {
            Issue.record("Expected a pairwise send")
            return
        }
        #expect(aliceRelay.pendingPublishes.count == 1)
        #expect(aliceRelay.sentEvents.map(\.id) == [outerEventID])

        aliceRelay.completeNextPublish(accepted: false)
        #expect(retryScheduler.scheduled.map(\.delay) == [0.25])
        retryScheduler.runNext()
        #expect(aliceRelay.pendingPublishes.count == 1)
        #expect(
            aliceRelay.sentEvents.filter { $0.id == outerEventID }.count == 2
        )

        aliceRelay.completeNextPublish(accepted: true)
        #expect(retryScheduler.scheduled.isEmpty)
        #expect(
            aliceRelay.sentEvents.filter { $0.id == outerEventID }.count == 2
        )
    }

    @Test("A connectivity wake invalidates the old relay retry timer")
    @MainActor
    func connectivityWakeDoesNotDoubleRunStaleRetryTimer() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let relay = FakeRelayManager()
        let retryScheduler = FakeNdrRetryScheduler()
        let storage = try makeTempDir(label: "publish-retry-token-alice")
        let aliceService = NdrNostrService(
            relayManager: relay,
            rolloutEnabled: true,
            storageDirectoryProvider: { storage },
            retryScheduler: retryScheduler.schedule
        )
        let bobRelay = FakeRelayManager()
        let bobService = try makeService(
            label: "publish-retry-token-bob",
            relay: bobRelay
        )
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)
        try establishPairwiseSessions(
            aliceService,
            bobService,
            firstIdentity: alice,
            secondIdentity: bob,
            firstRelay: relay,
            secondRelay: bobRelay
        )

        relay.resetSentEvents()
        relay.automaticallyCompletePublishes = false
        guard case let .sent(_, outerEventID) = aliceService.send(
            "bitchat1:retry-token",
            to: bob.publicKeyHex
        ) else {
            Issue.record("Expected a pairwise send")
            return
        }

        relay.completeNextPublish(accepted: false)
        #expect(retryScheduler.scheduled.count == 1)

        aliceService.retryRelayActions()
        #expect(
            relay.sentEvents.filter { $0.id == outerEventID }.count == 2
        )
        relay.completeNextPublish(accepted: false)
        #expect(retryScheduler.scheduled.count == 2)

        retryScheduler.runNext()
        #expect(
            relay.sentEvents.filter { $0.id == outerEventID }.count == 2,
            "the timer from the previous connectivity epoch must be inert"
        )

        retryScheduler.runNext()
        #expect(
            relay.sentEvents.filter { $0.id == outerEventID }.count == 3
        )
    }

    @Test("Relay retry backoff is bounded")
    @MainActor
    func rejectedPublishStopsAfterBoundedBackoff() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let relay = FakeRelayManager()
        let retryScheduler = FakeNdrRetryScheduler()
        let storage = try makeTempDir(label: "publish-bounded-alice")
        let aliceService = NdrNostrService(
            relayManager: relay,
            rolloutEnabled: true,
            storageDirectoryProvider: { storage },
            retryScheduler: retryScheduler.schedule
        )
        let bobRelay = FakeRelayManager()
        let bobService = try makeService(
            label: "publish-bounded-bob",
            relay: bobRelay
        )
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)
        try establishPairwiseSessions(
            aliceService,
            bobService,
            firstIdentity: alice,
            secondIdentity: bob,
            firstRelay: relay,
            secondRelay: bobRelay
        )

        relay.resetSentEvents()
        relay.automaticallyCompletePublishes = false
        guard case let .sent(_, outerEventID) = aliceService.send(
            "bitchat1:bounded-retry",
            to: bob.publicKeyHex
        ) else {
            Issue.record("Expected a pairwise send")
            return
        }

        for _ in 0..<4 {
            relay.completeNextPublish(accepted: false)
            retryScheduler.runNext()
        }
        relay.completeNextPublish(accepted: false)

        #expect(
            retryScheduler.requestedDelays == [0.25, 0.5, 1, 2]
        )
        #expect(retryScheduler.scheduled.isEmpty)
        #expect(
            relay.sentEvents.filter { $0.id == outerEventID }.count == 5
        )

        _ = aliceService.processOutOfBandEventJson(
            "not-a-valid-oob-event",
            expectedPeerPubkeyHex: bob.publicKeyHex,
            persistEstablishedBinding: { true }
        )
        #expect(
            relay.sentEvents.filter { $0.id == outerEventID }.count == 5,
            "invalid OOB traffic must not release unrelated relay deferrals"
        )
        for _ in 0..<3 {
            aliceService.configureIfNeeded(identity: alice)
        }
        #expect(
            relay.sentEvents.filter { $0.id == outerEventID }.count == 5,
            "ordinary sends/configuration must not reset an exhausted budget"
        )
        guard case .sent = aliceService.send(
            "bitchat1:unrelated-traffic",
            to: bob.publicKeyHex
        ) else {
            Issue.record("Expected unrelated pairwise send")
            return
        }
        #expect(
            relay.sentEvents.filter { $0.id == outerEventID }.count == 5
        )
    }

    @Test("Connectivity recovery wakes a subscription after retry exhaustion")
    @MainActor
    func subscriptionRegistrationRetriesWithoutRestart() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let relay = FakeRelayManager()
        relay.subscriptionRegistrationSucceeds = false
        let retryScheduler = FakeNdrRetryScheduler()
        let storage = try makeTempDir(label: "subscription-retry-alice")
        let aliceService = NdrNostrService(
            relayManager: relay,
            rolloutEnabled: true,
            storageDirectoryProvider: { storage },
            retryScheduler: retryScheduler.schedule
        )
        let bobRelay = FakeRelayManager()
        let bobService = try makeService(
            label: "subscription-retry-bob",
            relay: bobRelay
        )
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)

        try establishPairwiseSessions(
            aliceService,
            bobService,
            firstIdentity: alice,
            secondIdentity: bob,
            firstRelay: relay,
            secondRelay: bobRelay
        )

        #expect(relay.activeSubscriptions.isEmpty)
        while !retryScheduler.scheduled.isEmpty {
            retryScheduler.runNext()
        }
        #expect(
            Array(retryScheduler.requestedDelays.suffix(4))
                == [0.25, 0.5, 1, 2]
        )
        #expect(relay.activeSubscriptions.isEmpty)

        relay.subscriptionRegistrationSucceeds = true
        aliceService.retryRelayActions()
        #expect(
            relay.activeSubscriptions.contains {
                $0.filter.kinds == [1060]
            }
        )
    }

    @Test("A restart drains mixed durable actions beyond one host batch")
    @MainActor
    func restartDrainsMoreThanMaximumActionBatch() async throws {
        let storage = try makeTempDir(label: "large-action-batch")
        let aliceKeys = generateKeypair()
        let bobKeys = generateKeypair()
        let aliceIdentity = try NostrIdentity(
            privateKeyData: try #require(
                Data(hexString: aliceKeys.privateKeyHex)
            )
        )
        let managerPath = storage
            .appendingPathComponent("pairwise-v1", isDirectory: true)
            .appendingPathComponent(
                aliceKeys.publicKeyHex,
                isDirectory: true
            )
            .path
        try seedMixedPendingActions(
            outboundCount: 127,
            deliveryCount: 128,
            senderKeys: aliceKeys,
            peerKeys: bobKeys,
            storagePath: managerPath
        )

        let relay = FakeRelayManager()
        let restored = NdrNostrService(
            relayManager: relay,
            rolloutEnabled: true,
            storageDirectoryProvider: { storage }
        )
        var deliveredCount = 0
        restored.onDecryptedMessage = { _, completion in
            deliveredCount += 1
            completion(.consumed)
        }
        restored.configureIfNeeded(identity: aliceIdentity)

        let drained = await TestHelpers.waitUntil(
            {
                relay.sentEvents.filter { $0.kind == 1060 }.count == 127
                    && deliveredCount == 128
            },
            timeout: TestConstants.settleTimeout
        )
        #expect(drained)
        restored.retryRelayActions()
        #expect(relay.sentEvents.filter { $0.kind == 1060 }.count == 127)
        #expect(deliveredCount == 128)
    }

    @Test("The FFI remains the durable delivery queue until explicit ack")
    @MainActor
    func decryptedDeliveryRetriesUntilConsumerAcknowledges() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let aliceRelay = FakeRelayManager()
        let aliceService = try makeService(
            label: "delivery-alice",
            relay: aliceRelay
        )
        let bobRelay = FakeRelayManager()
        let bobService = try makeService(
            label: "delivery-bob",
            relay: bobRelay
        )
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)
        try establishPairwiseSessions(
            aliceService,
            bobService,
            firstIdentity: alice,
            secondIdentity: bob,
            firstRelay: aliceRelay,
            secondRelay: bobRelay
        )

        aliceRelay.resetSentEvents()
        guard case .sent = aliceService.send(
            "bitchat1:durable",
            to: bob.publicKeyHex
        ) else {
            Issue.record("Expected a pairwise send")
            return
        }
        let outer = try #require(
            aliceRelay.sentEvents.first(where: { $0.kind == 1060 })
        )

        bobService.processInboundRelayEvent(outer)
        var deliveries: [NdrDecryptedMessage] = []
        bobService.onDecryptedMessage = { message, completion in
            deliveries.append(message)
            completion(deliveries.count == 1 ? .retry : .consumed)
        }
        #expect(deliveries.count == 1)

        bobService.retryPendingDeliveries()
        #expect(deliveries.count == 2)
        #expect(deliveries.allSatisfy { $0.event.content == "bitchat1:durable" })

        bobService.retryPendingDeliveries()
        bobService.processInboundRelayEvent(outer)
        #expect(deliveries.count == 2)
    }

    @Test("Replacing a retired delivery owner drains once across restart")
    @MainActor
    func replacingDeliveryOwnerWakesDeferredActionExactlyOnce() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let aliceRelay = FakeRelayManager()
        let aliceService = try makeService(
            label: "delivery-owner-alice",
            relay: aliceRelay
        )
        let bobStorage = try makeTempDir(label: "delivery-owner-bob")
        defer { try? FileManager.default.removeItem(at: bobStorage) }
        var outer: NostrEvent?

        do {
            let bobRelay = FakeRelayManager()
            let bobService = NdrNostrService(
                relayManager: bobRelay,
                rolloutEnabled: true,
                storageDirectoryProvider: { bobStorage }
            )
            aliceService.configureIfNeeded(identity: alice)
            bobService.configureIfNeeded(identity: bob)
            try establishPairwiseSessions(
                aliceService,
                bobService,
                firstIdentity: alice,
                secondIdentity: bob,
                firstRelay: aliceRelay,
                secondRelay: bobRelay
            )

            var retiredOwner: NdrDeliveryLifecycleOwner? =
                NdrDeliveryLifecycleOwner()
            var retiredHandlerCalls = 0
            bobService.onDecryptedMessage = { [weak retiredOwner] _, completion in
                retiredHandlerCalls += 1
                completion(retiredOwner == nil ? .retry : .consumed)
            }
            retiredOwner = nil

            aliceRelay.resetSentEvents()
            guard case .sent = aliceService.send(
                "bitchat1:lifecycle-owner",
                to: bob.publicKeyHex
            ) else {
                Issue.record("Expected a pairwise send")
                return
            }
            let sent = try #require(
                aliceRelay.sentEvents.first(where: { $0.kind == 1060 })
            )
            outer = sent
            bobService.processInboundRelayEvent(sent)
            #expect(retiredHandlerCalls == 1)

            var replacementDeliveries = 0
            bobService.onDecryptedMessage = { message, completion in
                #expect(
                    message.event.content == "bitchat1:lifecycle-owner"
                )
                replacementDeliveries += 1
                completion(.consumed)
            }
            #expect(replacementDeliveries == 1)
        }

        let restartedRelay = FakeRelayManager()
        let restarted = NdrNostrService(
            relayManager: restartedRelay,
            rolloutEnabled: true,
            storageDirectoryProvider: { bobStorage }
        )
        var deliveriesAfterRestart = 0
        restarted.onDecryptedMessage = { _, completion in
            deliveriesAfterRestart += 1
            completion(.consumed)
        }
        restarted.configureIfNeeded(identity: bob)
        if let outer {
            restarted.processInboundRelayEvent(outer)
        }
        #expect(deliveriesAfterRestart == 0)
    }

    @Test("Switching identities isolates invites and persisted ratchet state")
    @MainActor
    func identitySwitchIsolatesPersistedState() throws {
        let storage = try makeTempDir(label: "identity-switch")
        let first = try NostrIdentity.generate()
        let second = try NostrIdentity.generate()
        let service = NdrNostrService(
            relayManager: FakeRelayManager(),
            rolloutEnabled: true,
            storageDirectoryProvider: { storage }
        )

        service.configureIfNeeded(identity: first)
        let firstInvite = try PairwiseInvite.fromEventJson(
            eventJson: try #require(service.currentInviteEventJson())
        )
        #expect(firstInvite.getPeerPubkeyHex() == first.publicKeyHex)

        service.configureIfNeeded(identity: second)
        let secondInvite = try PairwiseInvite.fromEventJson(
            eventJson: try #require(service.currentInviteEventJson())
        )

        #expect(service.configuredPubkeyHex == second.publicKeyHex)
        #expect(secondInvite.getPeerPubkeyHex() == second.publicKeyHex)
        #expect(!service.hasActiveSession(with: first.publicKeyHex))
    }

    @Test("Late relay callbacks cannot acknowledge another account's action")
    @MainActor
    func identityEpochRejectsLatePublishCompletion() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let replacement = try NostrIdentity.generate()
        let relay = FakeRelayManager()
        let storage = try makeTempDir(label: "late-callback")
        let aliceService = NdrNostrService(
            relayManager: relay,
            rolloutEnabled: true,
            storageDirectoryProvider: { storage }
        )
        let bobRelay = FakeRelayManager()
        let bobService = try makeService(
            label: "late-callback-bob",
            relay: bobRelay
        )
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)
        try establishPairwiseSessions(
            aliceService,
            bobService,
            firstIdentity: alice,
            secondIdentity: bob,
            firstRelay: relay,
            secondRelay: bobRelay
        )

        relay.resetSentEvents()
        relay.automaticallyCompletePublishes = false
        let sendResult = aliceService.send(
            "bitchat1:old-account",
            to: bob.publicKeyHex
        )
        guard case let .sent(_, outerEventID) = sendResult else {
            Issue.record("Expected a pairwise send")
            return
        }
        #expect(relay.pendingPublishes.count == 1)

        aliceService.configureIfNeeded(identity: replacement)
        relay.completeNextPublish(accepted: true)
        #expect(aliceService.configuredPubkeyHex == replacement.publicKeyHex)
        #expect(!aliceService.hasActiveSession(with: bob.publicKeyHex))

        aliceService.configureIfNeeded(identity: alice)
        #expect(
            relay.sentEvents.filter { $0.id == outerEventID }.count == 2
        )
        relay.completeNextPublish(accepted: true)
    }

    @Test("Pairwise state and kind-1060 subscription survive restart")
    @MainActor
    func pairwiseSessionRestoresAfterRestart() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let aliceStorage = try makeTempDir(label: "restart-alice")
        let bobRelay = FakeRelayManager()
        let bobService = try makeService(
            label: "restart-bob",
            relay: bobRelay
        )
        bobService.configureIfNeeded(identity: bob)

        do {
            let initialRelay = FakeRelayManager()
            let initial = NdrNostrService(
                relayManager: initialRelay,
                rolloutEnabled: true,
                storageDirectoryProvider: { aliceStorage }
            )
            initial.configureIfNeeded(identity: alice)
            try establishPairwiseSessions(
                initial,
                bobService,
                firstIdentity: alice,
                secondIdentity: bob,
                firstRelay: initialRelay,
                secondRelay: bobRelay
            )
            #expect(initial.hasActiveSession(with: bob.publicKeyHex))
        }

        let restoredRelay = FakeRelayManager()
        let restored = NdrNostrService(
            relayManager: restoredRelay,
            rolloutEnabled: true,
            storageDirectoryProvider: { aliceStorage }
        )
        restored.configureIfNeeded(identity: alice)

        #expect(restored.hasActiveSession(with: bob.publicKeyHex))
        #expect(
            restoredRelay.activeSubscriptions.contains {
                $0.filter.kinds == [1060]
                    && $0.filter.authors?.isEmpty == false
            }
        )
        restoredRelay.resetSentEvents()
        let restoredSend = restored.send(
            "bitchat1:after-restart",
            to: bob.publicKeyHex
        )
        guard case .sent = restoredSend else {
            Issue.record(
                "Expected restored session to send, got \(restoredSend)"
            )
            return
        }
        #expect(restoredRelay.sentEvents.filter { $0.kind == 1060 }.count == 1)
    }

    @Test("Startup backfills the durable per-Noise pin before NDR delivery")
    @MainActor
    func startupBackfillsFavoritePinForRestoredPairwiseSession() throws {
        let local = try NostrIdentity.generate()
        let peer = try NostrIdentity.generate()
        let localStorage = try makeTempDir(label: "startup-pin-local")
        let markerStore = InMemoryNdrSessionMarkerStore()
        let peerRelay = FakeRelayManager()
        let peerService = try makeService(
            label: "startup-pin-peer",
            relay: peerRelay
        )
        peerService.configureIfNeeded(identity: peer)

        do {
            let initialRelay = FakeRelayManager()
            let initialService = NdrNostrService(
                relayManager: initialRelay,
                rolloutEnabled: true,
                storageDirectoryProvider: { localStorage },
                sessionMarkerStore: markerStore
            )
            initialService.configureIfNeeded(identity: local)
            try establishPairwiseSessions(
                initialService,
                peerService,
                firstIdentity: local,
                secondIdentity: peer,
                firstRelay: initialRelay,
                secondRelay: peerRelay
            )
            #expect(
                initialService.hasActiveSession(
                    with: peer.publicKeyHex
                )
            )
        }

        let nostrKeychain = MockKeychain()
        nostrKeychain.save(
            key: "nostr-current-identity",
            data: try JSONEncoder().encode(local),
            service: "chat.bitchat.nostr",
            accessible: nil
        )
        let favoritesService = FavoritesPersistenceService(
            keychain: MockKeychain()
        )
        let noiseKey = Data(repeating: 0xd4, count: 32)
        installMutualFavorite(
            in: favoritesService,
            noiseKey: noiseKey,
            nostrIdentity: peer
        )
        #expect(!favoritesService.isNdrRequired(for: noiseKey))

        let restoredService = NdrNostrService(
            relayManager: FakeRelayManager(),
            rolloutEnabled: true,
            storageDirectoryProvider: { localStorage },
            sessionMarkerStore: markerStore
        )
        let (viewModel, _, _) = makeViewModel(
            ndrService: restoredService,
            nostrKeychain: nostrKeychain,
            favoritesService: favoritesService
        )

        viewModel.setupNostrMessageHandling()

        #expect(favoritesService.isNdrRequired(for: noiseKey))
        #expect(
            !favoritesService.canAcceptLegacyNostrDM(
                from: peer.publicKeyHex
            )
        )
        #expect(
            restoredService.hasActiveSession(
                with: peer.publicKeyHex
            )
        )
    }

    @Test("A failed binding pin makes zero native OOB mutation")
    @MainActor
    func bindingPinFailurePrecedesNativeInviteAcceptance() throws {
        let local = try NostrIdentity.generate()
        let peer = try NostrIdentity.generate()
        let markerStore = InMemoryNdrSessionMarkerStore()
        var nativeMutationCalls = 0
        let localService = NdrNostrService(
            relayManager: FakeRelayManager(),
            rolloutEnabled: true,
            storageDirectoryProvider: {
                try makeTempDir(label: "pin-order-local")
            },
            sessionMarkerStore: markerStore,
            nativeOutOfBandMutationObserver: {
                nativeMutationCalls += 1
            }
        )
        let peerService = try makeService(label: "pin-order-peer")
        localService.configureIfNeeded(identity: local)
        peerService.configureIfNeeded(identity: peer)
        let invite = try #require(
            peerService.currentInviteEventJson()
        )

        let rejected = localService.processOutOfBandEventJson(
            invite,
            expectedPeerPubkeyHex: peer.publicKeyHex,
            persistEstablishedBinding: { false }
        )

        #expect(rejected.isEmpty)
        #expect(nativeMutationCalls == 0)
        #expect(
            !localService.hasPairwiseSession(with: peer.publicKeyHex)
        )
        #expect(
            try !markerStore.contains(
                identityPubkeyHex: local.publicKeyHex
            )
        )

        let accepted = localService.processOutOfBandEventJson(
            invite,
            expectedPeerPubkeyHex: peer.publicKeyHex,
            persistEstablishedBinding: { true }
        )

        #expect(!accepted.isEmpty)
        #expect(nativeMutationCalls == 1)
        #expect(
            localService.hasPairwiseSession(with: peer.publicKeyHex)
        )
        #expect(
            try markerStore.contains(
                identityPubkeyHex: local.publicKeyHex
            )
        )
    }

    @Test("A failed marker precommit makes zero native OOB mutation")
    @MainActor
    func establishedMarkerWriteFailureIsRetriableBeforeNativeResponse()
        throws
    {
        let local = try NostrIdentity.generate()
        let peer = try NostrIdentity.generate()
        let localStorage = try makeTempDir(label: "marker-write-local")
        let markerStore = ControllableNdrSessionMarkerStore()
        markerStore.failMark = true
        let localRelay = FakeRelayManager()
        var nativeMutationCalls = 0
        let localService = NdrNostrService(
            relayManager: localRelay,
            rolloutEnabled: true,
            storageDirectoryProvider: { localStorage },
            sessionMarkerStore: markerStore,
            nativeOutOfBandMutationObserver: {
                nativeMutationCalls += 1
            }
        )
        let peerService = try makeService(
            label: "marker-write-peer"
        )
        #expect(localService.configureIfNeeded(identity: local))
        peerService.configureIfNeeded(identity: peer)

        let invite = try #require(
            localService.currentInviteEventJson()
        )
        let responses = peerService.processOutOfBandEventJson(
            invite,
            expectedPeerPubkeyHex: local.publicKeyHex,
            persistEstablishedBinding: { true }
        )
        let response = try #require(
            handOff(responses, from: peerService).first
        )
        let actions = localService.processOutOfBandEventJson(
            response,
            expectedPeerPubkeyHex: peer.publicKeyHex,
            persistEstablishedBinding: { true }
        )

        #expect(actions.isEmpty)
        #expect(nativeMutationCalls == 0)
        #expect(localService.isConfigured)
        #expect(
            !localService.hasPairwiseSession(with: peer.publicKeyHex)
        )
        #expect(
            localService.send(
                "blocked",
                to: peer.publicKeyHex
            ) == .noSession
        )

        markerStore.failMark = false
        _ = localService.processOutOfBandEventJson(
            response,
            expectedPeerPubkeyHex: peer.publicKeyHex,
            persistEstablishedBinding: { true }
        )

        #expect(nativeMutationCalls == 1)
        #expect(
            localService.hasPairwiseSession(with: peer.publicKeyHex)
        )
    }

    @Test("An established marker rejects missing pairwise state on restart")
    @MainActor
    func establishedMarkerFailsClosedWhenStateDisappears() throws {
        let markerStore = InMemoryNdrSessionMarkerStore()
        let aliceStorage = try makeTempDir(label: "marker-missing-alice")
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()

        do {
            let aliceRelay = FakeRelayManager()
            let bobRelay = FakeRelayManager()
            let aliceService = NdrNostrService(
                relayManager: aliceRelay,
                rolloutEnabled: true,
                storageDirectoryProvider: { aliceStorage },
                sessionMarkerStore: markerStore
            )
            let bobService = try makeService(
                label: "marker-missing-bob",
                relay: bobRelay
            )
            aliceService.configureIfNeeded(identity: alice)
            bobService.configureIfNeeded(identity: bob)
            try establishPairwiseSessions(
                aliceService,
                bobService,
                firstIdentity: alice,
                secondIdentity: bob,
                firstRelay: aliceRelay,
                secondRelay: bobRelay
            )
            #expect(
                try markerStore.contains(
                    identityPubkeyHex: alice.publicKeyHex
                )
            )
        }

        let identityStateDirectory = aliceStorage
            .appendingPathComponent("pairwise-v1", isDirectory: true)
            .appendingPathComponent(
                alice.publicKeyHex,
                isDirectory: true
            )
        try FileManager.default.removeItem(at: identityStateDirectory)

        let restored = NdrNostrService(
            relayManager: FakeRelayManager(),
            rolloutEnabled: true,
            storageDirectoryProvider: { aliceStorage },
            sessionMarkerStore: markerStore
        )
        restored.configureIfNeeded(identity: alice)

        #expect(!restored.isConfigured)
        #expect(
            restored.send("blocked", to: bob.publicKeyHex) == .failed
        )
    }

    @Test("An established marker rejects corrupt pairwise state on restart")
    @MainActor
    func establishedMarkerFailsClosedWhenStateIsCorrupt() throws {
        let markerStore = InMemoryNdrSessionMarkerStore()
        let aliceStorage = try makeTempDir(label: "marker-corrupt-alice")
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()

        do {
            let aliceRelay = FakeRelayManager()
            let bobRelay = FakeRelayManager()
            let aliceService = NdrNostrService(
                relayManager: aliceRelay,
                rolloutEnabled: true,
                storageDirectoryProvider: { aliceStorage },
                sessionMarkerStore: markerStore
            )
            let bobService = try makeService(
                label: "marker-corrupt-bob",
                relay: bobRelay
            )
            aliceService.configureIfNeeded(identity: alice)
            bobService.configureIfNeeded(identity: bob)
            try establishPairwiseSessions(
                aliceService,
                bobService,
                firstIdentity: alice,
                secondIdentity: bob,
                firstRelay: aliceRelay,
                secondRelay: bobRelay
            )
        }

        let identityStateDirectory = aliceStorage
            .appendingPathComponent("pairwise-v1", isDirectory: true)
            .appendingPathComponent(
                alice.publicKeyHex,
                isDirectory: true
            )
        let stateFile = try #require(
            FileManager.default
                .contentsOfDirectory(
                    at: identityStateDirectory,
                    includingPropertiesForKeys: nil
                )
                .first {
                    $0.lastPathComponent.hasPrefix(
                        "ndr-pairwise-state-v1-"
                    )
                }
        )
        try Data("corrupt".utf8).write(to: stateFile, options: .atomic)

        let restored = NdrNostrService(
            relayManager: FakeRelayManager(),
            rolloutEnabled: true,
            storageDirectoryProvider: { aliceStorage },
            sessionMarkerStore: markerStore
        )
        restored.configureIfNeeded(identity: alice)

        #expect(!restored.isConfigured)
        #expect(
            restored.send("blocked", to: bob.publicKeyHex) == .failed
        )
    }

    @Test("Panic reset clears established state and its marker")
    @MainActor
    func panicResetClearsEstablishedMarker() throws {
        let markerStore = InMemoryNdrSessionMarkerStore()
        let aliceStorage = try makeTempDir(label: "marker-panic-alice")
        let aliceRelay = FakeRelayManager()
        let bobRelay = FakeRelayManager()
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let aliceService = NdrNostrService(
            relayManager: aliceRelay,
            rolloutEnabled: true,
            storageDirectoryProvider: { aliceStorage },
            sessionMarkerStore: markerStore
        )
        let bobService = try makeService(
            label: "marker-panic-bob",
            relay: bobRelay
        )
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)
        try establishPairwiseSessions(
            aliceService,
            bobService,
            firstIdentity: alice,
            secondIdentity: bob,
            firstRelay: aliceRelay,
            secondRelay: bobRelay
        )
        #expect(
            try markerStore.contains(
                identityPubkeyHex: alice.publicKeyHex
            )
        )

        try aliceService.resetForPanic()

        #expect(
            try !markerStore.contains(
                identityPubkeyHex: alice.publicKeyHex
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: aliceStorage.path
            )
        )
    }

    @Test("Panic reset invalidates callbacks and removes pairwise storage")
    @MainActor
    func panicResetRemovesState() throws {
        let relay = FakeRelayManager()
        let storage = try makeTempDir(label: "panic")
        let identity = try NostrIdentity.generate()
        let service = NdrNostrService(
            relayManager: relay,
            rolloutEnabled: true,
            storageDirectoryProvider: { storage }
        )
        service.configureIfNeeded(identity: identity)
        #expect(service.isConfigured)
        #expect(FileManager.default.fileExists(atPath: storage.path))

        try service.resetForPanic()

        #expect(!service.isConfigured)
        #expect(service.configuredPubkeyHex == nil)
        #expect(!FileManager.default.fileExists(atPath: storage.path))
    }

    @Test("Only kind 1060 is exposed to Nostr relays")
    @MainActor
    func relaySurfaceIsOnlyKind1060() throws {
        let relay = FakeRelayManager()
        let service = try makeService(label: "relay-surface", relay: relay)
        let identity = try NostrIdentity.generate()
        service.configureIfNeeded(identity: identity)

        let invite = try #require(service.currentInviteEventJson())
        #expect(try extractNostrKind(json: invite) == 30078)
        #expect(relay.sentEvents.allSatisfy { $0.kind == 1060 })
        #expect(relay.subscriptions.allSatisfy { $0.filter.kinds == [1060] })
    }

    @Test("Kind 1060 relay envelopes never expose recipient tags")
    @MainActor
    func publishValidationRejectsRecipientTaggedEnvelope() throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let tagged = try signedKind1060Event(
            identity: sender,
            tags: [["p", recipient.publicKeyHex]]
        )
        let tagless = try signedKind1060Event(
            identity: sender,
            tags: []
        )

        #expect(
            NdrNostrService.validatedPublishAction(
                makePublishAction(tagged)
            ) == nil
        )
        #expect(
            NdrNostrService.validatedPublishAction(
                makePublishAction(tagless)
            )?.id == tagless.id
        )
    }

    @Test("Two native managers handshake, send, decrypt, and restart")
    @MainActor
    func nativePairwiseFlowWorksEndToEnd() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let aliceRelay = FakeRelayManager()
        let bobRelay = FakeRelayManager()
        let aliceStorage = try makeTempDir(label: "e2e-alice")
        let bobStorage = try makeTempDir(label: "e2e-bob")
        let aliceService = NdrNostrService(
            relayManager: aliceRelay,
            rolloutEnabled: true,
            storageDirectoryProvider: { aliceStorage }
        )
        let bobService = NdrNostrService(
            relayManager: bobRelay,
            rolloutEnabled: true,
            storageDirectoryProvider: { bobStorage }
        )
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)

        try establishPairwiseSessions(
            aliceService,
            bobService,
            firstIdentity: alice,
            secondIdentity: bob,
            firstRelay: aliceRelay,
            secondRelay: bobRelay
        )
        #expect(aliceService.hasActiveSession(with: bob.publicKeyHex))
        #expect(bobService.hasActiveSession(with: alice.publicKeyHex))
        #expect(!aliceRelay.sentEvents.contains { $0.kind == 37368 })
        #expect(!bobRelay.sentEvents.contains { $0.kind == 37368 })

        aliceRelay.resetSentEvents()
        let outboundSend = aliceService.send(
            "bitchat1:hello",
            to: bob.publicKeyHex
        )
        guard case .sent = outboundSend else {
            Issue.record("Expected a pairwise send, got \(outboundSend)")
            return
        }
        let outbound = try #require(
            aliceRelay.sentEvents.first(where: { $0.kind == 1060 })
        )
        var decrypted: NostrEvent?
        bobService.onDecryptedMessage = { message, completion in
            decrypted = message.event
            completion(.consumed)
        }
        bobService.processInboundRelayEvent(outbound)

        #expect(decrypted?.pubkey == alice.publicKeyHex)
        #expect(decrypted?.content == "bitchat1:hello")

        let restored = NdrNostrService(
            relayManager: FakeRelayManager(),
            rolloutEnabled: true,
            storageDirectoryProvider: { bobStorage }
        )
        restored.configureIfNeeded(identity: bob)
        #expect(restored.hasActiveSession(with: alice.publicKeyHex))
    }

    @Test("Rotated NDR filters stay live across bidirectional relay turns")
    @MainActor
    func rotatedSubscriptionFiltersReplaceTheLiveRelayRequest() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let aliceRelay = FakeRelayManager()
        let bobRelay = FakeRelayManager()
        let aliceService = try makeService(
            label: "subscription-rotation-alice",
            relay: aliceRelay
        )
        let bobService = try makeService(
            label: "subscription-rotation-bob",
            relay: bobRelay
        )
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)
        try establishPairwiseSessions(
            aliceService,
            bobService,
            firstIdentity: alice,
            secondIdentity: bob,
            firstRelay: aliceRelay,
            secondRelay: bobRelay
        )

        var receivedByAlice: [String] = []
        var receivedByBob: [String] = []
        aliceService.onDecryptedMessage = { message, completion in
            receivedByAlice.append(message.event.content)
            completion(.consumed)
        }
        bobService.onDecryptedMessage = { message, completion in
            receivedByBob.append(message.event.content)
            completion(.consumed)
        }
        aliceRelay.resetSentEvents()
        bobRelay.resetSentEvents()

        guard case let .sent(_, firstOuterID) = aliceService.send(
            "bitchat1:first-turn",
            to: bob.publicKeyHex
        ),
            let firstOuter = aliceRelay.sentEvents.first(where: {
                $0.id == firstOuterID
            })
        else {
            Issue.record("Expected Alice's first pairwise send")
            return
        }
        #expect(bobRelay.deliverMatching(firstOuter))
        #expect(receivedByBob == ["bitchat1:first-turn"])

        guard case let .sent(_, replyOuterID) = bobService.send(
            "bitchat1:reply-turn",
            to: alice.publicKeyHex
        ),
            let replyOuter = bobRelay.sentEvents.first(where: {
                $0.id == replyOuterID
            })
        else {
            Issue.record("Expected Bob's pairwise reply")
            return
        }
        #expect(aliceRelay.deliverMatching(replyOuter))
        #expect(receivedByAlice == ["bitchat1:reply-turn"])

        guard case let .sent(_, secondOuterID) = aliceService.send(
            "bitchat1:second-turn",
            to: bob.publicKeyHex
        ),
            let secondOuter = aliceRelay.sentEvents.first(where: {
                $0.id == secondOuterID
            })
        else {
            Issue.record("Expected Alice's second pairwise send")
            return
        }
        #expect(
            bobRelay.deliverMatching(secondOuter),
            "the live relay filter must follow the rotated sender key"
        )
        #expect(
            receivedByBob
                == ["bitchat1:first-turn", "bitchat1:second-turn"]
        )
        #expect(aliceRelay.unsubscribedIDs.isEmpty)
        #expect(bobRelay.unsubscribedIDs.isEmpty)
    }

    @Test("Absolute message expiry survives the pairwise round trip")
    @MainActor
    func outboundExpirationRoundTripsToDelivery() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let aliceRelay = FakeRelayManager()
        let aliceService = try makeService(
            label: "expiry-alice",
            relay: aliceRelay
        )
        let bobRelay = FakeRelayManager()
        let bobService = try makeService(
            label: "expiry-bob",
            relay: bobRelay
        )
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)
        try establishPairwiseSessions(
            aliceService,
            bobService,
            firstIdentity: alice,
            secondIdentity: bob,
            firstRelay: aliceRelay,
            secondRelay: bobRelay
        )

        aliceRelay.resetSentEvents()
        let expiration: UInt64 = 4_000_000_000
        let expiringSend = aliceService.send(
            "bitchat1:disappearing",
            to: bob.publicKeyHex,
            expiresAtSeconds: expiration
        )
        guard case .sent = expiringSend else {
            Issue.record("Expected a pairwise send, got \(expiringSend)")
            return
        }
        let outbound = try #require(
            aliceRelay.sentEvents.first { $0.kind == 1060 }
        )
        var deliveredExpiration: UInt64?
        bobService.onDecryptedMessage = { message, completion in
            deliveredExpiration = message.expiresAtSeconds
            completion(.consumed)
        }

        bobService.processInboundRelayEvent(outbound)

        #expect(deliveredExpiration == expiration)
    }

    @MainActor
    private func establishPairwiseSessions(
        _ firstService: NdrNostrService,
        _ secondService: NdrNostrService,
        firstIdentity: NostrIdentity,
        secondIdentity: NostrIdentity,
        firstRelay: FakeRelayManager,
        secondRelay: FakeRelayManager
    ) throws {
        let firstRelayEventCount = firstRelay.sentEvents.count
        let secondRelayEventCount = secondRelay.sentEvents.count
        let firstInvite = try #require(
            firstService.currentInviteEventJson()
        )
        let secondInvite = try #require(
            secondService.currentInviteEventJson()
        )

        // Simultaneous invite glare is intentionally exercised here. Complete
        // the authenticated OOB responses before delivering either bootstrap
        // publish; the native runtime deterministically rejects the losing
        // response/bootstrap pair and converges on the winning session.
        let generatedBySecond = secondService.processOutOfBandEventJson(
            firstInvite,
            expectedPeerPubkeyHex: firstIdentity.publicKeyHex,
            persistEstablishedBinding: { true }
        )
        let generatedByFirst = firstService.processOutOfBandEventJson(
            secondInvite,
            expectedPeerPubkeyHex: secondIdentity.publicKeyHex,
            persistEstablishedBinding: { true }
        )
        for response in handOff(generatedBySecond, from: secondService) {
            _ = firstService.processOutOfBandEventJson(
                response,
                expectedPeerPubkeyHex: secondIdentity.publicKeyHex,
                persistEstablishedBinding: { true }
            )
        }
        for response in handOff(generatedByFirst, from: firstService) {
            _ = secondService.processOutOfBandEventJson(
                response,
                expectedPeerPubkeyHex: firstIdentity.publicKeyHex,
                persistEstablishedBinding: { true }
            )
        }

        for event in firstRelay.sentEvents
            .dropFirst(firstRelayEventCount)
        where event.kind == 1060
        {
            secondService.processInboundRelayEvent(event)
        }
        for event in secondRelay.sentEvents
            .dropFirst(secondRelayEventCount)
        where event.kind == 1060
        {
            firstService.processInboundRelayEvent(event)
        }

        guard firstService.hasActiveSession(
            with: secondIdentity.publicKeyHex
        ),
            secondService.hasActiveSession(
                with: firstIdentity.publicKeyHex
            )
        else {
            Issue.record(
                "Pairwise OOB handshake did not establish both sessions"
            )
            return
        }
    }

    @MainActor
    private func handOff(
        _ actions: [NdrOutOfBandAction],
        from service: NdrNostrService
    ) -> [String] {
        actions.map { action in
            service.completeOutOfBandAction(action, succeeded: true)
            return action.eventJson
        }
    }

    @MainActor
    private func makeService(
        label: String,
        relay: FakeRelayManager? = nil,
        sessionMarkerStore: NdrSessionMarkerStoring? = nil
    ) throws -> NdrNostrService {
        let storage = try makeTempDir(label: label)
        return NdrNostrService(
            relayManager: relay ?? FakeRelayManager(),
            rolloutEnabled: true,
            storageDirectoryProvider: { storage },
            sessionMarkerStore:
                sessionMarkerStore ?? InMemoryNdrSessionMarkerStore()
        )
    }

    @MainActor
    private func makeViewModel(
        ndrService: NdrNostrService,
        nostrKeychain: KeychainManagerProtocol? = nil,
        favoritesService: FavoritesPersistenceService? = nil
    ) -> (
        ChatViewModel,
        MockTransport,
        FavoritesPersistenceService
    ) {
        let keychain = MockKeychain()
        let identityManager = MockIdentityManager(keychain)
        let transport = MockTransport()
        let resolvedFavoritesService =
            favoritesService
            ?? FavoritesPersistenceService(keychain: MockKeychain())
        let resolvedNostrKeychain =
            nostrKeychain ?? MockKeychainHelper()
        let viewModel = ChatViewModel(
            keychain: keychain,
            idBridge: NostrIdentityBridge(
                keychain: resolvedNostrKeychain
            ),
            identityManager: identityManager,
            transport: transport,
            ndrService: ndrService,
            favoritesService: resolvedFavoritesService
        )
        return (viewModel, transport, resolvedFavoritesService)
    }

    @MainActor
    private func installMutualFavorite(
        in favoritesService: FavoritesPersistenceService,
        noiseKey: Data,
        nostrIdentity: NostrIdentity
    ) {
        favoritesService.addFavorite(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: nostrIdentity.npub,
            peerNickname: "NDR test peer"
        )
        favoritesService.updatePeerFavoritedUs(
            peerNoisePublicKey: noiseKey,
            favorited: true,
            peerNostrPublicKey: nostrIdentity.npub
        )
    }

    @MainActor
    private func removeFavorite(
        in favoritesService: FavoritesPersistenceService,
        noiseKey: Data
    ) {
        favoritesService.updatePeerFavoritedUs(
            peerNoisePublicKey: noiseKey,
            favorited: false
        )
        favoritesService.removeFavorite(
            peerNoisePublicKey: noiseKey
        )
    }

    private func makeTempDir(label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "bitchat-tests-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return directory
    }

    private func makeInnerMessageEvent(
        identity: NostrIdentity,
        content: String
    ) throws -> NostrEvent {
        let event = NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: Date(),
            kind: .dm,
            tags: [],
            content: content
        )
        var rumor = try event.sign(with: identity.schnorrSigningKey())
        rumor.sig = nil
        return rumor
    }

    private func makeDeliveryAction(
        _ event: NostrEvent,
        authenticatedSender: String,
        innerEventID: String? = nil,
        expiresAtSeconds: UInt64? = nil
    ) -> PairwiseAction {
        PairwiseAction(
            actionId: "delivery-test",
            kind: "delivery",
            sessionId: nil,
            subscriptionId: nil,
            filterJson: nil,
            eventJson: nil,
            peerPubkeyHex: authenticatedSender,
            innerEventJson: try? event.jsonString(),
            innerEventId: innerEventID ?? event.id,
            outerEventId: String(repeating: "a", count: 64),
            expiresAtSeconds: expiresAtSeconds
        )
    }

    private func signedKind1060Event(
        identity: NostrIdentity,
        tags: [[String]]
    ) throws -> NostrEvent {
        let unsigned = try NostrEvent(
            from: [
                "pubkey": identity.publicKeyHex,
                "created_at": 1_750_000_000,
                "kind": 1060,
                "tags": tags,
                "content": "opaque-ratchet-envelope"
            ]
        )
        return try unsigned.sign(with: identity.schnorrSigningKey())
    }

    private func makePublishAction(
        _ event: NostrEvent
    ) -> PairwiseAction {
        PairwiseAction(
            actionId: "publish-test-\(event.id)",
            kind: "publish",
            sessionId: "session-test",
            subscriptionId: nil,
            filterJson: nil,
            eventJson: try? event.jsonString(),
            peerPubkeyHex: nil,
            innerEventJson: nil,
            innerEventId: nil,
            outerEventId: event.id,
            expiresAtSeconds: nil
        )
    }

    private func seedMixedPendingActions(
        outboundCount: Int,
        deliveryCount: Int,
        senderKeys: FfiKeyPair,
        peerKeys: FfiKeyPair,
        storagePath: String
    ) throws {
        let sender = try PairwiseManager.newWithStoragePath(
            ourPubkeyHex: senderKeys.publicKeyHex,
            ourIdentityPrivateKeyHex: senderKeys.privateKeyHex,
            storagePath: storagePath
        )
        let peer = try PairwiseManager.newWithStoragePath(
            ourPubkeyHex: peerKeys.publicKeyHex,
            ourIdentityPrivateKeyHex: peerKeys.privateKeyHex,
            storagePath: "\(storagePath)-peer"
        )
        _ = try sender.acceptInviteFromEventJson(
            eventJson: peer.currentInviteEventJson(),
            authenticatedPeerPubkeyHex: peerKeys.publicKeyHex
        )
        let senderSetup = try sender.pendingActions()
        let response = try #require(
            senderSetup.first { $0.kind == "out_of_band" }?.eventJson
        )
        let bootstrap = try #require(
            senderSetup.first { action in
                action.kind == "publish"
                    && action.innerEventId == nil
            }?.eventJson
        )
        try peer.processOutOfBandResponse(
            eventJson: response,
            authenticatedPeerPubkeyHex: senderKeys.publicKeyHex
        )
        try peer.processEvent(eventJson: bootstrap)
        // Seed only post-handshake relay/delivery work. A real host must ack
        // the authenticated OOB response before its bootstrap can publish.
        let senderSetupActionIDs = senderSetup.map(\.actionId)
        try sender.ackActions(actionIds: senderSetupActionIDs)
        let peerSetupActionIDs = try peer.pendingActions()
            .filter { $0.kind != "delivery" }
            .map(\.actionId)
        try peer.ackActions(actionIds: peerSetupActionIDs)

        for index in 0..<outboundCount {
            _ = try sender.sendText(
                peerPubkeyHex: peerKeys.publicKeyHex,
                text: "outbound-\(index)",
                expiresAtSeconds: nil
            )
        }

        for index in 0..<deliveryCount {
            let result = try peer.sendText(
                peerPubkeyHex: senderKeys.publicKeyHex,
                text: "inbound-\(index)",
                expiresAtSeconds: nil
            )
            let publish = try #require(
                try peer.pendingActions().first {
                    $0.kind == "publish"
                        && $0.outerEventId == result.outerEventId
                }
            )
            try sender.processEvent(
                eventJson: try #require(publish.eventJson)
            )
            try peer.ackActions(actionIds: [publish.actionId])
        }
    }

    private func extractNostrKind(json: String) throws -> Int {
        let object = try JSONSerialization.jsonObject(
            with: Data(json.utf8),
            options: []
        )
        let dictionary = try #require(
            object as? [String: Any],
            "Event should be a JSON object"
        )
        return try #require(
            dictionary["kind"] as? Int,
            "Event should have an integer kind"
        )
    }
}
