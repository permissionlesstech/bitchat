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
#if os(iOS)
import UIKit
#endif

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
    #if os(iOS)
    private var unlockObserver: NSObjectProtocol?
    #endif
    /// True when the initial keychain read failed due to a transient error
    /// (e.g. locked boot) rather than `.itemNotFound`. While true, writes are
    /// deferred and replayed once the Keychain becomes readable so existing
    /// follows are never clobbered.
    private var loadUnavailable = false
    private var pendingFollows: [String: FollowedAuthor] = [:]
    private var pendingUnfollows: Set<String> = []

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
        #if os(iOS)
        unlockObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.retryDeferredLoad()
            }
        }
        #endif
    }

    #if os(iOS)
    deinit {
        if let unlockObserver {
            NotificationCenter.default.removeObserver(unlockObserver)
        }
    }
    #endif

    /// Re-attempts reading the Keychain follow list after a locked-boot failure
    /// and replays any queued follow/unfollow mutations without clobbering.
    func retryDeferredLoad() {
        guard loadUnavailable else { return }
        loadExplicitFollows()
        guard !loadUnavailable else { return }

        var mutated = false
        if !pendingUnfollows.isEmpty {
            let unfollows = pendingUnfollows
            pendingUnfollows.removeAll(keepingCapacity: false)
            let before = explicitFollows.count
            explicitFollows.removeAll { unfollows.contains($0.pubkeyHex) }
            if explicitFollows.count != before { mutated = true }
        }
        if !pendingFollows.isEmpty {
            let queued = pendingFollows.values.sorted { $0.followedAt < $1.followedAt }
            pendingFollows.removeAll(keepingCapacity: false)
            for entry in queued {
                if let index = explicitFollows.firstIndex(where: { $0.pubkeyHex == entry.pubkeyHex }) {
                    if let alias = entry.alias, explicitFollows[index].alias != alias {
                        explicitFollows[index].alias = alias
                        mutated = true
                    }
                } else if explicitFollows.count < Self.maxExplicitFollows {
                    explicitFollows.insert(entry, at: 0)
                    mutated = true
                }
            }
        }
        if mutated {
            saveExplicitFollows()
        }
        refreshMergedFollows()
    }

    /// Follow a Nostr author by 64-char hex pubkey or `npub1...`.
    @discardableResult
    func follow(_ pubkeyOrNpub: String, alias: String? = nil) -> Bool {
        if loadUnavailable {
            retryDeferredLoad()
        }
        guard let hex = NostrProtocol.normalizePubkeyHex(pubkeyOrNpub) else {
            return false
        }
        let cleanAlias = alias?.trimmedOrNilIfEmpty
        if let index = explicitFollows.firstIndex(where: { $0.pubkeyHex == hex }) {
            if let cleanAlias, explicitFollows[index].alias != cleanAlias {
                explicitFollows[index].alias = cleanAlias
                if loadUnavailable {
                    pendingFollows[hex] = explicitFollows[index]
                    pendingUnfollows.remove(hex)
                } else {
                    saveExplicitFollows()
                }
            }
            return true
        }
        guard explicitFollows.count < Self.maxExplicitFollows else {
            return false
        }
        let entry = FollowedAuthor(pubkeyHex: hex, alias: cleanAlias, followedAt: Date())
        explicitFollows.insert(entry, at: 0)
        if loadUnavailable {
            pendingFollows[hex] = entry
            pendingUnfollows.remove(hex)
        } else {
            saveExplicitFollows()
        }
        refreshMergedFollows()
        return true
    }

    /// Remove an explicitly followed pubkey.
    func unfollow(_ pubkeyHex: String) {
        if loadUnavailable {
            retryDeferredLoad()
        }
        let normalized = NostrProtocol.normalizePubkeyHex(pubkeyHex) ?? pubkeyHex.lowercased()
        let before = explicitFollows.count
        explicitFollows.removeAll { $0.pubkeyHex == normalized }
        if loadUnavailable {
            pendingFollows.removeValue(forKey: normalized)
            pendingUnfollows.insert(normalized)
            refreshMergedFollows()
            return
        }
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
        loadUnavailable = false
        pendingFollows.removeAll(keepingCapacity: false)
        pendingUnfollows.removeAll(keepingCapacity: false)
        explicitFollows.removeAll(keepingCapacity: false)
        favoriteFollowPubkeys.removeAll(keepingCapacity: false)
        allFollowedPubkeys.removeAll(keepingCapacity: false)
        keychain.delete(key: Self.storageKey, service: Self.keychainService)
    }

    // MARK: - Persistence

    private func loadExplicitFollows() {
        let data: Data
        switch keychain.loadWithResult(key: Self.storageKey, service: Self.keychainService) {
        case .success(let loadedData):
            loadUnavailable = false
            data = loadedData
        case .itemNotFound:
            loadUnavailable = false
            return
        case .deviceLocked, .authenticationFailed, .accessDenied, .otherError:
            loadUnavailable = true
            SecureLogger.warning("NostrFollowsStore: keychain read unavailable at launch; deferring writes to prevent overwrite", category: .security)
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
        guard !loadUnavailable else {
            SecureLogger.warning("NostrFollowsStore: skipping keychain save while initial load is unavailable", category: .security)
            return
        }
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
