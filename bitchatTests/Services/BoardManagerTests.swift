//
// BoardManagerTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import CryptoKit
import Foundation
import Testing
@testable import bitchat

@MainActor
struct BoardManagerTests {

    private func makeManager(
        transport: MockTransport = MockTransport(),
        store: BoardStore = BoardStore(persistsToDisk: false),
        trusted: Set<Data> = []
    ) -> BoardManager {
        BoardManager(
            transport: transport,
            store: store,
            trustedSigningKeys: { trusted },
            publishToNostr: { _, _, _, _, _ in nil },
            deleteFromNostr: { _, _ in }
        )
    }

    private func makePost(
        author: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey(),
        urgent: Bool = true
    ) throws -> BoardPostPacket {
        let postID = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = author.publicKey.rawRepresentation
        let createdAt = UInt64(Date().timeIntervalSince1970 * 1000)
        let expiresAt = createdAt + 60 * 60 * 1000
        let flags: UInt8 = urgent ? BoardPostPacket.urgentFlag : 0
        let signingBytes = BoardPostPacket.signingBytes(
            postID: postID,
            geohash: "",
            content: "bridge is out on 5th",
            authorSigningKey: key,
            authorNickname: "scout",
            createdAt: createdAt,
            expiresAt: expiresAt,
            flags: flags
        )
        return BoardPostPacket(
            postID: postID,
            geohash: "",
            content: "bridge is out on 5th",
            authorSigningKey: key,
            authorNickname: "scout",
            createdAt: createdAt,
            expiresAt: expiresAt,
            flags: flags,
            signature: try author.signature(for: signingBytes)
        )
    }

    private func makeEndorsement(of post: BoardPostPacket, by endorser: Curve25519.Signing.PrivateKey) throws -> BoardWire {
        let endorserKey = endorser.publicKey.rawRepresentation
        let endorsedAt = UInt64(Date().timeIntervalSince1970 * 1000)
        return .endorsement(BoardEndorsementPacket(
            postID: post.postID,
            postAuthorSigningKey: post.authorSigningKey,
            postDigest: post.digest,
            endorserSigningKey: endorserKey,
            endorsedAt: endorsedAt,
            signature: try endorser.signature(for: BoardEndorsementPacket.signingBytes(
                postID: post.postID,
                postAuthorSigningKey: post.authorSigningKey,
                postDigest: post.digest,
                endorserSigningKey: endorserKey,
                endorsedAt: endorsedAt
            ))
        ))
    }

    private func packet(for wire: BoardWire) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.boardPost.rawValue,
            senderID: Data((0..<8).map { _ in UInt8.random(in: 0...255) }),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: wire.encode(),
            signature: nil,
            ttl: 7
        )
    }

    /// The store publishes snapshots on the main queue; let them land.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Endorsing

    @Test func endorsingAnUrgentPostSendsAVerifiableEndorsement() throws {
        let transport = MockTransport()
        let manager = makeManager(transport: transport)
        let post = try makePost()

        #expect(manager.endorsePost(post))
        let payload = try #require(transport.sentBoardPayloads.last)
        let wire = try #require(BoardWire.decode(from: payload))
        guard case .endorsement(let endorsement) = wire else {
            Issue.record("expected an endorsement payload")
            return
        }
        #expect(wire.verifySignature())
        #expect(endorsement.postID == post.postID)
        #expect(endorsement.postAuthorSigningKey == post.authorSigningKey)
        #expect(endorsement.endorserSigningKey == transport.noiseSigningPublicKeyData())
    }

    @Test func calmPostsAreNotOfferedForEndorsement() throws {
        let transport = MockTransport()
        let manager = makeManager(transport: transport)
        let post = try makePost(urgent: false)

        #expect(!manager.canEndorse(post))
        #expect(!manager.endorsePost(post))
        #expect(transport.sentBoardPayloads.isEmpty)
    }

    @Test func ownPostCannotBeEndorsed() throws {
        let transport = MockTransport()
        let manager = makeManager(transport: transport)
        let ownKey = transport.noiseSigningPublicKeyData()
        let signingBytes = BoardPostPacket.signingBytes(
            postID: Data(repeating: 0x01, count: 16),
            geohash: "",
            content: "mine",
            authorSigningKey: ownKey,
            authorNickname: "me",
            createdAt: 1,
            expiresAt: 2,
            flags: BoardPostPacket.urgentFlag
        )
        let own = BoardPostPacket(
            postID: Data(repeating: 0x01, count: 16),
            geohash: "",
            content: "mine",
            authorSigningKey: ownKey,
            authorNickname: "me",
            createdAt: 1,
            expiresAt: 2,
            flags: BoardPostPacket.urgentFlag,
            signature: try #require(transport.noiseSignData(signingBytes))
        )

        #expect(!manager.canEndorse(own))
        #expect(!manager.endorsePost(own))
        #expect(transport.sentBoardPayloads.isEmpty)
    }

    @Test func alreadyEndorsedPostIsNotOfferedAgain() async throws {
        let transport = MockTransport()
        let store = BoardStore(persistsToDisk: false)
        let manager = makeManager(transport: transport, store: store)
        let post = try makePost()
        store.ingest(.post(post), packet: packet(for: .post(post)))

        #expect(manager.endorsePost(post))
        let payload = try #require(transport.sentBoardPayloads.last)
        let sent = try #require(BoardWire.decode(from: payload))
        store.ingest(sent, packet: packet(for: sent))
        await settle { manager.hasEndorsed(post) }

        #expect(manager.hasEndorsed(post))
        #expect(!manager.canEndorse(post))
    }

    // MARK: - Confirmation counting

    @Test func onlyTrustedEndorsersCountAsConfirmation() async throws {
        let store = BoardStore(persistsToDisk: false)
        let friend = Curve25519.Signing.PrivateKey()
        let stranger = Curve25519.Signing.PrivateKey()
        let manager = makeManager(store: store, trusted: [friend.publicKey.rawRepresentation])
        let post = try makePost()
        store.ingest(.post(post), packet: packet(for: .post(post)))

        for endorser in [friend, stranger] {
            let wire = try makeEndorsement(of: post, by: endorser)
            store.ingest(wire, packet: packet(for: wire))
        }
        await settle { manager.endorsements[post.postID]?.count == 2 }

        #expect(manager.endorsements[post.postID]?.count == 2)
        #expect(manager.confirmationCount(for: post) == 1)
    }

    @Test func trustingTheAuthorDoesNotLetThemConfirmThemselves() async throws {
        let store = BoardStore(persistsToDisk: false)
        let author = Curve25519.Signing.PrivateKey()
        let manager = makeManager(store: store, trusted: [author.publicKey.rawRepresentation])
        let post = try makePost(author: author)
        store.ingest(.post(post), packet: packet(for: .post(post)))

        #expect(manager.confirmationCount(for: post) == 0)
    }

    @Test func postWithoutEndorsementsHasNoConfirmation() throws {
        let manager = makeManager(trusted: [Curve25519.Signing.PrivateKey().publicKey.rawRepresentation])
        #expect(manager.confirmationCount(for: try makePost()) == 0)
    }

    // MARK: - Notices row label

    @Test func rowLabelAnnouncesConfirmationAfterUrgency() {
        let label = NoticesView.Strings.rowAccessibilityLabel(author: "scout", content: "bridge out", urgent: true, confirmations: 2)
        let urgent = NoticesView.Strings.urgentBadge
        let confirmed = NoticesView.Strings.confirmedBadge(2)
        #expect(label.hasPrefix("\(urgent), \(confirmed), "))
        #expect(label.contains("bridge out"))
    }

    @Test func rowLabelOmitsConfirmationWhenNobodyTrustedConfirmed() {
        let label = NoticesView.Strings.rowAccessibilityLabel(author: "scout", content: "bridge out", urgent: true)
        #expect(!label.contains(NoticesView.Strings.confirmedBadge(0)))
        #expect(label.hasPrefix("\(NoticesView.Strings.urgentBadge), "))
    }
}
