//
// NostrFollowsStore.swift
// bitchat
//
// Private, local-only follow list stored in Keychain (never published as a
// public kind-3 graph) merged with Nostr pubkeys already exchanged with
// favorite peers via FavoritesPersistenceService.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import Combine
import Foundation

@MainActor
final class NostrFollowsStore: ObservableObject {
    struct FollowedAuthor: Codable, Equatable, Identifiable {
        let pubkeyHex: String
        var alias: String?
        let followedAt: Date

        var id: String { pubkeyHex }

        var npub: String? {
            guard let data = Data(hexString: pubkeyHex), data.count == 32 else { return nil }
            return try? Bech32.encode(hrp: "npub", data: data)
        }
    }

    static let shared = NostrFollowsStore()
    static let maxExplicitFollows = 250

    private static let keychainService = "chat.bitchat.nostr.follows"
    private static let storageKey = "followed-authors"

    @Published private(set) var explicitFollows: [FollowedAuthor] = []
    @Published private(set) var favoriteFollowPubkeys: Set<String> = []
    @Published private(set) var allFollowedPubkeys: [String] = []

    private let keychain: KeychainManagerProtocol
    private let favoritesProvider: () -> [FavoritesPersistenceService.FavoriteRelationship]
    private var favoritesCancellable: AnyCancellable?

    init(
        keychain: KeychainManagerProtocol = KeychainManager.makeDefault(),
        favoritesService: FavoritesPersistenceService? = nil,
        favoritesProvider: (() -> [FavoritesPersistenceService.FavoriteRelationship])? = nil
    ) {
        self.keychain = keychain
        if let favoritesProvider {
            self.favoritesProvider = favoritesProvider
        } else {
            let service = favoritesService ?? .shared
            self.favoritesProvider = { Array(service.favorites.values) }
            self.favoritesCancellable = service.$favorites
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refreshMergedFollows()
                }
        }
        loadExplicitFollows()
        refreshMergedFollows()
    }

    /// Follow a Nostr author by 64-char hex pubkey or `npub1...`.
    @discardableResult
    func follow(_ pubkeyOrNpub: String, alias: String? = nil) -> Bool {
        guard let hex = NostrProtocol.normalizePubkeyHex(pubkeyOrNpub) else {
            return false
        }
        let cleanAlias = alias?.trimmedOrNilIfEmpty
        if let index = explicitFollows.firstIndex(where: { $0.pubkeyHex == hex }) {
            if let cleanAlias, explicitFollows[index].alias != cleanAlias {
                explicitFollows[index].alias = cleanAlias
                saveExplicitFollows()
            }
            return true
        }
        guard explicitFollows.count < Self.maxExplicitFollows else {
            return false
        }
        explicitFollows.insert(
            FollowedAuthor(pubkeyHex: hex, alias: cleanAlias, followedAt: Date()),
            at: 0
        )
        saveExplicitFollows()
        refreshMergedFollows()
        return true
    }

    /// Remove an explicitly followed pubkey.
    func unfollow(_ pubkeyHex: String) {
        let normalized = NostrProtocol.normalizePubkeyHex(pubkeyHex) ?? pubkeyHex.lowercased()
        let before = explicitFollows.count
        explicitFollows.removeAll { $0.pubkeyHex == normalized }
        guard explicitFollows.count != before else { return }
        saveExplicitFollows()
        refreshMergedFollows()
    }

    @discardableResult
    func toggleFollow(_ pubkeyHex: String, alias: String? = nil) -> Bool {
        let normalized = NostrProtocol.normalizePubkeyHex(pubkeyHex) ?? pubkeyHex.lowercased()
        if isExplicitlyFollowing(normalized) {
            unfollow(normalized)
            return false
        }
        return follow(normalized, alias: alias)
    }

    func isExplicitlyFollowing(_ pubkeyHex: String) -> Bool {
        let normalized = pubkeyHex.lowercased()
        return explicitFollows.contains { $0.pubkeyHex == normalized }
    }

    /// True if followed explicitly OR via a favorited peer's exchanged Nostr pubkey.
    func isFollowing(_ pubkeyHex: String) -> Bool {
        let normalized = pubkeyHex.lowercased()
        return isExplicitlyFollowing(normalized) || favoriteFollowPubkeys.contains(normalized)
    }

    func localAlias(for pubkeyHex: String) -> String? {
        let normalized = pubkeyHex.lowercased()
        if let explicit = explicitFollows.first(where: { $0.pubkeyHex == normalized })?.alias?.trimmedOrNilIfEmpty {
            return explicit
        }
        for rel in favoritesProvider() where rel.isFavorite {
            if let raw = rel.peerNostrPublicKey,
               NostrProtocol.normalizePubkeyHex(raw) == normalized,
               let nick = rel.peerNickname.trimmedOrNilIfEmpty,
               nick != "Unknown" {
                return nick
            }
        }
        return nil
    }

    func refreshMergedFollows() {
        var favSet = Set<String>()
        for rel in favoritesProvider() where rel.isFavorite {
            if let raw = rel.peerNostrPublicKey,
               let hex = NostrProtocol.normalizePubkeyHex(raw) {
                favSet.insert(hex)
            }
        }
        favoriteFollowPubkeys = favSet

        var seen = Set<String>()
        var merged: [String] = []
        for entry in explicitFollows {
            if seen.insert(entry.pubkeyHex).inserted {
                merged.append(entry.pubkeyHex)
            }
        }
        for fav in favSet.sorted() {
            if seen.insert(fav).inserted {
                merged.append(fav)
            }
        }
        if merged.count > Self.maxExplicitFollows {
            merged = Array(merged.prefix(Self.maxExplicitFollows))
        }
        allFollowedPubkeys = merged
    }

    /// Panic-wipe hook: erase all explicitly followed pubkeys from memory and Keychain.
    func resetForPanic() {
        explicitFollows.removeAll(keepingCapacity: false)
        favoriteFollowPubkeys.removeAll(keepingCapacity: false)
        allFollowedPubkeys.removeAll(keepingCapacity: false)
        keychain.delete(key: Self.storageKey, service: Self.keychainService)
    }

    // MARK: - Persistence

    private func loadExplicitFollows() {
        guard let data = keychain.load(key: Self.storageKey, service: Self.keychainService) else {
            return
        }
        do {
            let decoded = try JSONDecoder().decode([FollowedAuthor].self, from: data)
            var seen = Set<String>()
            explicitFollows = decoded.compactMap { entry in
                guard let hex = NostrProtocol.normalizePubkeyHex(entry.pubkeyHex),
                      seen.insert(hex).inserted else {
                    return nil
                }
                return FollowedAuthor(
                    pubkeyHex: hex,
                    alias: entry.alias?.trimmedOrNilIfEmpty,
                    followedAt: entry.followedAt
                )
            }
        } catch {
            SecureLogger.error("NostrFollowsStore: failed to decode follows: \(error)", category: .session)
        }
    }

    private func saveExplicitFollows() {
        do {
            let data = try JSONEncoder().encode(explicitFollows)
            keychain.save(
                key: Self.storageKey,
                data: data,
                service: Self.keychainService,
                accessible: nil
            )
        } catch {
            SecureLogger.error("NostrFollowsStore: failed to encode follows: \(error)", category: .session)
        }
    }
}
