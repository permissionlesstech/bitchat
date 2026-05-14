import BitFoundation
import Foundation

@MainActor
final class ChatComposerCoordinator {
    private unowned let viewModel: ChatViewModel

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    func updateAutocomplete(for text: String, cursorPosition: Int) {
        let peerCandidates = autocompleteCandidates()
        let (suggestions, range) = viewModel.autocompleteService.getSuggestions(
            for: text,
            peers: peerCandidates,
            cursorPosition: cursorPosition
        )

        if !suggestions.isEmpty {
            viewModel.autocompleteSuggestions = suggestions
            viewModel.autocompleteRange = range
            viewModel.showAutocomplete = true
            viewModel.selectedAutocompleteIndex = 0
        } else {
            viewModel.autocompleteSuggestions = []
            viewModel.autocompleteRange = nil
            viewModel.showAutocomplete = false
            viewModel.selectedAutocompleteIndex = 0
        }
    }

    func completeNickname(_ nickname: String, in text: inout String) -> Int {
        guard let range = viewModel.autocompleteRange else { return text.count }

        text = viewModel.autocompleteService.applySuggestion(nickname, to: text, range: range)

        viewModel.showAutocomplete = false
        viewModel.autocompleteSuggestions = []
        viewModel.autocompleteRange = nil
        viewModel.selectedAutocompleteIndex = 0

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

        let peerNicknames = viewModel.meshService.getPeerNicknames()
        var validTokens = Set(peerNicknames.values)
        validTokens.insert(viewModel.nickname)
        validTokens.insert(viewModel.nickname + "#" + String(viewModel.meshService.myPeerID.id.prefix(4)))

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
        switch viewModel.activeChannel {
        case .mesh:
            let values = viewModel.meshService.getPeerNicknames().values
            return Array(values.filter { $0 != viewModel.meshService.myNickname })

        case .location(let channel):
            var tokens = Set<String>()
            for (pubkey, nick) in viewModel.geoNicknames {
                tokens.insert("\(nick)#\(pubkey.suffix(4))")
            }
            if let identity = try? viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash) {
                let myToken = viewModel.nickname + "#" + String(identity.publicKeyHex.suffix(4))
                tokens.remove(myToken)
            }
            return Array(tokens)
        }
    }
}
