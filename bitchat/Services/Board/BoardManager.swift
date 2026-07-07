//
// BoardManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import Foundation

/// UI-facing coordinator for the bulletin board: builds and signs posts and
/// tombstones with the device's Noise signing key, hands them to the mesh
/// transport, and mirrors the store's live posts for SwiftUI.
@MainActor
final class BoardManager: ObservableObject {
    /// Live posts across all boards, newest state from the store.
    @Published private(set) var posts: [BoardPostPacket] = []

    private let transport: Transport
    private let store: BoardStore
    private let publishToNostr: (_ content: String, _ geohash: String, _ nickname: String) -> Void
    private var cancellable: AnyCancellable?

    init(
        transport: Transport,
        store: BoardStore = .shared,
        publishToNostr: ((String, String, String) -> Void)? = nil
    ) {
        self.transport = transport
        self.store = store
        self.publishToNostr = publishToNostr ?? Self.livePublishToNostr
        cancellable = store.$postsSnapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.posts = snapshot
            }
    }

    /// Posts for one board context, urgent first, then newest first.
    func posts(forGeohash geohash: String) -> [BoardPostPacket] {
        posts
            .filter { $0.geohash == geohash }
            .sorted {
                if $0.isUrgent != $1.isUrgent { return $0.isUrgent }
                return $0.createdAt > $1.createdAt
            }
    }

    func isOwnPost(_ post: BoardPostPacket) -> Bool {
        let key = transport.noiseSigningPublicKeyData()
        return !key.isEmpty && key == post.authorSigningKey
    }

    /// Creates, signs, and broadcasts a board post. Returns false when the
    /// content is empty/oversized or signing fails.
    @discardableResult
    func createPost(
        content: String,
        geohash: String,
        urgent: Bool,
        expiryDays: Int,
        nickname: String
    ) -> Bool {
        guard let trimmed = content.trimmedOrNilIfEmpty,
              trimmed.utf8.count <= BoardWireConstants.contentMaxBytes else {
            return false
        }
        let signingKey = transport.noiseSigningPublicKeyData()
        guard signingKey.count == BoardWireConstants.signingKeyLength else { return false }

        var cleanNickname = nickname
        while cleanNickname.utf8.count > BoardWireConstants.nicknameMaxBytes {
            cleanNickname.removeLast()
        }
        let createdAt = UInt64(Date().timeIntervalSince1970 * 1000)
        let lifetimeMs = min(
            UInt64(max(1, expiryDays)) * 24 * 60 * 60 * 1000,
            BoardWireConstants.maxLifetimeMs
        )
        let expiresAt = createdAt + lifetimeMs
        let flags: UInt8 = urgent ? BoardPostPacket.urgentFlag : 0
        var postID = Data(count: BoardWireConstants.postIDLength)
        let status = postID.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        guard status == errSecSuccess else { return false }

        let signingBytes = BoardPostPacket.signingBytes(
            postID: postID,
            geohash: geohash,
            content: trimmed,
            authorSigningKey: signingKey,
            authorNickname: cleanNickname,
            createdAt: createdAt,
            expiresAt: expiresAt,
            flags: flags
        )
        guard let signature = transport.noiseSignData(signingBytes) else {
            SecureLogger.error("Board: failed to sign post", category: .session)
            return false
        }
        let post = BoardPostPacket(
            postID: postID,
            geohash: geohash,
            content: trimmed,
            authorSigningKey: signingKey,
            authorNickname: cleanNickname,
            createdAt: createdAt,
            expiresAt: expiresAt,
            flags: flags,
            signature: signature
        )
        transport.sendBoardPayload(BoardWire.post(post).encode())

        // One-way Nostr bridge (v1): geohash posts also go out as kind-1
        // location notes so online users see them. No inbound merge yet.
        if !geohash.isEmpty {
            publishToNostr(trimmed, geohash, cleanNickname)
        }
        return true
    }

    /// Signs and broadcasts a tombstone for one of our own posts.
    @discardableResult
    func deletePost(_ post: BoardPostPacket) -> Bool {
        guard isOwnPost(post) else { return false }
        let deletedAt = UInt64(Date().timeIntervalSince1970 * 1000)
        let signingBytes = BoardTombstonePacket.signingBytes(postID: post.postID, deletedAt: deletedAt)
        guard let signature = transport.noiseSignData(signingBytes) else {
            SecureLogger.error("Board: failed to sign tombstone", category: .session)
            return false
        }
        let tombstone = BoardTombstonePacket(
            postID: post.postID,
            authorSigningKey: post.authorSigningKey,
            deletedAt: deletedAt,
            signature: signature
        )
        transport.sendBoardPayload(BoardWire.tombstone(tombstone).encode())
        return true
    }

    private static func livePublishToNostr(content: String, geohash: String, nickname: String) {
        let relays = GeoRelayDirectory.shared.closestRelays(toGeohash: geohash, count: TransportConfig.nostrGeoRelayCount)
        guard !relays.isEmpty else {
            SecureLogger.debug("Board: no geo relays for \(geohash); skipping Nostr bridge", category: .session)
            return
        }
        do {
            let identity = try NostrIdentityBridge().deriveIdentity(forGeohash: geohash)
            let event = try NostrProtocol.createGeohashTextNote(
                content: content,
                geohash: geohash,
                senderIdentity: identity,
                nickname: nickname
            )
            NostrRelayManager.shared.sendEvent(event, to: relays)
        } catch {
            SecureLogger.error("Board: failed to bridge post to Nostr: \(error)", category: .session)
        }
    }
}
