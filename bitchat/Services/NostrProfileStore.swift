//
// NostrProfileStore.swift
// bitchat
//
// Manages:
// 1. The user's optional persistent Nostr public handle (NIP-01 kind 0),
//    disabled by default so per-place unlinkable personas remain the default.
// 2. A bounded in-memory cache of remote kind-0 profiles fetched in batched,
//    Tor-friendly REQs on the default relay set.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import Combine
import Foundation

struct NostrProfileStoreDependencies {
    typealias Subscribe = @MainActor (_ filter: NostrFilter, _ id: String, _ handler: @escaping (NostrEvent) -> Void, _ onEOSE: (() -> Void)?) -> Void
    typealias Unsubscribe = @MainActor (_ id: String) -> Void
    typealias SendEvent = @MainActor (_ event: NostrEvent) -> Void

    var subscribe: Subscribe
    var unsubscribe: Unsubscribe
    var sendEvent: SendEvent
    var currentIdentity: () throws -> NostrIdentity?
    var now: () -> Date

    static let live = NostrProfileStoreDependencies(
        subscribe: { filter, id, handler, onEOSE in
            NostrRelayManager.shared.subscribe(
                filter: filter,
                id: id,
                relayUrls: nil,
                handler: handler,
                onEOSE: onEOSE
            )
        },
        unsubscribe: { id in
            NostrRelayManager.shared.unsubscribe(id: id)
        },
        sendEvent: { event in
            NostrRelayManager.shared.sendEvent(event)
        },
        currentIdentity: {
            try NostrIdentityBridge.shared.getCurrentNostrIdentity()
        },
        now: Date.init
    )
}

@MainActor
final class NostrProfileStore: ObservableObject {
    struct OwnPublicProfile: Codable, Equatable, Sendable {
        var isEnabled: Bool = false
        var displayName: String = ""
        var about: String = ""
        var nip05: String = ""

        var metadata: NostrProtocol.ProfileMetadata {
            NostrProtocol.ProfileMetadata(
                name: displayName.trimmedOrNilIfEmpty,
                displayName: displayName.trimmedOrNilIfEmpty,
                about: about.trimmedOrNilIfEmpty,
                nip05: nip05.trimmedOrNilIfEmpty
            )
        }
    }

    struct CachedProfile: Equatable {
        let metadata: NostrProtocol.ProfileMetadata
        let createdAt: Int
    }

    static let shared = NostrProfileStore()

    private static let keychainService = "chat.bitchat.nostr.profile"
    private static let storageKey = "own-public-profile"
    private static let maxCachedProfiles = 500
    private static let fetchCooldownSeconds: TimeInterval = 10 * 60

    @Published private(set) var ownProfile: OwnPublicProfile = OwnPublicProfile()
    @Published private(set) var profiles: [String: CachedProfile] = [:]

    private let keychain: KeychainManagerProtocol
    private let dependencies: NostrProfileStoreDependencies
    private var fetchOrder: [String] = []
    private var lastRequestedAt: [String: Date] = [:]
    private var activeSubscriptionIDs: Set<String> = []

    init(
        keychain: KeychainManagerProtocol = KeychainManager.makeDefault(),
        dependencies: NostrProfileStoreDependencies = .live
    ) {
        self.keychain = keychain
        self.dependencies = dependencies
        loadOwnProfile()
    }

    deinit {
        let subs = activeSubscriptionIDs
        let unsubscribe = dependencies.unsubscribe
        if !subs.isEmpty {
            Task { @MainActor in
                for id in subs {
                    unsubscribe(id)
                }
            }
        }
    }

    // MARK: - Own Opt-In Public Handle

    var isPublicHandleEnabled: Bool {
        ownProfile.isEnabled
    }

    func ownPublicIdentity() -> NostrIdentity? {
        try? dependencies.currentIdentity()
    }

    var ownPublicPubkeyHex: String? {
        ownPublicIdentity()?.publicKeyHex.lowercased()
    }

    var ownPublicNpub: String? {
        ownPublicIdentity()?.npub
    }

    /// Saves the user's opt-in public profile locally (Keychain) and, when
    /// enabled, signs and publishes a NIP-01 kind-0 event to default relays.
    @discardableResult
    func saveAndPublishOwnProfile(_ updated: OwnPublicProfile) -> Bool {
        ownProfile = updated
        saveOwnProfile()

        guard updated.isEnabled else {
            return true
        }
        guard let identity = ownPublicIdentity() else {
            return false
        }
        do {
            let now = dependencies.now()
            let event = try NostrProtocol.createMetadataEvent(
                profile: updated.metadata,
                senderIdentity: identity,
                createdAt: now
            )
            dependencies.sendEvent(event)
            ingestMetadataEvent(event)
            return true
        } catch {
            SecureLogger.error("NostrProfileStore: failed to publish kind-0 metadata: \(error)", category: .session)
            return false
        }
    }

    func disablePublicHandle() {
        var updated = ownProfile
        updated.isEnabled = false
        ownProfile = updated
        saveOwnProfile()
    }

    // MARK: - Remote Profile Lookup & Cache

    func profile(for pubkeyHex: String) -> NostrProtocol.ProfileMetadata? {
        profiles[pubkeyHex.lowercased()]?.metadata
    }

    func displayName(for pubkeyHex: String, fallbackNickname: String?) -> String {
        if let preferred = profile(for: pubkeyHex)?.preferredName {
            return preferred
        }
        return fallbackNickname?.trimmedOrNilIfEmpty ?? "anon"
    }

    /// Batches missing pubkeys into a single short-lived kind-0 REQ on default
    /// relays and auto-closes on EOSE to keep Tor relay usage minimal.
    func ensureProfiles(for pubkeys: [String]) {
        let now = dependencies.now()
        var toFetch: [String] = []
        var seen = Set<String>()

        for raw in pubkeys {
            guard let hex = NostrProtocol.normalizePubkeyHex(raw),
                  seen.insert(hex).inserted else {
                continue
            }
            if let last = lastRequestedAt[hex],
               now.timeIntervalSince(last) < Self.fetchCooldownSeconds {
                continue
            }
            lastRequestedAt[hex] = now
            toFetch.append(hex)
            if toFetch.count >= 64 { break }
        }
        guard !toFetch.isEmpty else { return }

        let subID = "profiles-\(UUID().uuidString.prefix(8))"
        activeSubscriptionIDs.insert(subID)
        let filter = NostrFilter.authorProfiles(toFetch)
        dependencies.subscribe(filter, subID, { [weak self] event in
            self?.ingestMetadataEvent(event)
        }, { [weak self] in
            guard let self else { return }
            self.activeSubscriptionIDs.remove(subID)
            self.dependencies.unsubscribe(subID)
        })
    }

    func ingestMetadataEvent(_ event: NostrEvent) {
        guard let metadata = NostrProtocol.parseMetadataEvent(event) else { return }
        let pubkey = event.pubkey.lowercased()
        if let existing = profiles[pubkey], existing.createdAt > event.created_at {
            return
        }
        profiles[pubkey] = CachedProfile(metadata: metadata, createdAt: event.created_at)
        if !fetchOrder.contains(pubkey) {
            fetchOrder.append(pubkey)
            if fetchOrder.count > Self.maxCachedProfiles {
                let evicted = fetchOrder.removeFirst()
                profiles.removeValue(forKey: evicted)
            }
        }
    }

    /// Panic-wipe hook: close active profile REQs, clear cached profiles, and
    /// delete the opt-in public profile from Keychain.
    func resetForPanic() {
        for subID in activeSubscriptionIDs {
            dependencies.unsubscribe(subID)
        }
        activeSubscriptionIDs.removeAll(keepingCapacity: false)
        profiles.removeAll(keepingCapacity: false)
        fetchOrder.removeAll(keepingCapacity: false)
        lastRequestedAt.removeAll(keepingCapacity: false)
        ownProfile = OwnPublicProfile()
        keychain.delete(key: Self.storageKey, service: Self.keychainService)
    }

    // MARK: - Persistence

    private func loadOwnProfile() {
        guard let data = keychain.load(key: Self.storageKey, service: Self.keychainService) else {
            return
        }
        if let decoded = try? JSONDecoder().decode(OwnPublicProfile.self, from: data) {
            ownProfile = decoded
        }
    }

    private func saveOwnProfile() {
        do {
            let data = try JSONEncoder().encode(ownProfile)
            keychain.save(
                key: Self.storageKey,
                data: data,
                service: Self.keychainService,
                accessible: nil
            )
        } catch {
            SecureLogger.error("NostrProfileStore: failed to save own profile: \(error)", category: .session)
        }
    }
}
