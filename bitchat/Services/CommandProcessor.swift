//
// CommandProcessor.swift
// bitchat
//
// Handles command parsing and execution for BitChat
// This is free and unencumbered software released into the public domain.
//

import Foundation
import BitFoundation

/// Result of command processing
enum CommandResult {
    case success(message: String?)
    case error(message: String)
    case handled  // Command handled, no message needed
}

/// Simple struct for geo participant info used by CommandProcessor
struct CommandGeoParticipant {
    let id: String        // pubkey hex (lowercased)
    let displayName: String
}

/// The conversation a command was typed into, captured when the command is
/// issued so deferred output (e.g. an async /ping result, which can arrive
/// many seconds later) lands there even if the user switches chats first.
enum CommandOutputDestination: Equatable {
    /// The #mesh public timeline. Commands that defer output (/ping) are
    /// mesh-only, so a non-DM origin is always the mesh timeline.
    case meshTimeline
    /// The private chat that was open when the command was typed.
    case privateChat(PeerID)
}

/// Protocol defining what CommandProcessor needs from its context.
/// This breaks the circular dependency between CommandProcessor and ChatViewModel.
@MainActor
protocol CommandContextProvider: AnyObject {
    // MARK: - State Properties
    var nickname: String { get }
    var activeChannel: ChannelID { get }
    var selectedPrivateChatPeer: PeerID? { get }
    var blockedUsers: Set<String> { get }
    var idBridge: NostrIdentityBridge { get }

    // MARK: - Peer Lookup
    func getPeerIDForNickname(_ nickname: String) -> PeerID?
    func getVisibleGeoParticipants() -> [CommandGeoParticipant]
    func nostrPubkeyForDisplayName(_ displayName: String) -> String?

    // MARK: - Chat Actions
    func startPrivateChat(with peerID: PeerID)
    func sendPrivateMessage(_ content: String, to peerID: PeerID)
    func clearCurrentPublicTimeline()
    /// Empties the peer's chat (single-writer store intent for `/clear`).
    func clearPrivateChat(_ peerID: PeerID)
    func sendPublicRaw(_ content: String)
    /// Sends a normal public message (with local echo) to the active channel.
    func sendPublicMessage(_ content: String)

    // MARK: - System Messages
    func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID)
    func addPublicSystemMessage(_ content: String)
    /// The conversation the user is typing into right now. Commands that
    /// finish asynchronously capture this BEFORE starting async work, so a
    /// chat switch cannot misroute their deferred output.
    func currentCommandDestination() -> CommandOutputDestination
    /// Routes deferred command output (e.g. an async /ping result) into the
    /// conversation captured when the command was issued.
    func addCommandOutput(_ content: String, to destination: CommandOutputDestination)

    // MARK: - Favorites
    /// Toggles the favorite via the unified peer flow, which persists by the
    /// real noise key and notifies the peer over mesh or Nostr.
    func toggleFavorite(peerID: PeerID)

    // MARK: - Groups
    // Group logic lives in `ChatGroupCoordinator`; these forward the parsed
    // /group subcommands.
    func groupCreate(named name: String) -> CommandResult
    func groupInvite(nickname: String) -> CommandResult
    func groupRemove(nickname: String) -> CommandResult
    func groupLeave() -> CommandResult
    func groupList() -> CommandResult
}

/// Processes chat commands in a focused, efficient way
@MainActor
final class CommandProcessor {
    weak var contextProvider: CommandContextProvider?
    weak var meshService: Transport?
    private let identityManager: SecureIdentityStateManagerProtocol

    init(contextProvider: CommandContextProvider? = nil, meshService: Transport? = nil, identityManager: SecureIdentityStateManagerProtocol) {
        self.contextProvider = contextProvider
        self.meshService = meshService
        self.identityManager = identityManager
    }
    
    /// Process a command string
    @MainActor
    func process(_ command: String) -> CommandResult {
        let parts = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let cmd = parts.first else { return .error(message: "Invalid command") }
        let args = parts.count > 1 ? String(parts[1]) : ""
        
        // Geohash context: disable favoriting in public geohash or GeoDM
        let inGeoPublic: Bool = {
            switch contextProvider?.activeChannel ?? .mesh {
            case .mesh: return false
            case .location: return true
            }
        }()
        let inGeoDM = contextProvider?.selectedPrivateChatPeer?.isGeoDM == true

        switch cmd {
        case "/m", "/msg":
            return handleMessage(args)
        case "/w", "/who":
            return handleWho()
        case "/clear":
            return handleClear()
        case "/hug":
            return handleEmote(args, command: "hug", action: "hugs", emoji: "🫂")
        case "/slap":
            return handleEmote(args, command: "slap", action: "slaps", emoji: "🐟", suffix: " around a bit with a large trout")
        case "/block":
            return handleBlock(args)
        case "/unblock":
            return handleUnblock(args)
        case "/group":
            if inGeoPublic || inGeoDM { return .error(message: "groups are only for mesh peers in #mesh") }
            return handleGroup(args)
        case "/fav":
            if inGeoPublic || inGeoDM { return .error(message: "favorites are only for mesh peers in #mesh") }
            return handleFavorite(args, add: true)
        case "/unfav":
            if inGeoPublic || inGeoDM { return .error(message: "favorites are only for mesh peers in #mesh") }
            return handleFavorite(args, add: false)
        case "/ping":
            if inGeoPublic || inGeoDM { return .error(message: "ping only works for mesh peers in #mesh") }
            return handlePing(args)
        case "/trace":
            if inGeoPublic || inGeoDM { return .error(message: "trace only works for mesh peers in #mesh") }
            return handleTrace(args)
        case "/pay":
            return handlePay(args)
        case "/drop":
            return handleDrop(args)
        case "/help":
            return .success(message: Self.helpText)
        default:
            return .error(message: "unknown command: \(cmd) — type /help for commands")
        }
    }

    /// Local-only command reference, printed as a system message. The
    /// suggestion panel hides once arguments are typed, and typos used to
    /// dead-end in a bare "unknown command" — this is the way out.
    static let helpText = """
    commands:
    /msg @name [message] — start a private chat
    /who — list who's here
    /clear — clear this chat
    /hug @name — send a hug
    /slap @name — slap with a large trout
    /block @name · /unblock @name
    /fav @name · /unfav @name — favorites (mesh only)
    /group create <name> — start an encrypted group
    /group invite @name · /group remove @name — manage members (creator)
    /group leave · /group list — leave or list your groups
    /ping @name — measure round-trip time (mesh only)
    /trace @name — estimated mesh path (mesh only)
    /pay <token> — send a cashu ecash token in this chat
    /drop <message> — pin a note to this place for 24h (needs location)
    /help — this list
    """

    /// /drop <text> — a dead drop: pins a note to the current building-level
    /// geohash with a 24h NIP-40 expiry. Anyone who passes through here and
    /// looks at notices (or hits the empty-timeline "notes left here" hint)
    /// reads it.
    private func handleDrop(_ args: String) -> CommandResult {
        guard LocationNotesSettings.enabled else {
            return .error(message: "location notes are off — enable them in the info screen")
        }
        guard let content = args.trimmedOrNilIfEmpty else {
            return .error(message: "usage: /drop <message>")
        }
        let location = LocationChannelManager.shared
        guard location.permissionState == .authorized else {
            return .error(message: "leaving a note needs location — enable it in the info screen")
        }
        guard let geohash = location.availableChannels.first(where: { $0.level == .building })?.geohash else {
            location.refreshChannels()
            return .error(message: "still finding this place — try again in a moment")
        }
        guard let nickname = contextProvider?.nickname,
              LocationNotesManager.postDrop(content: content, nickname: nickname, geohash: geohash) else {
            return .error(message: "no geo relays reachable — note not left")
        }
        // Leaving a note is an explicit notes act: it unlocks the passive
        // nearby-notes counter (tap-to-reveal) so the sender sees their own
        // drop counted on the timeline.
        NearbyNotesCounter.shared.reveal()
        return .success(message: "📍 note left here — it fades in 24h")
    }

    // MARK: - Command Handlers
    
    private func handleMessage(_ args: String) -> CommandResult {
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts.isEmpty else {
            return .error(message: "usage: /msg @nickname [message]")
        }
        
        let targetName = String(parts[0])
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        guard let peerID = contextProvider?.getPeerIDForNickname(nickname) else {
            return .error(message: "'\(nickname)' not found")
        }

        contextProvider?.startPrivateChat(with: peerID)

        if parts.count > 1 {
            let message = String(parts[1])
            contextProvider?.sendPrivateMessage(message, to: peerID)
        }
        
        return .success(message: "started private chat with \(nickname)")
    }
    
    private func handleWho() -> CommandResult {
        // Show geohash participants when in a geohash channel; otherwise mesh peers
        switch contextProvider?.activeChannel ?? .mesh {
        case .location(let ch):
            // Geohash context: show visible geohash participants (exclude self)
            guard let vm = contextProvider else { return .success(message: "nobody around") }
            let myHex = (try? vm.idBridge.deriveIdentity(forGeohash: ch.geohash))?.publicKeyHex.lowercased()
            let people = vm.getVisibleGeoParticipants().filter { person in
                if let me = myHex { return person.id.lowercased() != me }
                return true
            }
            let names = people.map { $0.displayName }
            if names.isEmpty { return .success(message: "no one else is online right now") }
            return .success(message: "online: " + names.sorted().joined(separator: ", "))
        case .mesh:
            // Mesh context: show connected peer nicknames
            guard let peers = meshService?.getPeerNicknames(), !peers.isEmpty else {
                return .success(message: "no one else is online right now")
            }
            let onlineList = peers.values.sorted().joined(separator: ", ")
            return .success(message: "online: \(onlineList)")
        }
    }
    
    private func handleClear() -> CommandResult {
        if let peerID = contextProvider?.selectedPrivateChatPeer {
            contextProvider?.clearPrivateChat(peerID)
        } else {
            contextProvider?.clearCurrentPublicTimeline()
        }
        return .handled
    }
    
    private func handleEmote(_ args: String, command: String, action: String, emoji: String, suffix: String = "") -> CommandResult {
        let targetName = args.trimmed
        guard !targetName.isEmpty else {
            return .error(message: "usage: /\(command) <nickname>")
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        guard let targetPeerID = contextProvider?.getPeerIDForNickname(nickname),
              let myNickname = contextProvider?.nickname else {
            return .error(message: "cannot \(command) \(nickname): not found")
        }
        
        let emoteContent = "* \(emoji) \(myNickname) \(action) \(nickname)\(suffix) *"
        
        if contextProvider?.selectedPrivateChatPeer != nil {
            // In private chat
            if let peerNickname = meshService?.peerNickname(peerID: targetPeerID) {
                let personalMessage = "* \(emoji) \(myNickname) \(action) you\(suffix) *"
                meshService?.sendPrivateMessage(personalMessage, to: targetPeerID,
                                               recipientNickname: peerNickname,
                                               messageID: UUID().uuidString)
                // Also add a local system message so the sender sees a natural-language confirmation
                let pastAction: String = {
                    switch action {
                    case "hugs": return "hugged"
                    case "slaps": return "slapped"
                    default: return action.hasSuffix("e") ? action + "d" : action + "ed"
                    }
                }()
                let localText = "\(emoji) you \(pastAction) \(nickname)\(suffix)"
                contextProvider?.addLocalPrivateSystemMessage(localText, to: targetPeerID)
            }
        } else {
            // In public chat: send to active public channel (mesh or geohash)
            contextProvider?.sendPublicRaw(emoteContent)
            let publicEcho = "\(emoji) \(myNickname) \(action) \(nickname)\(suffix)"
            contextProvider?.addPublicSystemMessage(publicEcho)
        }
        
        return .handled
    }
    
    private func handleBlock(_ args: String) -> CommandResult {
        let targetName = args.trimmed
        
        if targetName.isEmpty {
            // List blocked users (mesh) and geohash (Nostr) blocks
            let meshBlocked = contextProvider?.blockedUsers ?? []
            var blockedNicknames: [String] = []
            if let peers = meshService?.getPeerNicknames() {
                for (peerID, nickname) in peers {
                    if let fingerprint = meshService?.getFingerprint(for: peerID),
                       meshBlocked.contains(fingerprint) {
                        blockedNicknames.append(nickname)
                    }
                }
            }

            // Geohash blocked names (prefer visible display names; fallback to #suffix)
            let geoBlocked = Array(identityManager.getBlockedNostrPubkeys())
            var geoNames: [String] = []
            if let vm = contextProvider {
                let visible = vm.getVisibleGeoParticipants()
                let visibleIndex = Dictionary(uniqueKeysWithValues: visible.map { ($0.id.lowercased(), $0.displayName) })
                for pk in geoBlocked {
                    if let name = visibleIndex[pk.lowercased()] {
                        geoNames.append(name)
                    } else {
                        let suffix = String(pk.suffix(4))
                        geoNames.append("anon#\(suffix)")
                    }
                }
            }

            let meshList = blockedNicknames.isEmpty ? "none" : blockedNicknames.sorted().joined(separator: ", ")
            let geoList = geoNames.isEmpty ? "none" : geoNames.sorted().joined(separator: ", ")
            return .success(message: "blocked peers: \(meshList) | geohash blocks: \(geoList)")
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        if let peerID = contextProvider?.getPeerIDForNickname(nickname),
           let fingerprint = meshService?.getFingerprint(for: peerID) {
            if identityManager.isBlocked(fingerprint: fingerprint) {
                return .success(message: "\(nickname) is already blocked")
            }
            // Block the user (mesh/noise identity)
            if var identity = identityManager.getSocialIdentity(for: fingerprint) {
                identity.isBlocked = true
                identity.isFavorite = false
                identityManager.updateSocialIdentity(identity)
            } else {
                let blockedIdentity = SocialIdentity(
                    fingerprint: fingerprint,
                    localPetname: nil,
                    claimedNickname: nickname,
                    trustLevel: .unknown,
                    isFavorite: false,
                    isBlocked: true,
                    notes: nil
                )
                identityManager.updateSocialIdentity(blockedIdentity)
            }
            // Scrub their carried public messages now, while the peerID is
            // resolvable, so they can't resurface as archived echoes.
            meshService?.purgeArchivedPublicMessages(from: peerID)
            return .success(message: "blocked \(nickname). you will no longer receive messages from them")
        }
        // Mesh lookup failed; try geohash (Nostr) participant by display name
        if let pub = contextProvider?.nostrPubkeyForDisplayName(nickname) {
            if identityManager.isNostrBlocked(pubkeyHexLowercased: pub) {
                return .success(message: "\(nickname) is already blocked")
            }
            identityManager.setNostrBlocked(pub, isBlocked: true)
            return .success(message: "blocked \(nickname) in geohash chats")
        }
        
        return .error(message: "cannot block \(nickname): not found or unable to verify identity")
    }
    
    private func handleUnblock(_ args: String) -> CommandResult {
        let targetName = args.trimmed
        guard !targetName.isEmpty else {
            return .error(message: "usage: /unblock <nickname>")
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        if let peerID = contextProvider?.getPeerIDForNickname(nickname),
           let fingerprint = meshService?.getFingerprint(for: peerID) {
            if !identityManager.isBlocked(fingerprint: fingerprint) {
                return .success(message: "\(nickname) is not blocked")
            }
            identityManager.setBlocked(fingerprint, isBlocked: false)
            return .success(message: "unblocked \(nickname)")
        }
        // Try geohash unblock
        if let pub = contextProvider?.nostrPubkeyForDisplayName(nickname) {
            if !identityManager.isNostrBlocked(pubkeyHexLowercased: pub) {
                return .success(message: "\(nickname) is not blocked")
            }
            identityManager.setNostrBlocked(pub, isBlocked: false)
            return .success(message: "unblocked \(nickname) in geohash chats")
        }
        return .error(message: "cannot unblock \(nickname): not found")
    }
    
    private static let groupUsage = "usage: /group create <name> · invite @name · remove @name · leave · list"

    private func handleGroup(_ args: String) -> CommandResult {
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let subcommand = parts.first else {
            return .error(message: Self.groupUsage)
        }
        let rest = parts.count > 1 ? String(parts[1]) : ""
        guard let provider = contextProvider else { return .handled }

        switch subcommand {
        case "create":
            return provider.groupCreate(named: rest)
        case "invite":
            return provider.groupInvite(nickname: rest)
        case "remove":
            return provider.groupRemove(nickname: rest)
        case "leave":
            return provider.groupLeave()
        case "list":
            return provider.groupList()
        default:
            return .error(message: Self.groupUsage)
        }
    }

    // MARK: - Mesh Diagnostics

    private enum MeshPeerResolution {
        case resolved(peerID: PeerID, nickname: String)
        case failed(CommandResult)
    }

    /// Resolves a mesh peer for /ping and /trace. Geohash identities are
    /// rejected — diagnostics measure the BLE mesh, not Nostr.
    private func resolveMeshPeer(_ args: String, command: String) -> MeshPeerResolution {
        let targetName = args.trimmed
        guard !targetName.isEmpty else {
            return .failed(.error(message: "usage: /\(command) <nickname>"))
        }
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        guard let peerID = contextProvider?.getPeerIDForNickname(nickname),
              !peerID.isGeoDM, !peerID.isGeoChat else {
            return .failed(.error(message: "cannot \(command) \(nickname): not found on mesh"))
        }
        return .resolved(peerID: peerID, nickname: nickname)
    }

    private func handlePing(_ args: String) -> CommandResult {
        let target: (peerID: PeerID, nickname: String)
        switch resolveMeshPeer(args, command: "ping") {
        case .resolved(let peerID, let nickname): target = (peerID, nickname)
        case .failed(let result): return result
        }

        let nickname = target.nickname
        let currentProvider = contextProvider
        // Capture the origin conversation now: the pong can arrive up to
        // meshPingTimeoutSeconds later, and reading the selected chat at
        // callback time would misroute the result after a chat switch.
        let destination = contextProvider?.currentCommandDestination() ?? .meshTimeline
        meshService?.sendMeshPing(to: target.peerID) { [weak currentProvider] result in
            let provider = currentProvider
            guard let result else {
                provider?.addCommandOutput("no reply from \(nickname)", to: destination)
                return
            }
            let hopText: String = result.hops.map { hops in
                hops == 1 ? " · direct (1 hop)" : " · \(hops) hops"
            } ?? ""
            provider?.addCommandOutput("pong from \(nickname): \(result.rttMs) ms\(hopText)", to: destination)
        }
        return .success(message: "pinging \(nickname)…")
    }

    private func handleTrace(_ args: String) -> CommandResult {
        let target: (peerID: PeerID, nickname: String)
        switch resolveMeshPeer(args, command: "trace") {
        case .resolved(let peerID, let nickname): target = (peerID, nickname)
        case .failed(let result): return result
        }

        guard let mesh = meshService,
              let intermediates = mesh.computeMeshPath(to: target.peerID) else {
            return .success(message: "no known path to \(target.nickname)")
        }
        // Graph-derived from gossiped neighbor claims, not route-recorded —
        // present it as an estimate.
        let hopNames = intermediates.map { hop in
            mesh.peerNickname(peerID: hop) ?? "\(hop.id.prefix(8))…"
        }
        let chain = (["you"] + hopNames + [target.nickname]).joined(separator: " → ")
        let hops = intermediates.count + 1
        return .success(message: "estimated path: \(chain) (\(hops) hop\(hops == 1 ? "" : "s"))")
    }

    /// `/pay <cashu-token>` — validates the token decodes, then sends it as
    /// the message body in the current chat. Cashu tokens are bearer
    /// instruments (whoever redeems first gets the funds), so posting one to
    /// a public channel requires an explicit `/pay <token> public` confirm.
    /// The app never contacts a mint; it only relays the string.
    private func handlePay(_ args: String) -> CommandResult {
        var parts = args.trimmed.split(separator: " ").map(String.init)
        guard !parts.isEmpty else {
            return .success(message: "usage: /pay <token> — paste a cashu token: /pay cashuA…")
        }

        let confirmedPublic = parts.count > 1 && parts.last?.lowercased() == "public"
        if confirmedPublic { parts.removeLast() }

        guard parts.count == 1, let token = CashuTokenDecoder.bareToken(from: parts[0]) else {
            return .error(message: "that doesn't look like a cashu token — expected cashuA… or cashuB…")
        }
        guard let info = CashuTokenDecoder.decode(token, strict: true) else {
            return .error(message: "invalid cashu token — it doesn't decode to a known token with an amount, not sending it")
        }

        let summary = info.displayAmount ?? "a cashu token"

        if let peerID = contextProvider?.selectedPrivateChatPeer {
            contextProvider?.sendPrivateMessage(token, to: peerID)
            return .success(message: "sent \(summary) — cashu is a bearer token; whoever redeems it first gets the funds")
        }

        guard confirmedPublic else {
            return .error(message: "this is a public channel — anyone reading it can redeem the token. send anyway: /pay <token> public")
        }

        contextProvider?.sendPublicMessage(token)
        return .success(message: "sent \(summary) to the public channel — anyone here can redeem it")
    }

    private func handleFavorite(_ args: String, add: Bool) -> CommandResult {
        let targetName = args.trimmed
        guard !targetName.isEmpty else {
            return .error(message: "usage: /\(add ? "fav" : "unfav") <nickname>")
        }

        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName

        guard let peerID = contextProvider?.getPeerIDForNickname(nickname) else {
            return .error(message: "can't find peer: \(nickname)")
        }

        // Resolve current state by the peer's real noise key. The resolved
        // peerID is either the short 16-hex mesh ID or the full 64-hex
        // noise-key ID (offline favorite row) — never the noise key itself.
        let isCurrentlyFavorite: Bool
        if let noiseKey = peerID.noiseKey {
            isCurrentlyFavorite = FavoritesPersistenceService.shared.isFavorite(noiseKey)
        } else {
            isCurrentlyFavorite = FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: peerID)?.isFavorite ?? false
        }

        guard add != isCurrentlyFavorite else {
            return .success(message: add ? "\(nickname) is already a favorite" : "\(nickname) is not a favorite")
        }

        // toggleFavorite persists by the real noise key and notifies the peer.
        contextProvider?.toggleFavorite(peerID: peerID)

        return .success(message: add ? "added \(nickname) to favorites" : "removed \(nickname) from favorites")
    }
    
}
