import BitFoundation
import Foundation

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
    var activeChannel: ChannelID { get }
    /// The transport's own nickname (excluded from autocomplete candidates).
    var meshNickname: String { get }
    func meshPeerNicknames() -> [PeerID: String]

    // MARK: Geohash identity (shared with the other contexts)
    var geoNicknames: [String: String] { get }
    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity
}

extension ChatViewModel: ChatComposerContext {
    // `autocompleteSuggestions`, `autocompleteRange`, `showAutocomplete`,
    // `selectedAutocompleteIndex`, `nickname`, `myPeerID`, `activeChannel`,
    // `geoNicknames`, `meshPeerNicknames()`, and
    // `deriveNostrIdentity(forGeohash:)` are shared requirements with the
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
}

@MainActor
final class ChatComposerCoordinator {
    private unowned let context: any ChatComposerContext

    init(context: any ChatComposerContext) {
        self.context = context
    }

    func updateAutocomplete(for text: String, cursorPosition: Int) {
        let peerCandidates = autocompleteCandidates()
        let (suggestions, range) = context.autocompleteQuery(
            for: text,
            peers: peerCandidates,
            cursorPosition: cursorPosition
        )

        if !suggestions.isEmpty {
            context.autocompleteSuggestions = suggestions
            context.autocompleteRange = range
            context.showAutocomplete = true
            context.selectedAutocompleteIndex = 0
        } else {
            context.autocompleteSuggestions = []
            context.autocompleteRange = nil
            context.showAutocomplete = false
            context.selectedAutocompleteIndex = 0
        }
    }

    func completeNickname(_ nickname: String, in text: inout String) -> Int {
        guard let range = context.autocompleteRange else { return text.count }

        text = context.applyAutocompleteSuggestion(nickname, to: text, range: range)

        context.showAutocomplete = false
        context.autocompleteSuggestions = []
        context.autocompleteRange = nil
        context.selectedAutocompleteIndex = 0

        return range.location + nickname.count + (nickname.hasPrefix("@") ? 1 : 2)
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
    func autocompleteCandidates() -> [String] {
        switch context.activeChannel {
        case .mesh:
            let values = context.meshPeerNicknames().values
            return Array(values.filter { $0 != context.meshNickname })

        case .location(let channel):
            var tokens = Set<String>()
            for (pubkey, nick) in context.geoNicknames {
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
