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
    /// Publishes a bridged kind-1 note (expiring with the board post via
    /// NIP-40) and returns its Nostr event id, or nil when bridging failed or
    /// was skipped.
    private let publishToNostr: (_ content: String, _ geohash: String, _ nickname: String, _ expiresAtMs: UInt64, _ urgent: Bool) -> String?
    /// Requests NIP-09 deletion of a previously bridged note.
    private let deleteFromNostr: (_ eventID: String, _ geohash: String) -> Void
    /// Bridged Nostr event ids by postID, for merged deletes. In-memory only:
    /// after a relaunch a delete still tombstones the board copy, but the
    /// Nostr copy is left to expire with relay retention.
    private var bridgedEventIDs: [Data: String] = [:]
    private var cancellable: AnyCancellable?

    init(
        transport: Transport,
        store: BoardStore = .shared,
        publishToNostr: ((String, String, String, UInt64, Bool) -> String?)? = nil,
        deleteFromNostr: ((String, String) -> Void)? = nil
    ) {
        self.transport = transport
        self.publishToNostr = publishToNostr ?? Self.livePublishToNostr
        self.deleteFromNostr = deleteFromNostr ?? Self.liveDeleteFromNostr
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

        // Nostr bridge: geohash posts also go out as kind-1 location notes so
        // online users see them. Remember the event id for merged deletes.
        if !geohash.isEmpty, let eventID = publishToNostr(trimmed, geohash, cleanNickname, expiresAt, urgent) {
            bridgedEventIDs[postID] = eventID
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

        // Merged delete: also retract the bridged Nostr copy when we still
        // know its event id.
        if !post.geohash.isEmpty, let eventID = bridgedEventIDs.removeValue(forKey: post.postID) {
            deleteFromNostr(eventID, post.geohash)
        }
        return true
    }

    private static func livePublishToNostr(content: String, geohash: String, nickname: String, expiresAtMs: UInt64, urgent: Bool) -> String? {
        let relays = GeoRelayDirectory.shared.closestRelays(toGeohash: geohash, count: TransportConfig.nostrGeoRelayCount)
        guard !relays.isEmpty else {
            SecureLogger.debug("Board: no geo relays for \(geohash); skipping Nostr bridge", category: .session)
            return nil
        }
        do {
            let identity = try NostrIdentityBridge().deriveIdentity(forGeohash: geohash)
            let event = try NostrProtocol.createGeohashTextNote(
                content: content,
                geohash: geohash,
                senderIdentity: identity,
                nickname: nickname,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAtMs) / 1000),
                urgent: urgent
            )
            NostrRelayManager.shared.sendEvent(event, to: relays)
            return event.id
        } catch {
            SecureLogger.error("Board: failed to bridge post to Nostr: \(error)", category: .session)
            return nil
        }
    }

    private static func liveDeleteFromNostr(eventID: String, geohash: String) {
        let relays = GeoRelayDirectory.shared.closestRelays(toGeohash: geohash, count: TransportConfig.nostrGeoRelayCount)
        guard !relays.isEmpty else { return }
        do {
            let identity = try NostrIdentityBridge().deriveIdentity(forGeohash: geohash)
            let deletion = try NostrProtocol.createDeleteEvent(ofEventID: eventID, senderIdentity: identity)
            NostrRelayManager.shared.sendEvent(deletion, to: relays)
        } catch {
            SecureLogger.error("Board: failed to delete bridged Nostr note: \(error)", category: .session)
        }
    }
}
