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

    private(set) var subscriptions: [Subscription] = []
    private(set) var unsubscribedIDs: [String] = []
    private(set) var sentEvents: [NostrEvent] = []
    private var activeSubscriptionIDs = Set<String>()

    var activeSubscriptions: [Subscription] {
        subscriptions.filter { activeSubscriptionIDs.contains($0.id) }
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
    ) {
        subscriptions.append(
            Subscription(id: id, filter: filter, handler: handler)
        )
        activeSubscriptionIDs.insert(id)
    }

    func unsubscribe(id: String) {
        unsubscribedIDs.append(id)
        activeSubscriptionIDs.remove(id)
    }

    func sendEvent(_ event: NostrEvent, to relayUrls: [String]?) {
        sentEvents.append(event)
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
}

struct NdrOutOfBandTransportTests {

    @Test("Double-ratchet bootstrap uses the coordinated cross-platform wire value")
    func wireValue_isCoordinated() {
        #expect(NoisePayloadType.ndrEvent.rawValue == 0x22)
        #expect(NoisePayloadType.decoded(rawValue: 0x22) == .ndrEvent)
        #expect(NoisePayloadType.decoded(rawValue: 0x12) == .vouch)
    }

    @Test("Double-ratchet rollout remains dark until kind-1402 coordination completes")
    @MainActor
    func rolloutGate_isDisabledByDefaultAndFailsClosed() throws {
        #expect(!DoubleRatchetFeature.isEnabled)
        #expect(!PeerCapabilities.localSupported.contains(.doubleRatchet))
        let identity = try NostrIdentity.generate()
        var requestedStorage = false
        let service = NdrNostrService(
            relayManager: FakeRelayManager(),
            deviceId: "disabled-rollout",
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

    @Test("Out-of-band invites are bound to the authenticated favorite identity")
    @MainActor
    func oobInvite_rejectsUnexpectedOwner() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let unexpectedPeer = try NostrIdentity.generate()
        let aliceService = NdrNostrService(
            relayManager: FakeRelayManager(),
            deviceId: "alice-device",
            rolloutEnabled: true,
            storageDirectoryProvider: { try makeTempDir(label: "ndr-owner-alice") }
        )
        let bobService = NdrNostrService(
            relayManager: FakeRelayManager(),
            deviceId: "bob-device",
            rolloutEnabled: true,
            storageDirectoryProvider: { try makeTempDir(label: "ndr-owner-bob") }
        )

        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)
        let aliceInvite = try #require(aliceService.currentInviteEventJson())

        let responses = bobService.processOutOfBandEventJson(
            aliceInvite,
            expectedPeerPubkeyHex: unexpectedPeer.publicKeyHex
        )

        #expect(responses.isEmpty)
        #expect(!bobService.hasActiveSession(with: alice.publicKeyHex))
    }

    @Test("Out-of-band responses cannot establish a session for another authenticated peer")
    @MainActor
    func oobResponse_rejectsUnexpectedOwner() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let unexpectedPeer = try NostrIdentity.generate()
        let aliceService = NdrNostrService(
            relayManager: FakeRelayManager(),
            deviceId: "response-owner-alice",
            rolloutEnabled: true,
            storageDirectoryProvider: { try makeTempDir(label: "ndr-response-owner-alice") }
        )
        let bobService = NdrNostrService(
            relayManager: FakeRelayManager(),
            deviceId: "response-owner-bob",
            rolloutEnabled: true,
            storageDirectoryProvider: { try makeTempDir(label: "ndr-response-owner-bob") }
        )
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)

        let aliceInvite = try #require(aliceService.currentInviteEventJson())
        let bobResponses = bobService.processOutOfBandEventJson(
            aliceInvite,
            expectedPeerPubkeyHex: alice.publicKeyHex
        )
        let bobResponse = try #require(
            bobResponses.first(where: { (try? extractNostrKind(json: $0)) == 1059 })
        )

        let rejected = aliceService.processOutOfBandEventJson(
            bobResponse,
            expectedPeerPubkeyHex: unexpectedPeer.publicKeyHex
        )

        #expect(rejected.isEmpty)
        #expect(!aliceService.hasActiveSession(with: bob.publicKeyHex))
        #expect(!aliceService.hasActiveSession(with: unexpectedPeer.publicKeyHex))
    }

    @Test("Relay-injected invite responses cannot bypass the authenticated Noise route")
    @MainActor
    func relayInjectedResponse_isRejected() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let aliceService = NdrNostrService(
            relayManager: FakeRelayManager(),
            deviceId: "relay-response-alice",
            rolloutEnabled: true,
            storageDirectoryProvider: { try makeTempDir(label: "ndr-relay-response-alice") }
        )
        let bobService = NdrNostrService(
            relayManager: FakeRelayManager(),
            deviceId: "relay-response-bob",
            rolloutEnabled: true,
            storageDirectoryProvider: { try makeTempDir(label: "ndr-relay-response-bob") }
        )
        aliceService.configureIfNeeded(identity: alice)
        bobService.configureIfNeeded(identity: bob)

        let aliceInvite = try #require(aliceService.currentInviteEventJson())
        let bobResponse = try #require(
            bobService.processOutOfBandEventJson(
                aliceInvite,
                expectedPeerPubkeyHex: alice.publicKeyHex
            ).first(where: { (try? extractNostrKind(json: $0)) == 1059 })
        )
        let relayInjected = try JSONDecoder().decode(
            NostrEvent.self,
            from: Data(bobResponse.utf8)
        )

        aliceService.processInboundRelayEvent(relayInjected)

        #expect(!aliceService.hasActiveSession(with: bob.publicKeyHex))
    }

    @Test("Decrypted rumors are bound to the ratchet-authenticated sending device")
    @MainActor
    func decryptedRumor_rejectsClaimedSenderMismatch() throws {
        let authenticated = try NostrIdentity.generate()
        let claimed = try NostrIdentity.generate()
        let conversationOwner = try NostrIdentity.generate()
        let matching = try makeInnerMessageEvent(
            identity: authenticated,
            content: "bitchat1:matching"
        )
        let forged = try makeInnerMessageEvent(
            identity: claimed,
            content: "bitchat1:forged"
        )

        #expect(
            NdrNostrService.validatedDecryptedMessage(
                from: makeDecryptedPubSubEvent(
                    matching,
                    authenticatedSender: authenticated.publicKeyHex,
                    conversationOwner: conversationOwner.publicKeyHex
                )
            )?.event.pubkey == authenticated.publicKeyHex
        )
        let sibling = try #require(
            NdrNostrService.validatedDecryptedMessage(
                from: makeDecryptedPubSubEvent(
                    matching,
                    authenticatedSender: authenticated.publicKeyHex,
                    conversationOwner: conversationOwner.publicKeyHex
                )
            )
        )
        #expect(sibling.senderPubkeyHex == authenticated.publicKeyHex)
        #expect(sibling.conversationPubkeyHex == conversationOwner.publicKeyHex)
        #expect(sibling.isLocalSiblingCopy)
        #expect(
            NdrNostrService.validatedDecryptedMessage(
                from: makeDecryptedPubSubEvent(
                    forged,
                    authenticatedSender: authenticated.publicKeyHex,
                    conversationOwner: claimed.publicKeyHex
                )
            ) == nil
        )
    }

    @Test("A delayed owner roster retries a multi-device invite and returns its response over Noise")
    @MainActor
    func multiDeviceInvite_retriesAfterOwnerRoster() throws {
        let owner = try NostrIdentity.generate()
        let device = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let deviceManager = try SessionManagerHandle(
            ourPubkeyHex: device.publicKeyHex,
            ourIdentityPrivkeyHex: device.privateKey.hexEncodedString(),
            deviceId: "multi-device-child",
            ownerPubkeyHex: owner.publicKeyHex
        )
        try deviceManager.`init`()
        let deviceInvite = try #require(
            try deviceManager.drainEvents()
                .first(where: { isInvitePublish($0) })?
                .eventJson
        )

        let recipientRelay = FakeRelayManager()
        let recipientService = NdrNostrService(
            relayManager: recipientRelay,
            deviceId: "multi-device-recipient",
            rolloutEnabled: true,
            storageDirectoryProvider: { try makeTempDir(label: "ndr-multi-device-recipient") }
        )
        recipientService.configureIfNeeded(identity: recipient)
        var deferredResponses: [String] = []

        let immediate = recipientService.processOutOfBandEventJson(
            deviceInvite,
            expectedPeerPubkeyHex: owner.publicKeyHex,
            deferredResponseHandler: { deferredResponses.append($0) }
        )
        #expect(immediate.isEmpty)
        #expect(!recipientService.hasActiveSession(with: owner.publicKeyHex))

        _ = recipientService.processOutOfBandEventJson(
            deviceInvite,
            expectedPeerPubkeyHex: owner.publicKeyHex,
            deferredResponseHandler: { deferredResponses.append($0) }
        )
        #expect(
            recipientRelay.subscriptions.filter {
                $0.filter.kinds == [37368] && $0.filter.authors == [owner.publicKeyHex]
            }.count == 1
        )

        recipientService.processInboundRelayEvent(
            try makeAppKeysEvent(owner: owner, devices: [device])
        )

        #expect(recipientService.hasActiveSession(with: owner.publicKeyHex))
        #expect(
            deferredResponses.contains {
                (try? extractNostrKind(json: $0)) == 1059
            }
        )
        #expect(
            recipientRelay.activeSubscriptions.contains {
                $0.filter.kinds == [37368]
                    && $0.filter.authors == [owner.publicKeyHex]
            }
        )
    }

    @Test("Delayed owner roster preserves invites from two devices on the same account")
    @MainActor
    func multiDeviceInvites_sameOwnerDoNotOverwriteEachOther() throws {
        let owner = try NostrIdentity.generate()
        let firstDevice = try NostrIdentity.generate()
        let secondDevice = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let firstManager = try makeChildManager(
            identity: firstDevice,
            owner: owner,
            deviceID: "multi-device-first"
        )
        let secondManager = try makeChildManager(
            identity: secondDevice,
            owner: owner,
            deviceID: "multi-device-second"
        )
        let firstInvite = try inviteEventJson(from: firstManager)
        let secondInvite = try inviteEventJson(from: secondManager)
        let relay = FakeRelayManager()
        let service = NdrNostrService(
            relayManager: relay,
            deviceId: "multi-device-recipient-two",
            rolloutEnabled: true,
            storageDirectoryProvider: {
                try makeTempDir(label: "ndr-multi-device-recipient-two")
            }
        )
        service.configureIfNeeded(identity: recipient)
        var firstResponses: [String] = []
        var secondResponses: [String] = []

        #expect(
            service.processOutOfBandEventJson(
                firstInvite,
                expectedPeerPubkeyHex: owner.publicKeyHex,
                deferredResponseHandler: { firstResponses.append($0) }
            ).isEmpty
        )
        #expect(
            service.processOutOfBandEventJson(
                secondInvite,
                expectedPeerPubkeyHex: owner.publicKeyHex,
                deferredResponseHandler: { secondResponses.append($0) }
            ).isEmpty
        )
        #expect(
            relay.subscriptions.filter {
                $0.filter.kinds == [37368] && $0.filter.authors == [owner.publicKeyHex]
            }.count == 1
        )

        service.processInboundRelayEvent(
            try makeAppKeysEvent(owner: owner, devices: [firstDevice, secondDevice])
        )

        #expect(firstResponses.contains { (try? extractNostrKind(json: $0)) == 1059 })
        #expect(secondResponses.contains { (try? extractNostrKind(json: $0)) == 1059 })
        #expect(
            relay.activeSubscriptions.contains {
                $0.filter.kinds == [37368]
                    && $0.filter.authors == [owner.publicKeyHex]
            }
        )
    }

    @Test("Owner roster updates stop outbound fanout to a removed device")
    @MainActor
    func durableOwnerRoster_removesRevokedDeviceFromOutboundFanout() throws {
        let owner = try NostrIdentity.generate()
        let firstDevice = try NostrIdentity.generate()
        let removedDevice = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let firstManager = try makeChildManager(
            identity: firstDevice,
            owner: owner,
            deviceID: "durable-roster-first"
        )
        let removedManager = try makeChildManager(
            identity: removedDevice,
            owner: owner,
            deviceID: "durable-roster-removed"
        )
        let firstInvite = try inviteEventJson(from: firstManager)
        let removedInvite = try inviteEventJson(from: removedManager)
        let relay = FakeRelayManager()
        let service = NdrNostrService(
            relayManager: relay,
            deviceId: "durable-roster-recipient",
            rolloutEnabled: true,
            storageDirectoryProvider: {
                try makeTempDir(label: "ndr-durable-roster-recipient")
            }
        )
        service.configureIfNeeded(identity: recipient)
        var firstResponses: [String] = []
        var removedResponses: [String] = []

        #expect(
            service.processOutOfBandEventJson(
                firstInvite,
                expectedPeerPubkeyHex: owner.publicKeyHex,
                deferredResponseHandler: { firstResponses.append($0) }
            ).isEmpty
        )
        #expect(
            service.processOutOfBandEventJson(
                removedInvite,
                expectedPeerPubkeyHex: owner.publicKeyHex,
                deferredResponseHandler: { removedResponses.append($0) }
            ).isEmpty
        )

        let initialTimestamp = Int(Date().timeIntervalSince1970)
        service.processInboundRelayEvent(
            try makeAppKeysEvent(
                owner: owner,
                devices: [firstDevice, removedDevice],
                timestamp: initialTimestamp
            )
        )
        #expect(service.hasActiveSession(with: owner.publicKeyHex))
        #expect(firstResponses.contains { (try? extractNostrKind(json: $0)) == 1059 })
        #expect(removedResponses.contains { (try? extractNostrKind(json: $0)) == 1059 })

        relay.resetSentEvents()
        #expect(
            service.sendIfPossible(
                "bitchat1:before-device-removal",
                to: owner.publicKeyHex
            )
        )
        #expect(relay.sentEvents.filter { $0.kind == 1060 }.count == 2)

        let rosterSubscription = try #require(
            relay.activeSubscriptions.first {
                $0.filter.kinds == [37368]
                    && $0.filter.authors == [owner.publicKeyHex]
            }
        )
        #expect(
            !relay.subscriptions.contains {
                $0.filter.kinds?.contains(30078) == true
            }
        )
        relay.deliver(
            try makeAppKeysEvent(
                owner: owner,
                devices: [firstDevice],
                timestamp: initialTimestamp + 1
            ),
            to: rosterSubscription.id
        )

        relay.resetSentEvents()
        #expect(
            service.sendIfPossible(
                "bitchat1:after-device-removal",
                to: owner.publicKeyHex
            )
        )
        #expect(relay.sentEvents.filter { $0.kind == 1060 }.count == 1)
    }

    @Test("Persisted peer owners restore durable roster subscriptions")
    @MainActor
    func durableOwnerRoster_restoresAfterRestart() throws {
        let peer = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let peerManager = try makeChildManager(
            identity: peer,
            owner: peer,
            deviceID: "durable-restart-peer"
        )
        let invite = try inviteEventJson(from: peerManager)
        let storage = try makeTempDir(label: "ndr-durable-restart")

        do {
            let initialRelay = FakeRelayManager()
            let initialService = NdrNostrService(
                relayManager: initialRelay,
                deviceId: "durable-restart-recipient",
                rolloutEnabled: true,
                storageDirectoryProvider: { storage }
            )
            initialService.configureIfNeeded(identity: recipient)
            _ = initialService.processOutOfBandEventJson(
                invite,
                expectedPeerPubkeyHex: peer.publicKeyHex
            )
            #expect(initialService.hasActiveSession(with: peer.publicKeyHex))
        }

        let restoredRelay = FakeRelayManager()
        let restoredService = NdrNostrService(
            relayManager: restoredRelay,
            deviceId: "durable-restart-recipient",
            rolloutEnabled: true,
            storageDirectoryProvider: { storage }
        )
        restoredService.configureIfNeeded(identity: recipient)

        #expect(restoredService.hasActiveSession(with: peer.publicKeyHex))
        #expect(
            restoredRelay.activeSubscriptions.contains {
                $0.filter.kinds == [37368]
                    && $0.filter.authors == [peer.publicKeyHex]
            }
        )
        #expect(
            !restoredRelay.subscriptions.contains {
                $0.filter.kinds?.contains(30078) == true
            }
        )
    }

    @Test("Delayed owner roster cannot resume after its authenticated binding is revoked")
    @MainActor
    func multiDeviceInvite_rechecksAuthorizationBeforeRetry() throws {
        let owner = try NostrIdentity.generate()
        let device = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let deviceManager = try makeChildManager(
            identity: device,
            owner: owner,
            deviceID: "revoked-device"
        )
        let invite = try inviteEventJson(from: deviceManager)
        let relay = FakeRelayManager()
        let service = NdrNostrService(
            relayManager: relay,
            deviceId: "revoked-recipient",
            rolloutEnabled: true,
            storageDirectoryProvider: {
                try makeTempDir(label: "ndr-revoked-recipient")
            }
        )
        service.configureIfNeeded(identity: recipient)
        var isAuthorized = true
        var deferredResponses: [String] = []

        #expect(
            service.processOutOfBandEventJson(
                invite,
                expectedPeerPubkeyHex: owner.publicKeyHex,
                authorization: { isAuthorized },
                deferredResponseHandler: { deferredResponses.append($0) }
            ).isEmpty
        )
        isAuthorized = false

        service.processInboundRelayEvent(
            try makeAppKeysEvent(owner: owner, devices: [device])
        )

        #expect(deferredResponses.isEmpty)
        #expect(!service.hasActiveSession(with: owner.publicKeyHex))
        #expect(relay.unsubscribedIDs.count == 1)
    }

    @Test("Pending-invite cap eviction preserves the shared owner roster subscription")
    @MainActor
    func pendingInviteCap_sameOwnerKeepsRosterSubscription() throws {
        let owner = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let relay = FakeRelayManager()
        let service = NdrNostrService(
            relayManager: relay,
            deviceId: "pending-cap-recipient",
            rolloutEnabled: true,
            storageDirectoryProvider: {
                try makeTempDir(label: "ndr-pending-cap-recipient")
            }
        )
        service.configureIfNeeded(identity: recipient)

        for index in 0...64 {
            let device = try NostrIdentity.generate()
            let manager = try makeChildManager(
                identity: device,
                owner: owner,
                deviceID: "pending-cap-\(index)"
            )
            #expect(
                service.processOutOfBandEventJson(
                    try inviteEventJson(from: manager),
                    expectedPeerPubkeyHex: owner.publicKeyHex,
                    deferredResponseHandler: { _ in }
                ).isEmpty
            )
        }

        #expect(
            relay.subscriptions.filter {
                $0.filter.kinds == [37368] && $0.filter.authors == [owner.publicKeyHex]
            }.count == 1
        )
        #expect(relay.unsubscribedIDs.isEmpty)
    }

    @Test("Validated decrypted messages wait for a consumer instead of being dropped")
    @MainActor
    func decryptedMessage_buffersUntilCallbackInstalled() throws {
        let identity = try NostrIdentity.generate()
        let inner = try makeInnerMessageEvent(
            identity: identity,
            content: "bitchat1:buffered"
        )
        let service = NdrNostrService(
            relayManager: FakeRelayManager(),
            deviceId: "buffered-decrypted",
            rolloutEnabled: true,
            storageDirectoryProvider: { try makeTempDir(label: "ndr-buffered-decrypted") }
        )
        var received: [NdrDecryptedMessage] = []

        service.consumeDecryptedPubSubEvent(
            makeDecryptedPubSubEvent(
                inner,
                authenticatedSender: identity.publicKeyHex
            )
        )
        #expect(received.isEmpty)

        service.onDecryptedMessage = { received.append($0) }
        #expect(received.map(\.event.id) == [inner.id])
    }

    @Test("Switching identities never reuses another owner's ratchet state")
    @MainActor
    func identitySwitch_isolatesPersistedState() throws {
        let storage = try makeTempDir(label: "ndr-identity-switch")
        let firstIdentity = try NostrIdentity.generate()
        let secondIdentity = try NostrIdentity.generate()
        let service = NdrNostrService(
            relayManager: FakeRelayManager(),
            deviceId: "identity-switch-device",
            rolloutEnabled: true,
            storageDirectoryProvider: { storage }
        )

        service.configureIfNeeded(identity: firstIdentity)
        let firstInviteJson = try #require(service.currentInviteEventJson())
        let firstInvite = try InviteHandle.fromEventJson(eventJson: firstInviteJson)
        #expect(try firstInvite.getOwnerPubkeyHex() == firstIdentity.publicKeyHex)

        service.configureIfNeeded(identity: secondIdentity)
        let secondInviteJson = try #require(service.currentInviteEventJson())
        let secondInvite = try InviteHandle.fromEventJson(eventJson: secondInviteJson)

        #expect(service.configuredPubkeyHex == secondIdentity.publicKeyHex)
        #expect(try secondInvite.getOwnerPubkeyHex() == secondIdentity.publicKeyHex)
    }

    @Test("Panic reset invalidates the session and deletes ratchet storage")
    @MainActor
    func panicReset_removesState() throws {
        let relay = FakeRelayManager()
        let storage = try makeTempDir(label: "ndr-panic")
        let identity = try NostrIdentity.generate()
        var clearedDeviceID = false
        let service = NdrNostrService(
            relayManager: relay,
            deviceId: "panic-device",
            rolloutEnabled: true,
            storageDirectoryProvider: { storage },
            clearPersistedDeviceId: { clearedDeviceID = true }
        )
        service.configureIfNeeded(identity: identity)
        #expect(service.isConfigured)
        #expect(FileManager.default.fileExists(atPath: storage.path))
        let buffered = try makeInnerMessageEvent(
            identity: identity,
            content: "bitchat1:must-not-survive-panic"
        )
        service.consumeDecryptedPubSubEvent(
            makeDecryptedPubSubEvent(
                buffered,
                authenticatedSender: identity.publicKeyHex
            )
        )

        try service.resetForPanic()

        var deliveredAfterPanic: [NdrDecryptedMessage] = []
        service.onDecryptedMessage = { deliveredAfterPanic.append($0) }
        #expect(!service.isConfigured)
        #expect(service.configuredPubkeyHex == nil)
        #expect(clearedDeviceID)
        #expect(!FileManager.default.fileExists(atPath: storage.path))
        #expect(deliveredAfterPanic.isEmpty)
    }

    @Test("NdrNostrService does not publish invite/response events to Nostr relays")
    @MainActor
    func ndrNostrService_doesNotPublishHandshakeEvents() throws {
        let relay = FakeRelayManager()
        let storage = try makeTempDir(label: "ndr-no-publish")
        let identity = try NostrIdentity.generate()
        let svc = NdrNostrService(
            relayManager: relay,
            deviceId: "test-device",
            rolloutEnabled: true,
            storageDirectoryProvider: { storage }
        )

        svc.configureIfNeeded(identity: identity)

        let inviteJson = try #require(svc.currentInviteEventJson(), "Expected device invite to be cached")
        #expect(try extractNostrKind(json: inviteJson) == 30078)

        // Service may publish other maintenance events, but not invites or giftwrap responses.
        #expect(!relay.sentEvents.contains(where: { isDoubleRatchetInviteEvent($0) }))
        #expect(!relay.sentEvents.contains(where: { $0.kind == 1059 }))

        // Service should not ask relays to subscribe to giftwrap responses (kind 1059) or invite discovery.
        #expect(!relay.subscriptions.contains(where: { $0.filter.kinds?.contains(1059) == true }))
        #expect(!relay.subscriptions.contains(where: { sub in
            (sub.filter.kinds?.contains(30078) == true) &&
            (sub.filter.tagFilters?["l"]?.contains("double-ratchet/invites") == true)
        }))
    }

    @Test("Out-of-band invite/response over BLE can establish a session and decrypt kind 1060 messages")
    @MainActor
    func oobHandshake_establishesSession_andDecrypts() throws {
        let aliceRelay = FakeRelayManager()
        let bobRelay = FakeRelayManager()
        let aliceStorage = try makeTempDir(label: "ndr-alice")
        let bobStorage = try makeTempDir(label: "ndr-bob")

        let aliceKeys = generateKeypair()
        let bobKeys = generateKeypair()
        let aliceIdentity = try NostrIdentity(privateKeyData: try #require(Data(hexString: aliceKeys.privateKeyHex)))
        let bobIdentity = try NostrIdentity(privateKeyData: try #require(Data(hexString: bobKeys.privateKeyHex)))

        let aliceSvc = NdrNostrService(
            relayManager: aliceRelay,
            deviceId: "alice-device",
            rolloutEnabled: true,
            storageDirectoryProvider: { aliceStorage }
        )
        let bobSvc = NdrNostrService(
            relayManager: bobRelay,
            deviceId: "bob-device",
            rolloutEnabled: true,
            storageDirectoryProvider: { bobStorage }
        )

        aliceSvc.configureIfNeeded(identity: aliceIdentity)
        bobSvc.configureIfNeeded(identity: bobIdentity)

        // Exchange BOTH device invites out-of-band (mutual favorites) and bounce any resulting
        // handshake events until both sides are quiescent.
        let aliceInvite = try #require(aliceSvc.currentInviteEventJson())
        let bobInvite = try #require(bobSvc.currentInviteEventJson())
        var aToB: [String] = [aliceInvite]
        var bToA: [String] = [bobInvite]
        var sawResponse1059 = false
        for _ in 0..<10 {
            let nextBToA = aToB.flatMap {
                bobSvc.processOutOfBandEventJson(
                    $0,
                    expectedPeerPubkeyHex: aliceIdentity.publicKeyHex
                )
            } // Bob -> Alice
            let nextAToB = bToA.flatMap {
                aliceSvc.processOutOfBandEventJson(
                    $0,
                    expectedPeerPubkeyHex: bobIdentity.publicKeyHex
                )
            } // Alice -> Bob
            if nextBToA.contains(where: { (try? extractNostrKind(json: $0)) == 1059 }) { sawResponse1059 = true }
            if nextAToB.contains(where: { (try? extractNostrKind(json: $0)) == 1059 }) { sawResponse1059 = true }
            aToB = nextAToB
            bToA = nextBToA
            if aToB.isEmpty && bToA.isEmpty { break }
        }
        #expect(sawResponse1059)

        #expect(aliceSvc.hasActiveSession(with: bobIdentity.publicKeyHex))
        #expect(bobSvc.hasActiveSession(with: aliceIdentity.publicKeyHex))

        // Now Alice can send via DR (kind 1060), which is published to Nostr relays.
        aliceRelay.resetSentEvents()
        #expect(aliceSvc.sendIfPossible("bitchat1:hello", to: bobIdentity.publicKeyHex))
        let outbound = aliceRelay.sentEvents.filter { $0.kind == 1060 }
        #expect(!outbound.isEmpty)

        var decryptedInner: NostrEvent?
        bobSvc.onDecryptedMessage = { message in
            decryptedInner = message.event
        }

        for event in outbound {
            bobSvc.processInboundRelayEvent(event)
        }

        let inner = try #require(decryptedInner, "Expected decrypted inner event to surface from SessionManagerHandle")
        #expect(inner.pubkey.lowercased() == aliceIdentity.publicKeyHex.lowercased())
        #expect(inner.content == "bitchat1:hello")
    }

    private func makeTempDir(label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bitchat-tests-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    private func isDoubleRatchetInviteEvent(_ event: NostrEvent) -> Bool {
        guard event.kind == 30078 else { return false }
        for tag in event.tags where tag.count >= 2 {
            if tag[0] == "l", tag[1] == "double-ratchet/invites" { return true }
            if tag[0] == "d", tag[1].hasPrefix("double-ratchet/invites/") { return true }
        }
        return false
    }

    private func isInvitePublish(_ event: PubSubEvent) -> Bool {
        guard event.kind == "publish_signed",
              let json = event.eventJson,
              (try? extractNostrKind(json: json)) == 30078,
              let nostrEvent = try? JSONDecoder().decode(
                NostrEvent.self,
                from: Data(json.utf8)
              ) else {
            return false
        }
        return isDoubleRatchetInviteEvent(nostrEvent)
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
        return try event.sign(with: identity.schnorrSigningKey())
    }

    private func makeDecryptedPubSubEvent(
        _ event: NostrEvent,
        authenticatedSender: String,
        conversationOwner: String? = nil
    ) -> PubSubEvent {
        PubSubEvent(
            kind: "decrypted_message",
            subid: nil,
            filterJson: nil,
            eventJson: nil,
            senderPubkeyHex: authenticatedSender,
            senderDevicePubkeyHex: authenticatedSender,
            conversationOwnerPubkeyHex: conversationOwner,
            content: try? event.jsonString(),
            eventId: String(repeating: "a", count: 64)
        )
    }

    private func makeChildManager(
        identity: NostrIdentity,
        owner: NostrIdentity,
        deviceID: String
    ) throws -> SessionManagerHandle {
        let manager = try SessionManagerHandle(
            ourPubkeyHex: identity.publicKeyHex,
            ourIdentityPrivkeyHex: identity.privateKey.hexEncodedString(),
            deviceId: deviceID,
            ownerPubkeyHex: owner.publicKeyHex
        )
        try manager.`init`()
        return manager
    }

    private func inviteEventJson(from manager: SessionManagerHandle) throws -> String {
        try #require(
            try manager.drainEvents()
                .first(where: { isInvitePublish($0) })?
                .eventJson
        )
    }

    private func makeAppKeysEvent(
        owner: NostrIdentity,
        devices: [NostrIdentity],
        timestamp: Int? = nil
    ) throws -> NostrEvent {
        let profileID = UUID().uuidString.lowercased()
        let timestamp = timestamp ?? Int(Date().timeIntervalSince1970)
        var tags: [[String]] = [
            ["d", profileID],
            ["i", profileID, "subject"],
            ["owner_pubkey", owner.publicKeyHex],
            ["p", owner.publicKeyHex],
            ["schema", "1"],
            ["type", "app_keys_roster_snapshot"]
        ]
        for device in devices {
            tags.append(["device", device.publicKeyHex, String(timestamp)])
            tags.append(["p", device.publicKeyHex])
        }
        let event = try NostrEvent(
            from: [
                "pubkey": owner.publicKeyHex,
                "created_at": timestamp,
                "kind": 37368,
                "tags": tags,
                "content": ""
            ]
        )
        return try event.sign(with: owner.schnorrSigningKey())
    }

    private func extractNostrKind(json: String) throws -> Int {
        let data = Data(json.utf8)
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        let dict = try #require(obj as? [String: Any], "Event should be a JSON object")
        return try #require(dict["kind"] as? Int, "Event should have integer kind")
    }

}
