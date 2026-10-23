import BitFoundation
import Foundation

/// One composer's mention suggestions: what to offer, the range of the
/// typed text a pick replaces, and the highlighted row. A value the
/// composer keeps for itself, so two composers never share (or apply) each
/// other's suggestions.
struct ComposerAutocompleteState: Equatable {
    var suggestions: [String] = []
    var range: NSRange?
    var selectedIndex = 0

    var isShowing: Bool { !suggestions.isEmpty }
}

/// The narrow surface `ChatComposerCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`. This keeps the coordinator independently
/// testable (see `ChatComposerCoordinatorContextTests`) and makes its true
/// dependencies explicit.
@MainActor
protocol ChatComposerContext: AnyObject {
    // MARK: Autocomplete UI state
    var autocompleteSuggestions: [String] { get set }
    var autocompleteRange: NSRange? { get set }
    var showAutocomplete: Bool { get set }
    var selectedAutocompleteIndex: Int { get set }
    /// Computes mention suggestions for the text up to the cursor.
    func autocompleteQuery(
        for text: String,
        peers: [String],
        cursorPosition: Int
    ) -> (suggestions: [String], range: NSRange?)
    /// Replaces the matched range in `text` with the chosen suggestion.
    func applyAutocompleteSuggestion(_ suggestion: String, to text: String, range: NSRange) -> String

    // MARK: Identity & channel state
    var nickname: String { get }
    var myPeerID: PeerID { get }
    /// The selection: the published-state shim's target, and the geohash
    /// whose nicknames `geoNicknames` holds.
    var activeChannel: ChannelID { get }
    var selectedPrivateChatPeer: PeerID? { get }
    /// The transport's own nickname (excluded from autocomplete candidates).
    var meshNickname: String { get }
    func meshPeerNicknames() -> [PeerID: String]
    /// True when this mesh nickname belongs to a blocked peer.
    func isMeshNicknameBlocked(_ nickname: String) -> Bool
    /// True when this geohash pubkey is blocked for location chats.
    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool

    // MARK: Geohash identity (shared with the other contexts)
    var geoNicknames: [String: String] { get }
    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity
}

extension ChatViewModel: ChatComposerContext {
    // `autocompleteSuggestions`, `autocompleteRange`, `showAutocomplete`,
    // `selectedAutocompleteIndex`, `nickname`, `myPeerID`, `activeChannel`,
    // `selectedPrivateChatPeer`, `geoNicknames`, `meshPeerNicknames()`, `isNostrBlocked(pubkeyHexLowercased:)`,
    // and `deriveNostrIdentity(forGeohash:)` are shared requirements with the
    // other contexts or satisfied by existing `ChatViewModel` members. The
    // members below flatten nested service accesses into intent-named calls.

    func autocompleteQuery(
        for text: String,
        peers: [String],
        cursorPosition: Int
    ) -> (suggestions: [String], range: NSRange?) {
        autocompleteService.getSuggestions(for: text, peers: peers, cursorPosition: cursorPosition)
    }

    func applyAutocompleteSuggestion(_ suggestion: String, to text: String, range: NSRange) -> String {
        autocompleteService.applySuggestion(suggestion, to: text, range: range)
    }

    var meshNickname: String {
        meshService.myNickname
    }

    func isMeshNicknameBlocked(_ nickname: String) -> Bool {
        for (peerID, nick) in meshService.getPeerNicknames() where nick == nickname {
            if isPeerBlocked(peerID) { return true }
        }
        return false
    }
}

@MainActor
final class ChatComposerCoordinator {
    private unowned let context: any ChatComposerContext

    init(context: any ChatComposerContext) {
        self.context = context
    }

    /// Mention suggestions for `text` typed into `target`'s composer. Pure:
    /// it returns the composer's new state and changes nothing shared.
    func autocomplete(
        for text: String,
        cursorPosition: Int,
        in target: ConversationTarget
    ) -> ComposerAutocompleteState {
        // The query can only suggest for an @-token ending at the cursor, so
        // skip assembling the candidates (a pass over every mesh peer or
        // geohash participant) after each typing pause in plain text.
        guard AutocompleteService.hasMentionToken(in: text, cursorPosition: cursorPosition) else {
            return ComposerAutocompleteState()
        }

        let (suggestions, range) = context.autocompleteQuery(
            for: text,
            peers: autocompleteCandidates(in: target),
            cursorPosition: cursorPosition
        )
        guard !suggestions.isEmpty else { return ComposerAutocompleteState() }
        return ComposerAutocompleteState(suggestions: suggestions, range: range)
    }

    /// Replaces the range `state` matched with `suggestion` and returns the
    /// cursor position after it. Without a range the text is left alone.
    func complete(_ suggestion: String, in text: inout String, state: ComposerAutocompleteState) -> Int {
        guard let range = state.range else { return text.count }
        text = context.applyAutocompleteSuggestion(suggestion, to: text, range: range)
        return range.location + suggestion.count + (suggestion.hasPrefix("@") ? 1 : 2)
    }

    /// The commands to offer for `text` typed into `target`'s composer,
    /// matching what has been typed: `CommandInfo.all` for the target's own
    /// channel and DM, the inputs the processor gates on, instead of the
    /// selection's. Once arguments begin, only the typed command's usage row
    /// stays.
    nonisolated static func commandSuggestions(for text: String, in target: ConversationTarget) -> [CommandInfo] {
        guard text.hasPrefix("/") else { return [] }
        let commands = CommandInfo.all(
            isGeoPublic: target.channel.isLocation,
            isGeoDM: target.privatePeer?.isGeoDM == true
        )
        if let spaceIndex = text.firstIndex(of: " ") {
            let typed = String(text[..<spaceIndex]).lowercased()
            return commands.filter { $0.alias == typed && $0.placeholder != nil }
        }
        return commands.filter { $0.alias.starts(with: text.lowercased()) }
    }

    /// The selection's composer: computes for the selection's target and
    /// publishes the result on the shared state the single composer reads.
    func updateAutocomplete(for text: String, cursorPosition: Int) {
        let state = autocomplete(
            for: text,
            cursorPosition: cursorPosition,
            in: ConversationTarget(channel: context.activeChannel, privatePeer: context.selectedPrivateChatPeer)
        )
        setAutocompleteState(suggestions: state.suggestions, range: state.range)
    }

    /// `complete(_:in:state:)` against the shared published state, which it
    /// then clears.
    func completeNickname(_ nickname: String, in text: inout String) -> Int {
        let state = ComposerAutocompleteState(
            suggestions: context.autocompleteSuggestions,
            range: context.autocompleteRange
        )
        guard state.range != nil else { return text.count }
        let cursor = complete(nickname, in: &text, state: state)

        context.showAutocomplete = false
        context.autocompleteSuggestions = []
        context.autocompleteRange = nil
        context.selectedAutocompleteIndex = 0

        return cursor
    }

    func parseMentions(from content: String) -> [String] {
        let regex = ChatViewModel.Patterns.mention
        let nsContent = content as NSString
        let matches = regex.matches(
            in: content,
            options: [],
            range: NSRange(location: 0, length: nsContent.length)
        )

        let peerNicknames = context.meshPeerNicknames()
        var validTokens = Set(peerNicknames.values)
        validTokens.insert(context.nickname)
        validTokens.insert(context.nickname + "#" + String(context.myPeerID.id.prefix(4)))

        var mentions: [String] = []
        for match in matches {
            guard let range = Range(match.range(at: 1), in: content) else { continue }
            let mentionedName = String(content[range])
            if validTokens.contains(mentionedName) {
                mentions.append(mentionedName)
            }
        }

        return Array(Set(mentions))
    }
}

private extension ChatComposerCoordinator {
    /// Shows `suggestions` (hidden when empty) with the highlight reset to the
    /// first one. Writes only the properties that change: each write
    /// republishes the composer state, which re-renders every message row.
    func setAutocompleteState(suggestions: [String], range: NSRange?) {
        let isShown = !suggestions.isEmpty
        if context.autocompleteSuggestions != suggestions {
            context.autocompleteSuggestions = suggestions
        }
        if context.autocompleteRange != range {
            context.autocompleteRange = range
        }
        if context.showAutocomplete != isShown {
            context.showAutocomplete = isShown
        }
        if context.selectedAutocompleteIndex != 0 {
            context.selectedAutocompleteIndex = 0
        }
    }

    /// Who can be mentioned in `target`: mesh peers for #mesh and for mesh
    /// DMs and groups, whatever channel is selected; the participants of a
    /// geohash for that geohash and its DMs. Geohash names are only known
    /// for the selected geohash, so any other offers nobody.
    func autocompleteCandidates(in target: ConversationTarget) -> [String] {
        let isGeohashConversation = target.privatePeer.map { $0.isGeoDM || $0.isGeoChat }
            ?? target.channel.isLocation
        guard isGeohashConversation else {
            let values = context.meshPeerNicknames().values
            return Array(values.filter { nick in
                nick != context.meshNickname && !context.isMeshNicknameBlocked(nick)
            })
        }

        switch target.channel {
        case .mesh:
            return []

        case .location(let channel):
            guard target.channel.isLive(whileSelected: context.activeChannel) else {
                return []
            }
            var tokens = Set<String>()
            for (pubkey, nick) in context.geoNicknames {
                guard !context.isNostrBlocked(pubkeyHexLowercased: pubkey) else { continue }
                tokens.insert("\(nick)#\(pubkey.suffix(4))")
            }
            if let identity = try? context.deriveNostrIdentity(forGeohash: channel.geohash) {
                let myToken = context.nickname + "#" + String(identity.publicKeyHex.suffix(4))
                tokens.remove(myToken)
            }
            return Array(tokens)
        }
    }
}
