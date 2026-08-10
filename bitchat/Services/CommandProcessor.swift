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
        guard let cmd = parts.first else { return .error(message: Strings.invalidCommand) }
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
            if inGeoPublic || inGeoDM { return .error(message: Strings.groupsMeshOnly) }
            return handleGroup(args)
        case "/fav":
            if inGeoPublic || inGeoDM { return .error(message: Strings.favoritesMeshOnly) }
            return handleFavorite(args, add: true)
        case "/unfav":
            if inGeoPublic || inGeoDM { return .error(message: Strings.favoritesMeshOnly) }
            return handleFavorite(args, add: false)
        case "/ping":
            if inGeoPublic || inGeoDM { return .error(message: Strings.pingMeshOnly) }
            return handlePing(args)
        case "/trace":
            if inGeoPublic || inGeoDM { return .error(message: Strings.traceMeshOnly) }
            return handleTrace(args)
        case "/pay":
            return handlePay(args)
        case "/drop":
            return handleDrop(args)
        case "/help":
            return .success(message: Strings.helpText)
        default:
            return .error(message: Strings.unknownCommand(String(cmd)))
        }
    }

    /// Local-only command reference, printed as a system message. The
    /// suggestion panel hides once arguments are typed, and typos used to
    /// dead-end in a bare "unknown command" — this is the way out.
    static var helpText: String { Strings.helpText }

    /// /drop <text> — a dead drop: pins a note to the current building-level
    /// geohash with a 24h NIP-40 expiry. Anyone who passes through here and
    /// looks at notices (or hits the empty-timeline "notes left here" hint)
    /// reads it.
    private func handleDrop(_ args: String) -> CommandResult {
        guard LocationNotesSettings.enabled else {
            return .error(message: Strings.dropNotesOff)
        }
        guard let content = args.trimmedOrNilIfEmpty else {
            return .error(message: Strings.dropUsage)
        }
        let location = LocationChannelManager.shared
        guard location.permissionState == .authorized else {
            return .error(message: Strings.dropNeedsLocation)
        }
        guard let geohash = location.availableChannels.first(where: { $0.level == .building })?.geohash else {
            location.refreshChannels()
            return .error(message: Strings.dropFindingPlace)
        }
        guard let nickname = contextProvider?.nickname,
              LocationNotesManager.postDrop(content: content, nickname: nickname, geohash: geohash) else {
            return .error(message: Strings.dropNoRelays)
        }
        // Leaving a note is an explicit notes act: it unlocks the passive
        // nearby-notes counter (tap-to-reveal) so the sender sees their own
        // drop counted on the timeline.
        NearbyNotesCounter.shared.reveal()
        return .success(message: Strings.dropLeft)
    }

    // MARK: - Command Handlers
    
    private func handleMessage(_ args: String) -> CommandResult {
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts.isEmpty else {
            return .error(message: Strings.msgUsage)
        }
        
        let targetName = String(parts[0])
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        guard let peerID = contextProvider?.getPeerIDForNickname(nickname) else {
            return .error(message: Strings.msgNotFound(nickname))
        }

        contextProvider?.startPrivateChat(with: peerID)

        if parts.count > 1 {
            let message = String(parts[1])
            contextProvider?.sendPrivateMessage(message, to: peerID)
        }
        
        return .success(message: Strings.msgStarted(nickname))
    }
    
    private func handleWho() -> CommandResult {
        // Show geohash participants when in a geohash channel; otherwise mesh peers
        switch contextProvider?.activeChannel ?? .mesh {
        case .location(let ch):
            // Geohash context: show visible geohash participants (exclude self)
            guard let vm = contextProvider else { return .success(message: Strings.whoNobody) }
            let myHex = (try? vm.idBridge.deriveIdentity(forGeohash: ch.geohash))?.publicKeyHex.lowercased()
            let people = vm.getVisibleGeoParticipants().filter { person in
                if let me = myHex { return person.id.lowercased() != me }
                return true
            }
            let names = people.map { $0.displayName }
            if names.isEmpty { return .success(message: Strings.whoEmpty) }
            return .success(message: Strings.whoOnline(names.sorted().joined(separator: ", ")))
        case .mesh:
            // Mesh context: show connected peer nicknames
            guard let peers = meshService?.getPeerNicknames(), !peers.isEmpty else {
                return .success(message: Strings.whoEmpty)
            }
            let onlineList = peers.values.sorted().joined(separator: ", ")
            return .success(message: Strings.whoOnline(onlineList))
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
            return .error(message: Strings.namedUsage(command))
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        guard let targetPeerID = contextProvider?.getPeerIDForNickname(nickname),
              let myNickname = contextProvider?.nickname else {
            return .error(message: Strings.emoteNotFound(command: command, nickname: nickname))
        }
        
        // Emote mesh content stays English — it is chat/wire-visible protocol text.
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

            let none = Strings.listNone
            let meshList = blockedNicknames.isEmpty ? none : blockedNicknames.sorted().joined(separator: ", ")
            let geoList = geoNames.isEmpty ? none : geoNames.sorted().joined(separator: ", ")
            return .success(message: Strings.blockList(mesh: meshList, geo: geoList))
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        if let peerID = contextProvider?.getPeerIDForNickname(nickname),
           let fingerprint = meshService?.getFingerprint(for: peerID) {
            if identityManager.isBlocked(fingerprint: fingerprint) {
                return .success(message: Strings.blockAlready(nickname))
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
            return .success(message: Strings.blockMesh(nickname))
        }
        // Mesh lookup failed; try geohash (Nostr) participant by display name
        if let pub = contextProvider?.nostrPubkeyForDisplayName(nickname) {
            if identityManager.isNostrBlocked(pubkeyHexLowercased: pub) {
                return .success(message: Strings.blockAlready(nickname))
            }
            identityManager.setNostrBlocked(pub, isBlocked: true)
            return .success(message: Strings.blockGeohash(nickname))
        }
        
        return .error(message: Strings.blockNotFound(nickname))
    }
    
    private func handleUnblock(_ args: String) -> CommandResult {
        let targetName = args.trimmed
        guard !targetName.isEmpty else {
            return .error(message: Strings.unblockUsage)
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        if let peerID = contextProvider?.getPeerIDForNickname(nickname),
           let fingerprint = meshService?.getFingerprint(for: peerID) {
            if !identityManager.isBlocked(fingerprint: fingerprint) {
                return .success(message: Strings.unblockNotBlocked(nickname))
            }
            identityManager.setBlocked(fingerprint, isBlocked: false)
            return .success(message: Strings.unblockMesh(nickname))
        }
        // Try geohash unblock
        if let pub = contextProvider?.nostrPubkeyForDisplayName(nickname) {
            if !identityManager.isNostrBlocked(pubkeyHexLowercased: pub) {
                return .success(message: Strings.unblockNotBlocked(nickname))
            }
            identityManager.setNostrBlocked(pub, isBlocked: false)
            return .success(message: Strings.unblockGeohash(nickname))
        }
        return .error(message: Strings.unblockNotFound(nickname))
    }
    
    private static var groupUsage: String { Strings.groupUsage }

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
            return .failed(.error(message: Strings.namedUsage(command)))
        }
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        guard let peerID = contextProvider?.getPeerIDForNickname(nickname),
              !peerID.isGeoDM, !peerID.isGeoChat else {
            return .failed(.error(message: Strings.meshNotFound(command: command, nickname: nickname)))
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
                provider?.addCommandOutput(Strings.pingNoReply(nickname), to: destination)
                return
            }
            let hopText: String = result.hops.map { hops in
                hops == 1 ? Strings.pingHopDirect : Strings.pingHopMany(hops)
            } ?? ""
            provider?.addCommandOutput(Strings.pingPong(nickname: nickname, rttMs: result.rttMs, hopText: hopText), to: destination)
        }
        return .success(message: Strings.pingPinging(nickname))
    }

    private func handleTrace(_ args: String) -> CommandResult {
        let target: (peerID: PeerID, nickname: String)
        switch resolveMeshPeer(args, command: "trace") {
        case .resolved(let peerID, let nickname): target = (peerID, nickname)
        case .failed(let result): return result
        }

        guard let mesh = meshService,
              let intermediates = meshDiagnostics?.computeMeshPath(to: target.peerID) else {
            return .success(message: Strings.traceNoPath(target.nickname))
        }
        // Graph-derived from gossiped neighbor claims, not route-recorded —
        // present it as an estimate.
        let hopNames = intermediates.map { hop in
            mesh.peerNickname(peerID: hop) ?? "\(hop.id.prefix(8))…"
        }
        let chain = (["you"] + hopNames + [target.nickname]).joined(separator: " → ")
        let hops = intermediates.count + 1
        return .success(message: Strings.tracePath(chain: chain, hops: hops))
    }

    /// `/pay <cashu-token>` — validates the token decodes, then sends it as
    /// the message body in the current chat. Cashu tokens are bearer
    /// instruments (whoever redeems first gets the funds), so posting one to
    /// a public channel requires an explicit `/pay <token> public` confirm.
    /// The app never contacts a mint; it only relays the string.
    private func handlePay(_ args: String) -> CommandResult {
        var parts = args.trimmed.split(separator: " ").map(String.init)
        guard !parts.isEmpty else {
            return .success(message: Strings.payUsage)
        }

        let confirmedPublic = parts.count > 1 && parts.last?.lowercased() == "public"
        if confirmedPublic { parts.removeLast() }

        guard parts.count == 1, let token = CashuTokenDecoder.bareToken(from: parts[0]) else {
            return .error(message: Strings.payNotToken)
        }
        guard let info = CashuTokenDecoder.decode(token, strict: true) else {
            return .error(message: Strings.payInvalid)
        }

        let summary = info.displayAmount ?? "a cashu token"

        if let peerID = contextProvider?.selectedPrivateChatPeer {
            contextProvider?.sendPrivateMessage(token, to: peerID)
            return .success(message: Strings.paySentPrivate(summary))
        }

        guard confirmedPublic else {
            return .error(message: Strings.payPublicConfirm)
        }

        contextProvider?.sendPublicMessage(token)
        return .success(message: Strings.paySentPublic(summary))
    }

    private func handleFavorite(_ args: String, add: Bool) -> CommandResult {
        let targetName = args.trimmed
        guard !targetName.isEmpty else {
            return .error(message: Strings.namedUsage(add ? "fav" : "unfav"))
        }

        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName

        guard let peerID = contextProvider?.getPeerIDForNickname(nickname) else {
            return .error(message: Strings.favoriteNotFound(nickname))
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
            return .success(message: add ? Strings.favoriteAlready(nickname) : Strings.favoriteNotFavorite(nickname))
        }

        // toggleFavorite persists by the real noise key and notifies the peer.
        contextProvider?.toggleFavorite(peerID: peerID)

        return .success(message: add ? Strings.favoriteAdded(nickname) : Strings.favoriteRemoved(nickname))
    }

    // MARK: - Localized strings

    /// Local-only command result / help copy. Emote mesh content is intentionally
    /// left in English so wire-visible text stays protocol-stable.
    enum Strings {
        static var invalidCommand: String {
            String(localized: "command.error.invalid", defaultValue: "Invalid command", comment: "Returned when the command string has no leading token")
        }
        static var groupsMeshOnly: String {
            String(localized: "command.error.groups.mesh_only", defaultValue: "groups are only for mesh peers in #mesh", comment: "Returned when /group is used outside mesh context")
        }
        static var favoritesMeshOnly: String {
            String(localized: "command.error.favorites.mesh_only", defaultValue: "favorites are only for mesh peers in #mesh", comment: "Returned when /fav or /unfav is used outside mesh context")
        }
        static var pingMeshOnly: String {
            String(localized: "command.error.ping.mesh_only", defaultValue: "ping only works for mesh peers in #mesh", comment: "Returned when /ping is used outside mesh context")
        }
        static var traceMeshOnly: String {
            String(localized: "command.error.trace.mesh_only", defaultValue: "trace only works for mesh peers in #mesh", comment: "Returned when /trace is used outside mesh context")
        }
        static func unknownCommand(_ cmd: String) -> String {
            String(
                format: String(localized: "command.error.unknown", defaultValue: "unknown command: %@ — type /help for commands", comment: "Returned for an unrecognized slash command; %@ is the command token"),
                locale: .current,
                cmd
            )
        }
        static var helpText: String {
            String(localized: "command.help.text", defaultValue: """
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
            """, comment: "Full /help command reference printed as a system message")
        }
        static var dropNotesOff: String {
            String(localized: "command.error.drop.notes_off", defaultValue: "location notes are off — enable them in the info screen", comment: "Returned by /drop when location notes are disabled")
        }
        static var dropUsage: String {
            String(localized: "command.usage.drop", defaultValue: "usage: /drop <message>", comment: "Usage hint when /drop has no message argument")
        }
        static var dropNeedsLocation: String {
            String(localized: "command.error.drop.needs_location", defaultValue: "leaving a note needs location — enable it in the info screen", comment: "Returned by /drop when location permission is not authorized")
        }
        static var dropFindingPlace: String {
            String(localized: "command.error.drop.finding_place", defaultValue: "still finding this place — try again in a moment", comment: "Returned by /drop when building-level geohash is not yet available")
        }
        static var dropNoRelays: String {
            String(localized: "command.error.drop.no_relays", defaultValue: "no geo relays reachable — note not left", comment: "Returned by /drop when posting to geo relays fails")
        }
        static var dropLeft: String {
            String(localized: "command.success.drop.left", defaultValue: "📍 note left here — it fades in 24h", comment: "Success confirmation after leaving a location note via /drop")
        }
        static var msgUsage: String {
            String(localized: "command.usage.msg", defaultValue: "usage: /msg @nickname [message]", comment: "Usage hint when /msg has no nickname argument")
        }
        static func msgNotFound(_ nickname: String) -> String {
            String(
                format: String(localized: "command.error.msg.not_found", defaultValue: "'%@' not found", comment: "Returned by /msg when the nickname cannot be resolved; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
        static func msgStarted(_ nickname: String) -> String {
            String(
                format: String(localized: "command.success.msg.started", defaultValue: "started private chat with %@", comment: "Success after starting a private chat via /msg; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
        static var whoNobody: String {
            String(localized: "command.success.who.nobody", defaultValue: "nobody around", comment: "Returned by /who in geohash when context provider is missing")
        }
        static var whoEmpty: String {
            String(localized: "command.success.who.empty", defaultValue: "no one else is online right now", comment: "Returned by /who when no other peers are online")
        }
        static func whoOnline(_ list: String) -> String {
            String(
                format: String(localized: "command.success.who.online", defaultValue: "online: %@", comment: "Returned by /who listing online names; %@ is the comma-separated name list"),
                locale: .current,
                list
            )
        }
        static func namedUsage(_ command: String) -> String {
            String(
                format: String(localized: "command.usage.named", defaultValue: "usage: /%@ <nickname>", comment: "Usage for commands that take a nickname; %@ is the command name without slash"),
                locale: .current,
                command
            )
        }
        static func emoteNotFound(command: String, nickname: String) -> String {
            String(
                format: String(localized: "command.error.emote.not_found", defaultValue: "cannot %@ %@: not found", comment: "Returned by /hug or /slap when target is not found; first %@ is command, second %@ is nickname"),
                locale: .current,
                command,
                nickname
            )
        }
        static var listNone: String {
            String(localized: "command.list.none", defaultValue: "none", comment: "Placeholder when a /block listing has no entries")
        }
        static func blockList(mesh: String, geo: String) -> String {
            String(
                format: String(localized: "command.success.block.list", defaultValue: "blocked peers: %@ | geohash blocks: %@", comment: "Returned by /block with no args; first %@ is mesh list, second %@ is geohash list"),
                locale: .current,
                mesh,
                geo
            )
        }
        static func blockAlready(_ nickname: String) -> String {
            String(
                format: String(localized: "command.success.block.already", defaultValue: "%@ is already blocked", comment: "Returned when blocking someone already blocked; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
        static func blockMesh(_ nickname: String) -> String {
            String(
                format: String(localized: "command.success.block.mesh", defaultValue: "blocked %@. you will no longer receive messages from them", comment: "Success after blocking a mesh peer; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
        static func blockGeohash(_ nickname: String) -> String {
            String(
                format: String(localized: "command.success.block.geohash", defaultValue: "blocked %@ in geohash chats", comment: "Success after blocking a geohash participant; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
        static func blockNotFound(_ nickname: String) -> String {
            String(
                format: String(localized: "command.error.block.not_found", defaultValue: "cannot block %@: not found or unable to verify identity", comment: "Returned when /block target cannot be resolved; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
        static var unblockUsage: String {
            String(localized: "command.usage.unblock", defaultValue: "usage: /unblock <nickname>", comment: "Usage hint when /unblock has no nickname argument")
        }
        static func unblockNotBlocked(_ nickname: String) -> String {
            String(
                format: String(localized: "command.success.unblock.not_blocked", defaultValue: "%@ is not blocked", comment: "Returned when unblocking someone who is not blocked; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
        static func unblockMesh(_ nickname: String) -> String {
            String(
                format: String(localized: "command.success.unblock.mesh", defaultValue: "unblocked %@", comment: "Success after unblocking a mesh peer; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
        static func unblockGeohash(_ nickname: String) -> String {
            String(
                format: String(localized: "command.success.unblock.geohash", defaultValue: "unblocked %@ in geohash chats", comment: "Success after unblocking a geohash participant; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
        static func unblockNotFound(_ nickname: String) -> String {
            String(
                format: String(localized: "command.error.unblock.not_found", defaultValue: "cannot unblock %@: not found", comment: "Returned when /unblock target cannot be resolved; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
        static var groupUsage: String {
            String(localized: "command.usage.group", defaultValue: "usage: /group create <name> · invite @name · remove @name · leave · list", comment: "Usage for /group when subcommand is missing or unknown")
        }
        static func meshNotFound(command: String, nickname: String) -> String {
            String(
                format: String(localized: "command.error.mesh.not_found", defaultValue: "cannot %@ %@: not found on mesh", comment: "Returned by /ping or /trace when peer is not found on mesh; first %@ is command, second %@ is nickname"),
                locale: .current,
                command,
                nickname
            )
        }
        static func pingPinging(_ nickname: String) -> String {
            String(
                format: String(localized: "command.success.ping.pinging", defaultValue: "pinging %@…", comment: "Immediate success after sending a mesh ping; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
        static func pingNoReply(_ nickname: String) -> String {
            String(
                format: String(localized: "command.success.ping.no_reply", defaultValue: "no reply from %@", comment: "Async ping timeout output; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
        static func pingPong(nickname: String, rttMs: Int, hopText: String) -> String {
            String(
                format: String(localized: "command.success.ping.pong", defaultValue: "pong from %1$@: %2$lld ms%3$@", comment: "Async ping success output; %1$@ is nickname, %2$lld is RTT ms, %3$@ is hop suffix"),
                locale: .current,
                nickname,
                Int64(rttMs),
                hopText
            )
        }
        static var pingHopDirect: String {
            String(localized: "command.success.ping.hop_direct", defaultValue: " · direct (1 hop)", comment: "Hop suffix for a direct 1-hop pong")
        }
        static func pingHopMany(_ hops: Int) -> String {
            String(
                format: String(localized: "command.success.ping.hop_many", defaultValue: " · %lld hops", comment: "Hop suffix for multi-hop pong; %lld is hop count"),
                locale: .current,
                Int64(hops)
            )
        }
        static func traceNoPath(_ nickname: String) -> String {
            String(
                format: String(localized: "command.success.trace.no_path", defaultValue: "no known path to %@", comment: "Returned by /trace when no mesh path is known; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
        static func tracePath(chain: String, hops: Int) -> String {
            if hops == 1 {
                return String(
                    format: String(localized: "command.success.trace.path_one", defaultValue: "estimated path: %@ (%lld hop)", comment: "Estimated mesh path with one hop; %@ is chain, %lld is hop count"),
                    locale: .current,
                    chain,
                    Int64(hops)
                )
            }
            return String(
                format: String(localized: "command.success.trace.path_other", defaultValue: "estimated path: %@ (%lld hops)", comment: "Estimated mesh path with multiple hops; %@ is chain, %lld is hop count"),
                locale: .current,
                chain,
                Int64(hops)
            )
        }
        static var payUsage: String {
            String(localized: "command.usage.pay", defaultValue: "usage: /pay <token> — paste a cashu token: /pay cashuA…", comment: "Usage/help returned by /pay with no token argument")
        }
        static var payNotToken: String {
            String(localized: "command.error.pay.not_token", defaultValue: "that doesn't look like a cashu token — expected cashuA… or cashuB…", comment: "Returned when /pay argument does not look like a cashu token")
        }
        static var payInvalid: String {
            String(localized: "command.error.pay.invalid", defaultValue: "invalid cashu token — it doesn't decode to a known token with an amount, not sending it", comment: "Returned when /pay token fails to decode")
        }
        static func paySentPrivate(_ summary: String) -> String {
            String(
                format: String(localized: "command.success.pay.sent_private", defaultValue: "sent %@ — cashu is a bearer token; whoever redeems it first gets the funds", comment: "Success after sending a cashu token privately; %@ is amount summary"),
                locale: .current,
                summary
            )
        }
        static var payPublicConfirm: String {
            String(localized: "command.error.pay.public_confirm", defaultValue: "this is a public channel — anyone reading it can redeem the token. send anyway: /pay <token> public", comment: "Returned when /pay is used publicly without confirmation suffix")
        }
        static func paySentPublic(_ summary: String) -> String {
            String(
                format: String(localized: "command.success.pay.sent_public", defaultValue: "sent %@ to the public channel — anyone here can redeem it", comment: "Success after sending a cashu token publicly; %@ is amount summary"),
                locale: .current,
                summary
            )
        }
        static func favoriteNotFound(_ nickname: String) -> String {
            String(
                format: String(localized: "command.error.favorite.not_found", defaultValue: "can't find peer: %@", comment: "Returned by /fav or /unfav when peer cannot be resolved; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
        static func favoriteAlready(_ nickname: String) -> String {
            String(
                format: String(localized: "command.success.favorite.already", defaultValue: "%@ is already a favorite", comment: "Returned by /fav when already favorited; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
        static func favoriteNotFavorite(_ nickname: String) -> String {
            String(
                format: String(localized: "command.success.favorite.not_favorite", defaultValue: "%@ is not a favorite", comment: "Returned by /unfav when not a favorite; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
        static func favoriteAdded(_ nickname: String) -> String {
            String(
                format: String(localized: "command.success.favorite.added", defaultValue: "added %@ to favorites", comment: "Success after adding a favorite; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
        static func favoriteRemoved(_ nickname: String) -> String {
            String(
                format: String(localized: "command.success.favorite.removed", defaultValue: "removed %@ from favorites", comment: "Success after removing a favorite; %@ is the nickname"),
                locale: .current,
                nickname
            )
        }
    }
}
