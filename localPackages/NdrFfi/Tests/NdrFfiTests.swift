import XCTest
@testable import NdrFfi

final class NdrFfiTests: XCTestCase {

    // MARK: - Version Tests

    func testVersion() {
        let v = NdrFfi.version()
        XCTAssertFalse(v.isEmpty, "Version should not be empty")
        print("ndr-ffi version: \(v)")
    }

    // MARK: - Keypair Tests

    func testKeypairGeneration() {
        let keypair = generateKeypair()

        XCTAssertEqual(keypair.publicKeyHex.count, 64, "Public key should be 64 hex characters")
        XCTAssertEqual(keypair.privateKeyHex.count, 64, "Private key should be 64 hex characters")

        // Verify they're valid hex
        XCTAssertNotNil(Data(hexString: keypair.publicKeyHex), "Public key should be valid hex")
        XCTAssertNotNil(Data(hexString: keypair.privateKeyHex), "Private key should be valid hex")

        print("Generated keypair - pubkey: \(keypair.publicKeyHex.prefix(16))...")
    }

    func testMultipleKeypairsAreDifferent() {
        let kp1 = generateKeypair()
        let kp2 = generateKeypair()

        XCTAssertNotEqual(kp1.publicKeyHex, kp2.publicKeyHex, "Different keypairs should have different public keys")
        XCTAssertNotEqual(kp1.privateKeyHex, kp2.privateKeyHex, "Different keypairs should have different private keys")
    }

    // MARK: - SessionManager Tests

    func testSessionManagerInitEmitsInviteEvent() throws {
        let keys = generateKeypair()
        let mgr = try SessionManagerHandle(
            ourPubkeyHex: keys.publicKeyHex,
            ourIdentityPrivkeyHex: keys.privateKeyHex,
            deviceId: "test-device",
            ownerPubkeyHex: nil
        )
        try mgr.`init`()

        let events = try mgr.drainEvents()
        let inviteEventJson = try XCTUnwrap(
            events.first(where: { $0.kind == "publish_signed" })?.eventJson,
            "Expected SessionManager to publish an invite on init"
        )
        XCTAssertEqual(try extractNostrKind(json: inviteEventJson), 30078)
    }

    func testSessionManagerAcceptInviteFromEventJsonEstablishesSession() throws {
        let alice = generateKeypair()
        let bob = generateKeypair()

        let aliceMgr = try SessionManagerHandle(
            ourPubkeyHex: alice.publicKeyHex,
            ourIdentityPrivkeyHex: alice.privateKeyHex,
            deviceId: "alice-device",
            ownerPubkeyHex: nil
        )
        let bobMgr = try SessionManagerHandle(
            ourPubkeyHex: bob.publicKeyHex,
            ourIdentityPrivkeyHex: bob.privateKeyHex,
            deviceId: "bob-device",
            ownerPubkeyHex: nil
        )
        try aliceMgr.`init`()
        try bobMgr.`init`()

        let aliceInitEvents = try aliceMgr.drainEvents()
        _ = try bobMgr.drainEvents() // discard Bob init invite

        let aliceInviteEventJson = try XCTUnwrap(
            aliceInitEvents.first(where: { $0.kind == "publish_signed" })?.eventJson,
            "Expected Alice to publish an invite on init"
        )
        XCTAssertEqual(try extractNostrKind(json: aliceInviteEventJson), 30078)

        let accept = try bobMgr.acceptInviteFromEventJson(eventJson: aliceInviteEventJson, ownerPubkeyHintHex: nil)
        XCTAssertTrue(accept.createdNewSession)

        let bobAfterAccept = try bobMgr.drainEvents()
        let responseEventJson = try XCTUnwrap(
            bobAfterAccept.first(where: { $0.kind == "publish_signed" && ((try? extractNostrKind(json: $0.eventJson ?? "")) == 1059) })?.eventJson,
            "Expected Bob to publish a giftwrap response after accepting invite"
        )
        XCTAssertEqual(try extractNostrKind(json: responseEventJson), 1059)

        try aliceMgr.processEvent(eventJson: responseEventJson)
        _ = try aliceMgr.drainEvents()

        XCTAssertNotNil(try aliceMgr.getActiveSessionState(peerPubkeyHex: bob.publicKeyHex))
        XCTAssertNotNil(try bobMgr.getActiveSessionState(peerPubkeyHex: alice.publicKeyHex))
    }

    func testSessionManagerSendTextDecryptsOnOtherSide() throws {
        let alice = generateKeypair()
        let bob = generateKeypair()

        let aliceMgr = try SessionManagerHandle(
            ourPubkeyHex: alice.publicKeyHex,
            ourIdentityPrivkeyHex: alice.privateKeyHex,
            deviceId: "alice-device",
            ownerPubkeyHex: nil
        )
        let bobMgr = try SessionManagerHandle(
            ourPubkeyHex: bob.publicKeyHex,
            ourIdentityPrivkeyHex: bob.privateKeyHex,
            deviceId: "bob-device",
            ownerPubkeyHex: nil
        )
        try aliceMgr.`init`()
        try bobMgr.`init`()

        let aliceInvite = try XCTUnwrap(
            try aliceMgr.drainEvents().first(where: { $0.kind == "publish_signed" })?.eventJson
        )
        _ = try bobMgr.drainEvents() // discard Bob init invite

        _ = try bobMgr.acceptInviteFromEventJson(eventJson: aliceInvite, ownerPubkeyHintHex: nil)
        let bobAfterAccept = try bobMgr.drainEvents()
        let bobResponse = try XCTUnwrap(
            bobAfterAccept.first(where: { $0.kind == "publish_signed" && ((try? extractNostrKind(json: $0.eventJson ?? "")) == 1059) })?.eventJson
        )
        try aliceMgr.processEvent(eventJson: bobResponse)
        _ = try aliceMgr.drainEvents()

        _ = try bobMgr.sendText(recipientPubkeyHex: alice.publicKeyHex, text: "hello from bob", expiresAtSeconds: nil)
        let bobOutbound = try bobMgr.drainEvents().compactMap { e -> String? in
            guard e.kind == "publish_signed", let json = e.eventJson else { return nil }
            return ((try? extractNostrKind(json: json)) == 1060) ? json : nil
        }
        XCTAssertFalse(bobOutbound.isEmpty, "Expected at least one kind 1060 message to publish")

        for eventJson in bobOutbound {
            try aliceMgr.processEvent(eventJson: eventJson)
        }
        let aliceEvents = try aliceMgr.drainEvents()
        let decryptedInner = try XCTUnwrap(
            aliceEvents.first(where: { $0.kind == "decrypted_message" })?.content,
            "Expected a decrypted inner event to surface"
        )
        XCTAssertEqual(try innerEventContent(json: decryptedInner), "hello from bob")
    }

    func testSessionManagerRejectsInvalidInviteEventJson() throws {
        let keys = generateKeypair()
        let mgr = try SessionManagerHandle(
            ourPubkeyHex: keys.publicKeyHex,
            ourIdentityPrivkeyHex: keys.privateKeyHex,
            deviceId: "test-device",
            ownerPubkeyHex: nil
        )
        try mgr.`init`()

        let notAnInvite = """
        {"kind":1,"id":"test","pubkey":"test","created_at":0,"content":"hello","tags":[],"sig":"test"}
        """
        XCTAssertThrowsError(try mgr.acceptInviteFromEventJson(eventJson: notAnInvite, ownerPubkeyHintHex: nil))
    }
}

// MARK: - Helper Extensions

extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var i = hexString.startIndex
        for _ in 0..<len {
            let j = hexString.index(i, offsetBy: 2)
            guard let byte = UInt8(hexString[i..<j], radix: 16) else {
                return nil
            }
            data.append(byte)
            i = j
        }
        self = data
    }
}

// MARK: - Test Helpers

private func extractNostrKind(json: String) throws -> Int {
    let data = Data(json.utf8)
    let obj = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dict = obj as? [String: Any] else { throw NSError(domain: "NdrFfiTests", code: 1) }
    guard let kind = dict["kind"] as? Int else { throw NSError(domain: "NdrFfiTests", code: 2) }
    return kind
}

private func innerEventContent(json: String) throws -> String {
    let data = Data(json.utf8)
    let obj = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dict = obj as? [String: Any] else { throw NSError(domain: "NdrFfiTests", code: 3) }
    guard let content = dict["content"] as? String else { throw NSError(domain: "NdrFfiTests", code: 4) }
    return content
}
