//
// StickerInstallStore.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

/// Local + relay-synced list of installed Sonar sticker packs (Nostr kind
/// 10031, `a` tags of `30031:<author>:<d>` coordinates).
///
/// The ordered list is persisted locally as JSON under
/// `Application Support/files/stickers/` so panic wipe covers it. Relay
/// publishing is strictly opt-in: `syncEnabled` defaults to false and
/// `publishInstalledList()` refuses to run while it is false — nothing about
/// the installed list leaves the device until the user turns sync on.
///
/// Local mutations always succeed locally; a publish failure is logged, never
/// rolled back.
actor StickerInstallStore {
    enum StickerInstallError: Swift.Error, Equatable {
        /// `publishInstalledList()` was called while `syncEnabled` is false.
        case syncDisabled
        case identityUnavailable
        case invalidCoordinate
    }

    static let listEventKind = 10031
    static let syncEnabledDefaultsKey = "stickerInstallStore.syncEnabled"

    /// App-wide shared instance (state is on disk + UserDefaults, but one
    /// actor keeps in-memory `installed` coherent across views).
    static let shared = StickerInstallStore()

    typealias RelayQuery = @Sendable (NostrFilter) async -> [NostrEvent]
    typealias EventPublisher = @Sendable (NostrEvent) async throws -> Void
    typealias IdentityProvider = @Sendable () throws -> NostrIdentity

    private let storageURL: URL
    private let defaults: UserDefaults
    private let identityProvider: IdentityProvider
    private let relayQuery: RelayQuery
    private let publisher: EventPublisher
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    /// Ordered installed pack coordinates, deduplicated in first-seen order.
    /// No default value: assigned exactly once in init (Swift 6 init isolation).
    private(set) var installed: [String]

    /// Opt-in gate for kind-10031 list sync. Default false.
    var syncEnabled: Bool {
        get { defaults.object(forKey: Self.syncEnabledDefaultsKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Self.syncEnabledDefaultsKey) }
    }

    init(
        baseDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        identityProvider: @escaping IdentityProvider = {
            guard let identity = try NostrIdentityBridge().getCurrentNostrIdentity() else {
                throw StickerInstallError.identityUnavailable
            }
            return identity
        },
        relayQuery: @escaping RelayQuery = { filter in
            await StickerRelayQuery.oneShot(filter: filter)
        },
        publisher: @escaping EventPublisher = { event in
            // nil relay set = built-in default relays (never geo relays). The
            // manager's own fail-closed queueing applies while Tor bootstraps.
            await MainActor.run { NostrRelayManager.shared.sendEvent(event) }
        },
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let dir = (try? StickerStoragePaths.stickersDirectory(base: baseDirectory, fileManager: fileManager))
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("bitchat-stickers-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("installed-packs.json", isDirectory: false)
        self.defaults = defaults
        self.identityProvider = identityProvider
        self.relayQuery = relayQuery
        self.publisher = publisher
        self.fileManager = fileManager
        self.now = now
        // Loaded inline: actor inits are nonisolated, so isolated helper calls
        // from here are an error in Swift 6 mode.
        var initial: [String] = []
        if let data = try? Data(contentsOf: self.storageURL),
           let coordinates = try? JSONDecoder().decode([String].self, from: data) {
            initial = Self.dedupePreservingOrder(
                coordinates.filter { StickerRef.isValidCoordinate($0) }
            )
        }
        self.installed = initial
    }

    // MARK: - Local mutations

    /// Appends a coordinate (first-seen order, no duplicates), persists, and
    /// publishes the updated list only when `syncEnabled` is true.
    func install(_ coordinate: String) async throws {
        guard StickerRef.isValidCoordinate(coordinate) else {
            throw StickerInstallError.invalidCoordinate
        }
        guard !installed.contains(coordinate) else { return }
        installed.append(coordinate)
        persist()
        await publishIfSyncEnabled()
    }

    func uninstall(_ coordinate: String) async {
        guard installed.contains(coordinate) else { return }
        installed.removeAll { $0 == coordinate }
        persist()
        await publishIfSyncEnabled()
    }

    func installedPacks() -> [String] { installed }

    // MARK: - Relay sync (kind 10031)

    /// Fetches the canonical identity's latest kind-10031 event from the
    /// default relay set and returns its `a`-tag coordinates (validated,
    /// deduplicated in first-seen order). Empty when no event exists.
    func fetchInstalledList() async throws -> [String] {
        let identity = try identityProvider()
        var filter = NostrFilter()
        filter.kinds = [Self.listEventKind]
        filter.authors = [identity.publicKeyHex]
        filter.limit = 5
        let events = await relayQuery(filter)
        guard let latest = events
            .filter({ $0.kind == Self.listEventKind && $0.pubkey == identity.publicKeyHex })
            .max(by: { $0.created_at < $1.created_at })
        else { return [] }
        let coordinates = latest.tags.compactMap { tag -> String? in
            guard tag.count >= 2, tag[0] == "a",
                  StickerRef.isValidCoordinate(tag[1])
            else { return nil }
            return tag[1]
        }
        return Self.dedupePreservingOrder(coordinates)
    }

    /// Union of local and relay state, preserving first-seen order (local
    /// entries first). Call on launch when sync is enabled.
    func mergeInstalledFromNetwork() async throws {
        let remote = try await fetchInstalledList()
        installed = Self.dedupePreservingOrder(installed + remote)
        persist()
    }

    /// Publishes the local list as a signed kind-10031 event (empty content,
    /// `a` tags) to the default relay set. REFUSES while `syncEnabled` is
    /// false — the caller must gate this on the explicit opt-in setting.
    func publishInstalledList() async throws {
        guard syncEnabled else { throw StickerInstallError.syncDisabled }
        let identity = try identityProvider()
        let unsigned = try NostrEvent(from: [
            "pubkey": identity.publicKeyHex,
            "created_at": Int(now().timeIntervalSince1970),
            "kind": Self.listEventKind,
            "tags": installed.map { ["a", $0] },
            "content": ""
        ])
        let signed = try unsigned.sign(with: identity.schnorrSigningKey())
        try await publisher(signed)
    }

    // MARK: - Internals

    private func publishIfSyncEnabled() async {
        guard syncEnabled else { return }
        do {
            try await publishInstalledList()
        } catch {
            SecureLogger.error(
                "⚠️ Failed to publish sticker install list: \(error.localizedDescription)",
                category: .session
            )
        }
    }

    static func dedupePreservingOrder(_ coordinates: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for coordinate in coordinates where seen.insert(coordinate).inserted {
            result.append(coordinate)
        }
        return result
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(installed) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
