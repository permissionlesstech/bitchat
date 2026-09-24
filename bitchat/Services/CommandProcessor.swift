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
    /// Mesh-only command surfaces, absent when the transport lacks them.
    private var meshDiagnostics: MeshDiagnosing? { meshService as? MeshDiagnosing }
    private var meshArchive: MeshPublicArchiving? { meshService as? MeshPublicArchiving }
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
        guard let cmd = parts.first else { return .error(message: String(localized: "command.error.invalid", defaultValue: "invalid command", comment: "Error for an empty or unparseable slash command")) }
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
            if inGeoPublic || inGeoDM { return .error(message: String(localized: "command.error.groups_mesh_only", defaultValue: "groups are only for mesh peers in #mesh", comment: "Error when a group command is used outside the mesh channel")) }
            return handleGroup(args)
        case "/fav":
            if inGeoPublic || inGeoDM { return .error(message: String(localized: "command.error.favorites_mesh_only", defaultValue: "favorites are only for mesh peers in #mesh", comment: "Error when a favorites command is used outside the mesh channel")) }
            return handleFavorite(args, add: true)
        case "/unfav":
            if inGeoPublic || inGeoDM { return .error(message: String(localized: "command.error.favorites_mesh_only", defaultValue: "favorites are only for mesh peers in #mesh", comment: "Error when a favorites command is used outside the mesh channel")) }
            return handleFavorite(args, add: false)
        case "/ping":
            if inGeoPublic || inGeoDM { return .error(message: String(localized: "command.error.ping_mesh_only", defaultValue: "ping only works for mesh peers in #mesh", comment: "Error when /ping is used outside the mesh channel")) }
            return handlePing(args)
        case "/trace":
            if inGeoPublic || inGeoDM { return .error(message: String(localized: "command.error.trace_mesh_only", defaultValue: "trace only works for mesh peers in #mesh", comment: "Error when /trace is used outside the mesh channel")) }
            return handleTrace(args)
        case "/pay":
            return handlePay(args)
        case "/drop":
            return handleDrop(args)
        case "/help":
            return .success(message: Self.helpText)
        default:
            return .error(message: String(format: String(localized: "command.error.unknown", defaultValue: "unknown command: %@ — type /help for commands", comment: "Error for an unrecognized slash command; placeholder is the typed command"), locale: .current, String(cmd)))
        }
    }

    /// Local-only command reference, printed as a system message. The
    /// suggestion panel hides once arguments are typed, and typos used to
    /// dead-end in a bare "unknown command" — this is the way out.
    static var helpText: String {
        String(localized: "command.help.text", defaultValue: "commands:\n/msg @name [message] — start a private chat\n/who — list who's here\n/clear — clear this chat\n/hug @name — send a hug\n/slap @name — slap with a large trout\n/block @name · /unblock @name\n/fav @name · /unfav @name — favorites (mesh only)\n/group create <name> — start an encrypted group\n/group invite @name · /group remove @name — manage members (creator)\n/group leave · /group list — leave or list your groups\n/ping @name — measure round-trip time (mesh only)\n/trace @name — estimated mesh path (mesh only)\n/pay <token> — send a cashu ecash token in this chat\n/drop <message> — pin a note to this place for 24h (needs location)\n/help — this list", comment: "The /help reference list; command syntax stays verbatim, only the descriptions after each dash are translated")
    }

    /// /drop <text> — a dead drop: pins a note to the current building-level
    /// geohash with a 24h NIP-40 expiry. Anyone who passes through here and
    /// looks at notices (or hits the empty-timeline "notes left here" hint)
    /// reads it.
    private func handleDrop(_ args: String) -> CommandResult {
        guard LocationNotesSettings.enabled else {
            return .error(message: String(localized: "command.drop.notes_off", defaultValue: "location notes are off — enable them in the info screen", comment: "Error when /drop is used while location notes are disabled"))
        }
        guard let content = args.trimmedOrNilIfEmpty else {
            return .error(message: String(localized: "command.drop.usage", defaultValue: "usage: /drop <message>", comment: "Usage hint for /drop"))
        }
        let location = LocationChannelManager.shared
        guard location.permissionState == .authorized else {
            return .error(message: String(localized: "command.drop.needs_location", defaultValue: "leaving a note needs location — enable it in the info screen", comment: "Error when /drop is used without location permission"))
        }
        guard let geohash = location.availableChannels.first(where: { $0.level == .building })?.geohash else {
            location.refreshChannels()
            return .error(message: String(localized: "command.drop.finding_place", defaultValue: "still finding this place — try again in a moment", comment: "Error when /drop runs before a location fix arrives"))
        }
        guard let nickname = contextProvider?.nickname,
              LocationNotesManager.postDrop(content: content, nickname: nickname, geohash: geohash) else {
            return .error(message: String(localized: "command.drop.no_relays", defaultValue: "no geo relays reachable — note not left", comment: "Error when /drop finds no reachable geo relays"))
        }
        // Leaving a note is an explicit notes act: it unlocks the passive
        // nearby-notes counter (tap-to-reveal) so the sender sees their own
        // drop counted on the timeline.
        NearbyNotesCounter.shared.reveal()
        return .success(message: String(localized: "command.drop.left", defaultValue: "📍 note left here — it fades in 24h", comment: "Confirmation after /drop pins a note"))
    }

    // MARK: - Command Handlers
    
    private func handleMessage(_ args: String) -> CommandResult {
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts.isEmpty else {
            return .error(message: String(localized: "command.msg.usage", defaultValue: "usage: /msg @nickname [message]", comment: "Usage hint for /msg"))
        }
        
        let targetName = String(parts[0])
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        guard let peerID = contextProvider?.getPeerIDForNickname(nickname) else {
            return .error(message: String(format: String(localized: "command.msg.not_found", defaultValue: "'%@' not found", comment: "Error when /msg can't resolve the nickname"), locale: .current, nickname))
        }

        contextProvider?.startPrivateChat(with: peerID)

        if parts.count > 1 {
            let message = String(parts[1])
            contextProvider?.sendPrivateMessage(message, to: peerID)
        }
        
        return .success(message: String(format: String(localized: "command.msg.started", defaultValue: "started private chat with %@", comment: "Confirmation after /msg opens a private chat"), locale: .current, nickname))
    }
    
    private func handleWho() -> CommandResult {
        // Show geohash participants when in a geohash channel; otherwise mesh peers
        switch contextProvider?.activeChannel ?? .mesh {
        case .location(let ch):
            // Geohash context: show visible geohash participants (exclude self)
            guard let vm = contextProvider else { return .success(message: String(localized: "command.who.nobody", defaultValue: "nobody around", comment: "Reply to /who when no context is available")) }
            let myHex = (try? vm.idBridge.deriveIdentity(forGeohash: ch.geohash))?.publicKeyHex.lowercased()
            let people = vm.getVisibleGeoParticipants().filter { person in
                if let me = myHex { return person.id.lowercased() != me }
                return true
            }
            let names = people.map { $0.displayName }
            if names.isEmpty { return .success(message: String(localized: "command.who.none_online", defaultValue: "no one else is online right now", comment: "Reply to /who when nobody else is online")) }
            return .success(message: String(format: String(localized: "command.who.online", defaultValue: "online: %@", comment: "Reply to /who; placeholder is the list of names"), locale: .current, names.sorted().joined(separator: ", ")))
        case .mesh:
            // Mesh context: show connected peer nicknames
            guard let peers = meshService?.getPeerNicknames(), !peers.isEmpty else {
                return .success(message: String(localized: "command.who.none_online", defaultValue: "no one else is online right now", comment: "Reply to /who when nobody else is online"))
            }
            let onlineList = peers.values.sorted().joined(separator: ", ")
            return .success(message: String(format: String(localized: "command.who.online", defaultValue: "online: %@", comment: "Reply to /who; placeholder is the list of names"), locale: .current, onlineList))
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
            return .error(message: String(format: String(localized: "command.action.usage", defaultValue: "usage: /%@ <nickname>", comment: "Usage hint for a command that takes a nickname; placeholder is the command name"), locale: .current, command))
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        guard let targetPeerID = contextProvider?.getPeerIDForNickname(nickname),
              let myNickname = contextProvider?.nickname else {
            return .error(message: String(format: String(localized: "command.action.not_found", defaultValue: "cannot %1$@ %2$@: not found", comment: "Error when an action command can't resolve its target; placeholders are the command and the nickname"), locale: .current, command, nickname))
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
            return .success(message: String(format: String(localized: "command.block.list", defaultValue: "blocked peers: %1$@ | geohash blocks: %2$@", comment: "Reply to /block with no argument; placeholders are the mesh and geohash block lists"), locale: .current, meshList, geoList))
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        if let peerID = contextProvider?.getPeerIDForNickname(nickname),
           let fingerprint = meshService?.getFingerprint(for: peerID) {
            if identityManager.isBlocked(fingerprint: fingerprint) {
                return .success(message: String(format: String(localized: "command.block.already", defaultValue: "%@ is already blocked", comment: "Reply when /block targets an already-blocked nickname"), locale: .current, nickname))
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
            meshArchive?.purgeArchivedPublicMessages(from: peerID)
            return .success(message: String(format: String(localized: "command.block.done", defaultValue: "blocked %@. you will no longer see their messages", comment: "Confirmation after blocking a mesh peer"), locale: .current, nickname))
        }
        // Mesh lookup failed; try geohash (Nostr) participant by display name
        if let pub = contextProvider?.nostrPubkeyForDisplayName(nickname) {
            if identityManager.isNostrBlocked(pubkeyHexLowercased: pub) {
                return .success(message: String(format: String(localized: "command.block.already", defaultValue: "%@ is already blocked", comment: "Reply when /block targets an already-blocked nickname"), locale: .current, nickname))
            }
            identityManager.setNostrBlocked(pub, isBlocked: true)
            return .success(message: String(format: String(localized: "command.block.done_geo", defaultValue: "blocked %@ in geohash chats", comment: "Confirmation after blocking a geohash participant"), locale: .current, nickname))
        }
        
        return .error(message: String(format: String(localized: "command.block.failed", defaultValue: "cannot block %@: not found or unable to verify identity", comment: "Error when /block can't resolve or verify the target"), locale: .current, nickname))
    }
    
    private func handleUnblock(_ args: String) -> CommandResult {
        let targetName = args.trimmed
        guard !targetName.isEmpty else {
            return .error(message: String(localized: "command.unblock.usage", defaultValue: "usage: /unblock <nickname>", comment: "Usage hint for /unblock"))
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        if let peerID = contextProvider?.getPeerIDForNickname(nickname),
           let fingerprint = meshService?.getFingerprint(for: peerID) {
            if !identityManager.isBlocked(fingerprint: fingerprint) {
                return .success(message: String(format: String(localized: "command.unblock.not_blocked", defaultValue: "%@ is not blocked", comment: "Reply when /unblock targets a nickname that isn't blocked"), locale: .current, nickname))
            }
            identityManager.setBlocked(fingerprint, isBlocked: false)
            return .success(message: String(format: String(localized: "command.unblock.done", defaultValue: "unblocked %@", comment: "Confirmation after unblocking a mesh peer"), locale: .current, nickname))
        }
        // Try geohash unblock
        if let pub = contextProvider?.nostrPubkeyForDisplayName(nickname) {
            if !identityManager.isNostrBlocked(pubkeyHexLowercased: pub) {
                return .success(message: String(format: String(localized: "command.unblock.not_blocked", defaultValue: "%@ is not blocked", comment: "Reply when /unblock targets a nickname that isn't blocked"), locale: .current, nickname))
            }
            identityManager.setNostrBlocked(pub, isBlocked: false)
            return .success(message: String(format: String(localized: "command.unblock.done_geo", defaultValue: "unblocked %@ in geohash chats", comment: "Confirmation after unblocking a geohash participant"), locale: .current, nickname))
        }
        return .error(message: String(format: String(localized: "command.unblock.failed", defaultValue: "cannot unblock %@: not found", comment: "Error when /unblock can't resolve the target"), locale: .current, nickname))
    }
    
    private static var groupUsage: String { String(localized: "command.group.usage", defaultValue: "usage: /group create <name> · invite @name · remove @name · leave · list", comment: "Usage hint for /group subcommands") }

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
            return .failed(.error(message: String(format: String(localized: "command.action.usage", defaultValue: "usage: /%@ <nickname>", comment: "Usage hint for a command that takes a nickname; placeholder is the command name"), locale: .current, command)))
        }
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        guard let peerID = contextProvider?.getPeerIDForNickname(nickname),
              !peerID.isGeoDM, !peerID.isGeoChat else {
            return .failed(.error(message: String(format: String(localized: "command.action.not_found_mesh", defaultValue: "cannot %1$@ %2$@: not found on mesh", comment: "Error when a mesh-only command can't resolve its target; placeholders are the command and the nickname"), locale: .current, command, nickname)))
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
        meshDiagnostics?.sendMeshPing(to: target.peerID) { [weak currentProvider] result in
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
        return .success(message: String(format: String(localized: "command.ping.started", defaultValue: "pinging %@…", comment: "Confirmation that /ping sent a probe"), locale: .current, nickname))
    }

    private func handleTrace(_ args: String) -> CommandResult {
        let target: (peerID: PeerID, nickname: String)
        switch resolveMeshPeer(args, command: "trace") {
        case .resolved(let peerID, let nickname): target = (peerID, nickname)
        case .failed(let result): return result
        }

        guard let mesh = meshService,
              let intermediates = meshDiagnostics?.computeMeshPath(to: target.peerID) else {
            return .success(message: String(format: String(localized: "command.trace.no_path", defaultValue: "no known path to %@", comment: "Reply when /trace has no mesh path to the target"), locale: .current, target.nickname))
        }
        // Graph-derived from gossiped neighbor claims, not route-recorded —
        // present it as an estimate.
        let hopNames = intermediates.map { hop in
            mesh.peerNickname(peerID: hop) ?? "\(hop.id.prefix(8))…"
        }
        let you = String(localized: "command.trace.you", defaultValue: "you", comment: "Label for the local device at the start of a /trace path")
        let chain = ([you] + hopNames + [target.nickname]).joined(separator: " → ")
        let hops = intermediates.count + 1
        let pathMessage = hops == 1
            ? String(format: String(localized: "command.trace.path_one", defaultValue: "estimated path: %@ (1 hop)", comment: "Reply to /trace for a single-hop path; placeholder is the node chain"), locale: .current, chain)
            : String(format: String(localized: "command.trace.path_many", defaultValue: "estimated path: %1$@ (%2$lld hops)", comment: "Reply to /trace; placeholders are the node chain and hop count"), locale: .current, chain, hops)
        return .success(message: pathMessage)
    }

    /// `/pay <cashu-token>` — validates the token decodes, then sends it as
    /// the message body in the current chat. Cashu tokens are bearer
    /// instruments (whoever redeems first gets the funds), so posting one to
    /// a public channel requires an explicit `/pay <token> public` confirm.
    /// The app never contacts a mint; it only relays the string.
    private func handlePay(_ args: String) -> CommandResult {
        var parts = args.trimmed.split(separator: " ").map(String.init)
        guard !parts.isEmpty else {
            return .success(message: String(localized: "command.pay.usage", defaultValue: "usage: /pay <token> — paste a cashu token: /pay cashuA…", comment: "Usage hint for /pay"))
        }

        let confirmedPublic = parts.count > 1 && parts.last?.lowercased() == "public"
        if confirmedPublic { parts.removeLast() }

        guard parts.count == 1, let token = CashuTokenDecoder.bareToken(from: parts[0]) else {
            return .error(message: String(localized: "command.pay.not_token", defaultValue: "that doesn't look like a cashu token — expected cashuA… or cashuB…", comment: "Error when /pay input has no cashu prefix"))
        }
        guard let info = CashuTokenDecoder.decode(token, strict: true) else {
            return .error(message: String(localized: "command.pay.invalid", defaultValue: "invalid cashu token — it doesn't decode to a known token with an amount, not sending it", comment: "Error when /pay input fails to decode"))
        }

        let summary = info.displayAmount ?? "a cashu token"

        if let peerID = contextProvider?.selectedPrivateChatPeer {
            contextProvider?.sendPrivateMessage(token, to: peerID)
            return .success(message: String(format: String(localized: "command.pay.sent_private", defaultValue: "sent %@ — cashu is a bearer token; whoever redeems it first gets the funds", comment: "Confirmation after sending a cashu token in a private chat; placeholder is the amount summary"), locale: .current, summary))
        }

        guard confirmedPublic else {
            return .error(message: String(localized: "command.pay.public_confirm", defaultValue: "this is a public channel — anyone reading it can redeem the token. send anyway: /pay <token> public", comment: "Confirmation gate before sending a cashu token to a public channel"))
        }

        contextProvider?.sendPublicMessage(token)
        return .success(message: String(format: String(localized: "command.pay.sent_public", defaultValue: "sent %@ to the public channel — anyone here can redeem it", comment: "Confirmation after sending a cashu token to a public channel; placeholder is the amount summary"), locale: .current, summary))
    }

    private func handleFavorite(_ args: String, add: Bool) -> CommandResult {
        let targetName = args.trimmed
        guard !targetName.isEmpty else {
            return .error(message: String(format: String(localized: "command.action.usage", defaultValue: "usage: /%@ <nickname>", comment: "Usage hint for a command that takes a nickname; placeholder is the command name"), locale: .current, (add ? "fav" : "unfav")))
        }

        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName

        guard let peerID = contextProvider?.getPeerIDForNickname(nickname) else {
            return .error(message: String(format: String(localized: "command.fav.not_found", defaultValue: "can't find peer: %@", comment: "Error when /fav or /unfav can't resolve the nickname"), locale: .current, nickname))
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
            return .success(message: add
                ? String(format: String(localized: "command.fav.already", defaultValue: "%@ is already a favorite", comment: "Reply when /fav targets an existing favorite"), locale: .current, nickname)
                : String(format: String(localized: "command.fav.not_favorite", defaultValue: "%@ is not a favorite", comment: "Reply when /unfav targets someone who isn't a favorite"), locale: .current, nickname))
        }

        // toggleFavorite persists by the real noise key and notifies the peer.
        contextProvider?.toggleFavorite(peerID: peerID)

        return .success(message: add
            ? String(format: String(localized: "command.fav.added", defaultValue: "added %@ to favorites", comment: "Confirmation after /fav"), locale: .current, nickname)
            : String(format: String(localized: "command.fav.removed", defaultValue: "removed %@ from favorites", comment: "Confirmation after /unfav"), locale: .current, nickname))
    }
    
}
