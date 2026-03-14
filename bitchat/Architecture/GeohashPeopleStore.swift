import Combine
import Foundation
import SwiftUI

@MainActor
final class GeohashPeopleStore: ObservableObject, GeohashPeopleStoreProtocol {
    @Published private(set) var currentGeohash: String?
    @Published private(set) var geoNicknames: [String: String]
    @Published private(set) var nostrKeyMapping: [PeerID: String]

    private let sessionStore: SessionStore
    private let participantStore: GeohashParticipantTracker
    private let privateConversationsStore: PrivateConversationsStore
    private let timelineStore: PublicTimelineStore
    private let identityManager: SecureIdentityStateManagerProtocol
    private let idBridge: NostrIdentityBridge
    private let nostrPalette = MinimalDistancePalette(config: .nostr)

    private var startPrivateChatAction: ((PeerID) -> Void)?
    private var addSystemMessageAction: ((String) -> Void)?
    private var cancellables = Set<AnyCancellable>()

    init(
        sessionStore: SessionStore,
        participantStore: GeohashParticipantTracker,
        privateConversationsStore: PrivateConversationsStore,
        timelineStore: PublicTimelineStore,
        identityManager: SecureIdentityStateManagerProtocol,
        idBridge: NostrIdentityBridge,
        initialCurrentGeohash: String? = nil,
        initialGeoNicknames: [String: String] = [:],
        initialNostrKeyMapping: [PeerID: String] = [:]
    ) {
        self.currentGeohash = initialCurrentGeohash
        self.geoNicknames = initialGeoNicknames
        self.nostrKeyMapping = initialNostrKeyMapping
        self.sessionStore = sessionStore
        self.participantStore = participantStore
        self.privateConversationsStore = privateConversationsStore
        self.timelineStore = timelineStore
        self.identityManager = identityManager
        self.idBridge = idBridge

        participantStore.configure(context: self)

        sessionStore.$nickname
            .sink { [weak self] _ in
                self?.participantStore.refresh()
            }
            .store(in: &cancellables)
    }

    var geoNicknamesSnapshot: [String: String] { geoNicknames }
    var nostrKeyMappingSnapshot: [PeerID: String] { nostrKeyMapping }

    func configureActions(
        startPrivateChat: @escaping (PeerID) -> Void,
        addSystemMessage: @escaping (String) -> Void
    ) {
        startPrivateChatAction = startPrivateChat
        addSystemMessageAction = addSystemMessage
    }

    func setCurrentGeohash(_ geohash: String?) {
        guard currentGeohash != geohash else { return }
        currentGeohash = geohash
        participantStore.refresh()
    }

    func replaceGeoNicknames(_ nicknames: [String: String]) {
        guard geoNicknames != nicknames else { return }
        geoNicknames = nicknames
        participantStore.refresh()
    }

    func clearNicknames() {
        replaceGeoNicknames([:])
    }

    func replaceNostrKeyMapping(_ mappings: [PeerID: String]) {
        guard nostrKeyMapping != mappings else { return }
        nostrKeyMapping = mappings
    }

    func registerNickname(_ nickname: String, for pubkeyHex: String) {
        let normalized = pubkeyHex.lowercased()
        guard geoNicknames[normalized] != nickname else { return }
        var updated = geoNicknames
        updated[normalized] = nickname
        replaceGeoNicknames(updated)
    }

    func registerPubkey(_ pubkeyHex: String, for peerID: PeerID) {
        let normalized = pubkeyHex.lowercased()
        guard nostrKeyMapping[peerID] != normalized else { return }
        var updated = nostrKeyMapping
        updated[peerID] = normalized
        replaceNostrKeyMapping(updated)
    }

    func removeMappings(for pubkeyHexLowercased: String) {
        let normalized = pubkeyHexLowercased.lowercased()
        var updated = nostrKeyMapping
        updated = updated.filter { $0.value.lowercased() != normalized }
        replaceNostrKeyMapping(updated)
    }

    func commandParticipants() -> [CommandGeoParticipant] {
        participantStore.getVisiblePeople().map {
            CommandGeoParticipant(id: $0.id, displayName: $0.displayName)
        }
    }

    func peerID(for nickname: String) -> PeerID? {
        guard currentGeohash != nil else { return nil }

        if nickname.contains("#"),
           let person = participantStore.getVisiblePeople().first(where: { $0.displayName == nickname }) {
            let conversationPeerID = PeerID(nostr_: person.id)
            registerPubkey(person.id, for: conversationPeerID)
            return conversationPeerID
        }

        let baseName = normalizedBaseNickname(from: nickname)
        guard let pubkey = geoNicknames.first(where: { $0.value.lowercased() == baseName })?.key else {
            return nil
        }

        let conversationPeerID = PeerID(nostr_: pubkey)
        registerPubkey(pubkey, for: conversationPeerID)
        return conversationPeerID
    }

    func autocompleteTokens(excludingSelfNickname nickname: String) -> [String] {
        var tokens = Set<String>()
        for (pubkey, cachedNickname) in geoNicknames where !cachedNickname.isEmpty {
            tokens.insert("\(cachedNickname)#\(pubkey.suffix(4))")
        }
        if let myHex = currentIdentityHex() {
            tokens.remove("\(nickname)#\(myHex.suffix(4))")
        }
        return Array(tokens)
    }

    func nostrPubkey(forDisplayName displayName: String) -> String? {
        for person in participantStore.getVisiblePeople() where person.displayName == displayName {
            return person.id
        }
        for (pubkey, nickname) in geoNicknames where nickname == displayName {
            return pubkey
        }
        return nil
    }

    func fullNostrHex(for senderPeerID: PeerID) -> String? {
        nostrKeyMapping[senderPeerID]
    }

    func geohashDisplayName(for conversationPeerID: PeerID) -> String {
        guard let fullPubkey = nostrKeyMapping[conversationPeerID] else {
            return conversationPeerID.bare
        }
        return displayNameForPubkey(fullPubkey)
    }

    func currentIdentityHex() -> String? {
        if let currentGeohash,
           let identity = try? idBridge.deriveIdentity(forGeohash: currentGeohash) {
            return identity.publicKeyHex.lowercased()
        }
        return nil
    }

    func displayNameForPubkey(_ pubkeyHex: String) -> String {
        let normalized = pubkeyHex.lowercased()
        let suffix = String(normalized.suffix(4))

        if currentIdentityHex() == normalized {
            return sessionStore.nickname + "#" + suffix
        }
        if let nickname = geoNicknames[normalized], !nickname.isEmpty {
            return nickname + "#" + suffix
        }
        return "anon#\(suffix)"
    }

    func isBlocked(_ pubkeyHexLowercased: String) -> Bool {
        identityManager.isNostrBlocked(pubkeyHexLowercased: pubkeyHexLowercased.lowercased())
    }

    func color(for pubkeyHexLowercased: String, isDark: Bool) -> Color {
        let normalized = pubkeyHexLowercased.lowercased()
        let myHex = currentIdentityHex()

        if normalized == myHex {
            return .orange
        }

        nostrPalette.ensurePalette(for: currentPaletteSeeds(excluding: myHex))
        if let color = nostrPalette.color(for: normalized, isDark: isDark) {
            return color
        }
        return Color(peerSeed: "nostr:" + normalized, isDark: isDark)
    }

    func startDirectMessage(withPubkeyHex hex: String) {
        let normalized = hex.lowercased()
        let conversationPeerID = PeerID(nostr_: normalized)
        registerPubkey(normalized, for: conversationPeerID)
        if let startPrivateChatAction {
            startPrivateChatAction(conversationPeerID)
        } else {
            privateConversationsStore.startChat(with: conversationPeerID)
        }
    }

    func block(pubkeyHexLowercased: String, displayName: String) {
        let normalized = pubkeyHexLowercased.lowercased()
        identityManager.setNostrBlocked(normalized, isBlocked: true)
        participantStore.removeParticipant(pubkeyHex: normalized)

        if let currentGeohash {
            let predicate: (BitchatMessage) -> Bool = { message in
                guard let senderPeerID = message.senderPeerID, senderPeerID.isGeoDM || senderPeerID.isGeoChat else {
                    return false
                }
                return self.nostrKeyMapping[senderPeerID]?.lowercased() == normalized
            }
            timelineStore.removeMessages(in: currentGeohash, where: predicate)
        }

        let conversationPeerID = PeerID(nostr_: normalized)
        if privateConversationsStore.hasMessages(for: conversationPeerID) {
            privateConversationsStore.removeConversation(for: conversationPeerID)
            privateConversationsStore.clearUnread(for: conversationPeerID)
        }

        removeMappings(for: normalized)

        addSystemMessageAction?(
            String(
                format: String(localized: "system.geohash.blocked", comment: "System message shown when a user is blocked in geohash chats"),
                locale: .current,
                displayName
            )
        )
    }

    func unblock(pubkeyHexLowercased: String, displayName: String) {
        let normalized = pubkeyHexLowercased.lowercased()
        identityManager.setNostrBlocked(normalized, isBlocked: false)
        participantStore.refresh()

        addSystemMessageAction?(
            String(
                format: String(localized: "system.geohash.unblocked", comment: "System message shown when a user is unblocked in geohash chats"),
                locale: .current,
                displayName
            )
        )
    }
}

private extension GeohashPeopleStore {
    func normalizedBaseNickname(from nickname: String) -> String {
        if let hashIndex = nickname.firstIndex(of: "#") {
            return String(nickname[..<hashIndex]).lowercased()
        }
        return nickname.lowercased()
    }

    func currentPaletteSeeds(excluding myHex: String?) -> [String: String] {
        let excluded = myHex ?? ""
        return participantStore.visiblePeople.reduce(into: [:]) { seeds, person in
            guard person.id != excluded else { return }
            seeds[person.id] = "nostr:" + person.id
        }
    }
}
