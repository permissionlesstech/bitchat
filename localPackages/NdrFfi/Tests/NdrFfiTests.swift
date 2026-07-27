import Foundation
import XCTest
@testable import NdrFfi

final class NdrFfiTests: XCTestCase {
    func testVersionAndKeyGeneration() throws {
        XCTAssertFalse(NdrFfi.version().isEmpty)

        let first = generateKeypair()
        let second = generateKeypair()
        XCTAssertEqual(first.publicKeyHex.count, 64)
        XCTAssertEqual(first.privateKeyHex.count, 64)
        XCTAssertNotNil(Data(hexString: first.publicKeyHex))
        XCTAssertNotNil(Data(hexString: first.privateKeyHex))
        XCTAssertNotEqual(first.publicKeyHex, second.publicKeyHex)
        XCTAssertNotEqual(first.privateKeyHex, second.privateKeyHex)
        XCTAssertEqual(
            try derivePublicKey(privateKeyHex: first.privateKeyHex),
            first.publicKeyHex
        )
    }

    func testCurrentInviteIsIdentityBoundKind30078() throws {
        let keys = generateKeypair()
        let manager = try makeManager(keys)
        let inviteJSON = try manager.currentInviteEventJson()
        let invite = try PairwiseInvite.fromEventJson(eventJson: inviteJSON)

        XCTAssertEqual(try extractNostrKind(json: inviteJSON), 30078)
        XCTAssertEqual(invite.getPeerPubkeyHex(), keys.publicKeyHex)
        XCTAssertEqual(
            try PairwiseInvite.fromUrl(
                url: invite.toUrl(root: "https://b")
            ).getPeerPubkeyHex(),
            keys.publicKeyHex
        )
    }

    func testAuthenticatedHandshakeBecomesBidirectionallySendReady() throws {
        let aliceKeys = generateKeypair()
        let bobKeys = generateKeypair()
        let alice = try makeManager(aliceKeys)
        let bob = try makeManager(bobKeys)

        let artifacts = try establishSession(
            inviter: alice,
            inviterKeys: aliceKeys,
            acceptor: bob,
            acceptorKeys: bobKeys
        )

        XCTAssertEqual(artifacts.response.peerPubkeyHex, aliceKeys.publicKeyHex)
        XCTAssertEqual(try extractNostrKind(json: artifacts.responseJSON), 1059)
        XCTAssertEqual(try extractNostrKind(json: artifacts.bootstrapJSON), 1060)
        XCTAssertEqual(
            try alice.sessionInfo(peerPubkeyHex: bobKeys.publicKeyHex)?
                .sendReady,
            true
        )
        XCTAssertEqual(
            try bob.sessionInfo(peerPubkeyHex: aliceKeys.publicKeyHex)?
                .sendReady,
            true
        )
    }

    func testSendProducesDurableUnsignedDeliveryWithExpiration() throws {
        let aliceKeys = generateKeypair()
        let bobKeys = generateKeypair()
        let alice = try makeManager(aliceKeys)
        let bob = try makeManager(bobKeys)
        _ = try establishSession(
            inviter: alice,
            inviterKeys: aliceKeys,
            acceptor: bob,
            acceptorKeys: bobKeys
        )

        let expiration = UInt64(Date().timeIntervalSince1970) + 60
        let result = try bob.sendText(
            peerPubkeyHex: aliceKeys.publicKeyHex,
            text: "hello from bob",
            expiresAtSeconds: expiration
        )
        let publish = try requireAction(
            in: bob,
            kind: "publish",
            outerEventID: result.outerEventId
        )
        let outerJSON = try XCTUnwrap(publish.eventJson)
        try alice.processEvent(eventJson: outerJSON)

        let delivery = try requireAction(
            in: alice,
            kind: "delivery",
            innerEventID: result.innerEventId
        )
        let innerJSON = try XCTUnwrap(delivery.innerEventJson)
        let inner = try jsonObject(innerJSON)
        XCTAssertEqual(inner["kind"] as? Int, 14)
        XCTAssertEqual(inner["pubkey"] as? String, bobKeys.publicKeyHex)
        XCTAssertEqual(inner["content"] as? String, "hello from bob")
        XCTAssertNil(inner["sig"] as? String)
        XCTAssertEqual(delivery.peerPubkeyHex, bobKeys.publicKeyHex)
        XCTAssertEqual(delivery.outerEventId, result.outerEventId)
        XCTAssertEqual(delivery.expiresAtSeconds, expiration)

        try bob.ackActions(actionIds: [publish.actionId])
        try alice.ackActions(actionIds: [delivery.actionId])
        XCTAssertFalse(
            try bob.pendingActions().contains {
                $0.actionId == publish.actionId
            }
        )
        XCTAssertFalse(
            try alice.pendingActions().contains {
                $0.actionId == delivery.actionId
            }
        )
    }

    func testSameSecondSendsHaveDistinctIDs() throws {
        let aliceKeys = generateKeypair()
        let bobKeys = generateKeypair()
        let alice = try makeManager(aliceKeys)
        let bob = try makeManager(bobKeys)
        _ = try establishSession(
            inviter: alice,
            inviterKeys: aliceKeys,
            acceptor: bob,
            acceptorKeys: bobKeys
        )

        let first = try bob.sendText(
            peerPubkeyHex: aliceKeys.publicKeyHex,
            text: "first",
            expiresAtSeconds: nil
        )
        let second = try bob.sendText(
            peerPubkeyHex: aliceKeys.publicKeyHex,
            text: "second",
            expiresAtSeconds: nil
        )

        XCTAssertNotEqual(first.innerEventId, second.innerEventId)
        XCTAssertNotEqual(first.outerEventId, second.outerEventId)
    }

    func testPendingPublishAndDeliverySurviveRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ndr-ffi-restart-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let alicePath = root.appendingPathComponent("alice").path
        let bobPath = root.appendingPathComponent("bob").path
        let aliceKeys = generateKeypair()
        let bobKeys = generateKeypair()
        var outerJSON = ""
        var result: PairwiseSendResult?

        do {
            let alice = try makeManager(aliceKeys, storagePath: alicePath)
            let bob = try makeManager(bobKeys, storagePath: bobPath)
            _ = try establishSession(
                inviter: alice,
                inviterKeys: aliceKeys,
                acceptor: bob,
                acceptorKeys: bobKeys
            )
            let sent = try bob.sendText(
                peerPubkeyHex: aliceKeys.publicKeyHex,
                text: "survives restart",
                expiresAtSeconds: nil
            )
            result = sent
            outerJSON = try XCTUnwrap(
                requireAction(
                    in: bob,
                    kind: "publish",
                    outerEventID: sent.outerEventId
                ).eventJson
            )
        }

        let sent = try XCTUnwrap(result)
        do {
            let restoredBob = try makeManager(
                bobKeys,
                storagePath: bobPath
            )
            XCTAssertNotNil(
                try restoredBob.pendingActions().first {
                    $0.outerEventId == sent.outerEventId
                        && $0.kind == "publish"
                }
            )
        }

        do {
            let restoredAlice = try makeManager(
                aliceKeys,
                storagePath: alicePath
            )
            try restoredAlice.processEvent(eventJson: outerJSON)
        }
        let restoredAgain = try makeManager(
            aliceKeys,
            storagePath: alicePath
        )
        let delivery = try requireAction(
            in: restoredAgain,
            kind: "delivery",
            innerEventID: sent.innerEventId
        )
        XCTAssertEqual(
            try jsonObject(
                XCTUnwrap(delivery.innerEventJson)
            )["content"] as? String,
            "survives restart"
        )
    }

    func testInvalidInviteAndAuthenticatedPeerMismatchAreRejected() throws {
        let aliceKeys = generateKeypair()
        let bobKeys = generateKeypair()
        let unexpectedKeys = generateKeypair()
        let alice = try makeManager(aliceKeys)
        let bob = try makeManager(bobKeys)

        XCTAssertThrowsError(
            try bob.acceptInviteFromEventJson(
                eventJson:
                    #"{"kind":1,"id":"bad","pubkey":"bad","created_at":0,"content":"","tags":[],"sig":"bad"}"#,
                authenticatedPeerPubkeyHex: aliceKeys.publicKeyHex
            )
        )
        XCTAssertThrowsError(
            try bob.acceptInviteFromEventJson(
                eventJson: alice.currentInviteEventJson(),
                authenticatedPeerPubkeyHex: unexpectedKeys.publicKeyHex
            )
        )
    }

    private func makeManager(
        _ keys: FfiKeyPair,
        storagePath: String? = nil
    ) throws -> PairwiseManager {
        let path: String
        if let storagePath {
            path = storagePath
        } else {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ndr-ffi-test-\(UUID().uuidString)",
                    isDirectory: true
                )
            path = directory.path
            addTeardownBlock {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        return try PairwiseManager.newWithStoragePath(
            ourPubkeyHex: keys.publicKeyHex,
            ourIdentityPrivateKeyHex: keys.privateKeyHex,
            storagePath: path
        )
    }
}

private struct HandshakeArtifacts {
    let response: PairwiseAction
    let responseJSON: String
    let bootstrapJSON: String
}

private func establishSession(
    inviter: PairwiseManager,
    inviterKeys: FfiKeyPair,
    acceptor: PairwiseManager,
    acceptorKeys: FfiKeyPair
) throws -> HandshakeArtifacts {
    let inviteJSON = try inviter.currentInviteEventJson()
    let accepted = try acceptor.acceptInviteFromEventJson(
        eventJson: inviteJSON,
        authenticatedPeerPubkeyHex: inviterKeys.publicKeyHex
    )
    XCTAssertTrue(accepted.createdNewSession)

    let response = try requireAction(in: acceptor, kind: "out_of_band")
    let responseJSON = try XCTUnwrap(response.eventJson)
    let bootstrap = try requireAction(in: acceptor, kind: "publish")
    let bootstrapJSON = try XCTUnwrap(bootstrap.eventJson)
    try inviter.processOutOfBandResponse(
        eventJson: responseJSON,
        authenticatedPeerPubkeyHex: acceptorKeys.publicKeyHex
    )
    XCTAssertEqual(
        try inviter.sessionInfo(
            peerPubkeyHex: acceptorKeys.publicKeyHex
        )?.sendReady,
        false
    )
    try inviter.processEvent(eventJson: bootstrapJSON)
    try acceptor.ackActions(
        actionIds: [response.actionId, bootstrap.actionId]
    )
    return HandshakeArtifacts(
        response: response,
        responseJSON: responseJSON,
        bootstrapJSON: bootstrapJSON
    )
}

private func requireAction(
    in manager: PairwiseManager,
    kind: String,
    innerEventID: String? = nil,
    outerEventID: String? = nil
) throws -> PairwiseAction {
    try XCTUnwrap(
        try manager.pendingActions().first { action in
            action.kind == kind
                && (innerEventID == nil || action.innerEventId == innerEventID)
                && (outerEventID == nil || action.outerEventId == outerEventID)
        },
        "Expected pending \(kind) action"
    )
}

private func extractNostrKind(json: String) throws -> Int {
    try XCTUnwrap(
        jsonObject(json)["kind"] as? Int,
        "Event should have an integer kind"
    )
}

private func jsonObject(_ json: String) throws -> [String: Any] {
    try XCTUnwrap(
        JSONSerialization.jsonObject(
            with: Data(json.utf8),
            options: []
        ) as? [String: Any],
        "Expected a JSON object"
    )
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        self = data
    }
}
