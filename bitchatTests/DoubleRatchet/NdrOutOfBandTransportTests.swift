//
// NdrOutOfBandTransportTests.swift
// bitchatTests
//

import Foundation
import NdrFfi
import Testing
@testable import bitchat

@MainActor
final class FakeRelayManager: NostrRelayManaging {
    struct Subscription {
        let id: String
        let filter: NostrFilter
    }

    private(set) var subscriptions: [Subscription] = []
    private(set) var unsubscribedIDs: [String] = []
    private(set) var sentEvents: [NostrEvent] = []

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
        subscriptions.append(Subscription(id: id, filter: filter))
    }

    func unsubscribe(id: String) {
        unsubscribedIDs.append(id)
    }

    func sendEvent(_ event: NostrEvent, to relayUrls: [String]?) {
        sentEvents.append(event)
    }
}

struct NdrOutOfBandTransportTests {

    @Test("NdrNostrService does not publish invite/response events to Nostr relays")
    @MainActor
    func ndrNostrService_doesNotPublishHandshakeEvents() throws {
        let relay = FakeRelayManager()
        let storage = try makeTempDir(label: "ndr-no-publish")
        let identity = try NostrIdentity.generate()
        let svc = NdrNostrService(
            relayManager: relay,
            deviceId: "test-device",
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
            storageDirectoryProvider: { aliceStorage }
        )
        let bobSvc = NdrNostrService(
            relayManager: bobRelay,
            deviceId: "bob-device",
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
            let nextBToA = aToB.flatMap { bobSvc.processOutOfBandEventJson($0) } // Bob -> Alice
            let nextAToB = bToA.flatMap { aliceSvc.processOutOfBandEventJson($0) } // Alice -> Bob
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
        bobSvc.onDecryptedMessage = { inner in
            decryptedInner = inner
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

    private func extractNostrKind(json: String) throws -> Int {
        let data = Data(json.utf8)
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        let dict = try #require(obj as? [String: Any], "Event should be a JSON object")
        return try #require(dict["kind"] as? Int, "Event should have integer kind")
    }

}
