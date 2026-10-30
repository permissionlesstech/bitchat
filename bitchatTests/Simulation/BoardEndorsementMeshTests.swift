//
// BoardEndorsementMeshTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// Board endorsements over real engines: a post and its endorsement relay
/// across a line topology and land in every node's own store.
@Suite(.serialized)
struct BoardEndorsementMeshTests {

    private func signedUrgentPost(by service: BLEService) throws -> BoardPostPacket {
        let postID = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = service.noiseSigningPublicKeyData()
        let createdAt = UInt64(Date().timeIntervalSince1970 * 1000)
        let expiresAt = createdAt + 60 * 60 * 1000
        let signingBytes = BoardPostPacket.signingBytes(
            postID: postID,
            geohash: "",
            content: "flooding at the underpass",
            authorSigningKey: key,
            authorNickname: "alice",
            createdAt: createdAt,
            expiresAt: expiresAt,
            flags: BoardPostPacket.urgentFlag
        )
        return BoardPostPacket(
            postID: postID,
            geohash: "",
            content: "flooding at the underpass",
            authorSigningKey: key,
            authorNickname: "alice",
            createdAt: createdAt,
            expiresAt: expiresAt,
            flags: BoardPostPacket.urgentFlag,
            signature: try #require(service.noiseSignData(signingBytes))
        )
    }

    private func signedEndorsement(of post: BoardPostPacket, by service: BLEService) throws -> BoardEndorsementPacket {
        let key = service.noiseSigningPublicKeyData()
        let endorsedAt = UInt64(Date().timeIntervalSince1970 * 1000)
        let signingBytes = BoardEndorsementPacket.signingBytes(
            postID: post.postID,
            postAuthorSigningKey: post.authorSigningKey,
            postDigest: post.digest,
            endorserSigningKey: key,
            endorsedAt: endorsedAt
        )
        return BoardEndorsementPacket(
            postID: post.postID,
            postAuthorSigningKey: post.authorSigningKey,
            postDigest: post.digest,
            endorserSigningKey: key,
            endorsedAt: endorsedAt,
            signature: try #require(service.noiseSignData(signingBytes))
        )
    }

    @Test
    func endorsementRelaysBackToTheAuthorAcrossALine() throws {
        let mesh = SimulatedMesh()
        let a = mesh.addNode(nickname: "alice")
        let b = mesh.addNode(nickname: "bob")
        let c = mesh.addNode(nickname: "carol")
        let stores = (0..<3).map { _ in BoardStore(persistsToDisk: false) }
        for (node, store) in zip([a, b, c], stores) {
            node.service.boardStore = store
        }
        mesh.connect(0, 1)
        mesh.connect(1, 2)
        mesh.announceAll()

        let post = try signedUrgentPost(by: a.service)
        a.service.sendBoardPayload(BoardWire.post(post).encode())
        mesh.settleUntil { stores[2].post(withID: post.postID) != nil }
        #expect(stores[2].post(withID: post.postID) != nil)

        let endorsement = try signedEndorsement(of: post, by: c.service)
        c.service.sendBoardPayload(BoardWire.endorsement(endorsement).encode())
        mesh.settleUntil { !stores[0].endorserKeys(forPostID: post.postID).isEmpty }

        let carolKey = c.service.noiseSigningPublicKeyData()
        #expect(stores[0].endorserKeys(forPostID: post.postID) == [carolKey])
        #expect(stores[1].endorserKeys(forPostID: post.postID) == [carolKey])
        #expect(stores[2].endorserKeys(forPostID: post.postID) == [carolKey])
    }

    @Test
    func selfEndorsementIsStoredNowhere() throws {
        let mesh = SimulatedMesh()
        let a = mesh.addNode(nickname: "alice")
        _ = mesh.addNode(nickname: "bob")
        let stores = (0..<2).map { _ in BoardStore(persistsToDisk: false) }
        for (node, store) in zip(mesh.nodes, stores) {
            node.service.boardStore = store
        }
        mesh.connect(0, 1)
        mesh.announceAll()

        let post = try signedUrgentPost(by: a.service)
        a.service.sendBoardPayload(BoardWire.post(post).encode())
        mesh.settleUntil { stores[1].post(withID: post.postID) != nil }

        let selfEndorsement = try signedEndorsement(of: post, by: a.service)
        a.service.sendBoardPayload(BoardWire.endorsement(selfEndorsement).encode())
        mesh.advanceTime(by: 2)
        mesh.advanceTime(by: 2)

        #expect(stores[0].endorserKeys(forPostID: post.postID).isEmpty)
        #expect(stores[1].endorserKeys(forPostID: post.postID).isEmpty)
    }
}
