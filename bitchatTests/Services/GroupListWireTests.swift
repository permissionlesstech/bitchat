//
// GroupListWireTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import Foundation
import Testing
import BitFoundation
@testable import bitchat

struct GroupListWireTests {
    private let signer = Curve25519.Signing.PrivateKey()
    private let groupID = Data((0..<16).map { UInt8($0) })
    private let key = Data(repeating: 0x42, count: 32)
    private let alice = Data(repeating: 0xA1, count: 32)
    private let bob = Data(repeating: 0xB0, count: 32)
    private let farFuture = UInt64.max

    private var signingKey: Data { signer.publicKey.rawRepresentation }

    private func sign(_ data: Data) -> Data? { try? signer.signature(for: data) }

    private func itemID(_ seed: UInt8) -> Data {
        Data(repeating: seed, count: GroupList.itemIDLength)
    }

    private var sampleDelta: GroupListDelta {
        [
            itemID(1): GroupListItemState(
                added: .init(stamp: GroupListStamp(timestampMs: 10, author: alice), text: "water ☕️"),
                checked: .init(stamp: GroupListStamp(timestampMs: 20, author: bob), value: true)
            ),
            itemID(2): GroupListItemState(removed: GroupListStamp(timestampMs: 30, author: bob))
        ]
    }

    // MARK: Coding

    @Test
    func deltaRoundTripsAndEncodesDeterministically() throws {
        let encoded = try #require(GroupListCoding.encode(sampleDelta))
        #expect(GroupListCoding.encode(sampleDelta) == encoded)
        #expect(GroupListCoding.decode(encoded, notAfterMs: farFuture) == GroupListUpdate(delta: sampleDelta, isSnapshot: false))
    }

    @Test
    func snapshotsAreMarkedAsSuch() throws {
        let encoded = try #require(GroupListCoding.encode(sampleDelta, isSnapshot: true))
        #expect(GroupListCoding.decode(encoded, notAfterMs: farFuture) == GroupListUpdate(delta: sampleDelta, isSnapshot: true))

        var unknownKind = encoded
        unknownKind[unknownKind.startIndex + 1] = 7
        #expect(GroupListCoding.decode(unknownKind, notAfterMs: farFuture) == nil)
    }

    @Test
    func malformedDeltasAreRejected() throws {
        let encoded = try #require(GroupListCoding.encode(sampleDelta))

        #expect(GroupListCoding.decode(Data(), notAfterMs: farFuture) == nil)
        #expect(GroupListCoding.decode(encoded.dropLast(), notAfterMs: farFuture) == nil)
        #expect(GroupListCoding.decode(encoded + Data([0]), notAfterMs: farFuture) == nil)

        var badVersion = encoded
        badVersion[badVersion.startIndex] = 9
        #expect(GroupListCoding.decode(badVersion, notAfterMs: farFuture) == nil)

        // Flags of the first record (sorted: itemID(1)) sit after version,
        // kind, count, and the 16-byte ID.
        var unknownFlag = encoded
        unknownFlag[unknownFlag.startIndex + 4 + 16] |= 0x80
        #expect(GroupListCoding.decode(unknownFlag, notAfterMs: farFuture) == nil)

        #expect(GroupListCoding.decode(Data([GroupListCoding.version, 0, 0, 0]), notAfterMs: farFuture) == nil)
    }

    @Test
    func textThatWouldNotSurviveCleanupIsRejected() throws {
        for text in ["two\nlines", " padded ", String(repeating: "x", count: GroupList.maxTextBytes + 1)] {
            let delta: GroupListDelta = [itemID(1): GroupListItemState(added: .init(stamp: GroupListStamp(timestampMs: 1, author: alice), text: text))]
            if let encoded = GroupListCoding.encode(delta) {
                #expect(GroupListCoding.decode(encoded, notAfterMs: farFuture) == nil)
            }
        }
    }

    @Test
    func futureDatedRegistersAreDropped() throws {
        let encoded = try #require(GroupListCoding.encode(sampleDelta))
        let decoded = try #require(GroupListCoding.decode(encoded, notAfterMs: 15)?.delta)
        #expect(decoded[itemID(1)]?.added != nil)
        #expect(decoded[itemID(1)]?.checked == nil)
        #expect(decoded[itemID(2)]?.removed == nil)
    }

    @Test
    func aFullListSnapshotFitsInOneGroupMessage() throws {
        var list = GroupList()
        let longText = String(repeating: "x", count: GroupList.maxTextBytes)
        var delta: GroupListDelta = [:]
        for index in 0..<GroupList.maxRecords {
            var id = itemID(0)
            id[0] = UInt8(index)
            let added = GroupListItemState.Added(stamp: GroupListStamp(timestampMs: UInt64(index), author: alice), text: longText)
            let checked = GroupListItemState.Checked(stamp: GroupListStamp(timestampMs: UInt64(index) + 1, author: bob), value: true)
            let removed = index < GroupList.maxVisibleItems ? nil : GroupListStamp(timestampMs: 9_999, author: bob)
            delta[id] = GroupListItemState(added: added, checked: checked, removed: removed)
        }
        list.merge(delta)
        #expect(list.items.count == GroupList.maxVisibleItems)

        let encoded = try #require(GroupListCoding.encode(list.snapshot, isSnapshot: true))
        // A v1 frame carries 65,535 bytes; leave room for the inner TLVs,
        // the AEAD tag, and the envelope.
        #expect(encoded.count < 60_000)

        var restored = GroupList()
        restored.merge(try #require(GroupListCoding.decode(encoded, notAfterMs: farFuture)?.delta))
        #expect(restored.items == list.items)
    }

    // MARK: Seal / open

    private func sealedUpdate(_ update: Data, sign: (Data) -> Data?) throws -> GroupMessageEnvelope {
        let payload = try GroupCrypto.sealListUpdate(
            update,
            messageID: "list-1",
            senderNickname: "alice",
            senderSigningKey: signingKey,
            timestampMs: 1_750_000_000_000,
            groupID: groupID,
            epoch: 3,
            key: key,
            sign: sign
        )
        return try #require(GroupMessageEnvelope.decode(payload))
    }

    @Test
    func listUpdateSealsAndOpens() throws {
        let update = try #require(GroupListCoding.encode(sampleDelta))
        let plaintext = try GroupCrypto.openMessage(try sealedUpdate(update, sign: sign), key: key)
        #expect(plaintext.listUpdate == update)
        #expect(plaintext.content.isEmpty)
        #expect(plaintext.senderSigningKey == signingKey)
        #expect(plaintext.messageID == "list-1")
    }

    @Test
    func chatMessagesCarryNoListUpdate() throws {
        let payload = try GroupCrypto.sealMessage(
            content: "hi",
            messageID: "msg-1",
            senderNickname: "alice",
            senderSigningKey: signingKey,
            timestampMs: 1,
            groupID: groupID,
            epoch: 3,
            key: key,
            sign: sign
        )
        let plaintext = try GroupCrypto.openMessage(try #require(GroupMessageEnvelope.decode(payload)), key: key)
        #expect(plaintext.listUpdate == nil)
        #expect(plaintext.content == "hi")
    }

    @Test
    func aChatDomainSignatureDoesNotAuthorizeAListUpdate() throws {
        let update = try #require(GroupListCoding.encode(sampleDelta))
        let crossDomain: (Data) -> Data? = { listBytes in
            var chatBytes = GroupCrypto.messageSigningDomain
            chatBytes.append(listBytes.dropFirst(GroupCrypto.listSigningDomain.count))
            return try? signer.signature(for: chatBytes)
        }
        let envelope = try sealedUpdate(update, sign: crossDomain)
        #expect(throws: GroupCryptoError.badSenderSignature) {
            _ = try GroupCrypto.openMessage(envelope, key: key)
        }
    }

    @Test
    func emptyUpdatesAreNotSealed() {
        #expect(throws: GroupCryptoError.malformedPayload) {
            _ = try sealedUpdate(Data(), sign: sign)
        }
    }
}
