import BitFoundation
import Foundation
import SwiftUI

@MainActor
final class ChatMessageFormatter {
    typealias Patterns = MessageFormattingEngine.Patterns

    private unowned let viewModel: ChatViewModel
    private let meshPalette = MinimalDistancePalette(config: .mesh)
    private let nostrPalette = MinimalDistancePalette(config: .nostr)

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    func formatMessageAsText(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        let isSelf: Bool = {
            if let spid = message.senderPeerID {
                if case .location(let channel) = viewModel.activeChannel, spid.isGeoChat {
                    let myGeo: NostrIdentity? = {
                        if let cached = viewModel.cachedGeohashIdentity, cached.geohash == channel.geohash {
                            return cached.identity
                        }
                        if let identity = try? viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash) {
                            viewModel.cachedGeohashIdentity = (channel.geohash, identity)
                            return identity
                        }
                        return nil
                    }()
                    if let myGeo {
                        return spid == PeerID(nostr: myGeo.publicKeyHex)
                    }
                }
                return spid == viewModel.meshService.myPeerID
            }
            if message.sender == viewModel.nickname { return true }
            if message.sender.hasPrefix(viewModel.nickname + "#") { return true }
            return false
        }()

        let isDark = colorScheme == .dark
        if let cachedText = message.getCachedFormattedText(isDark: isDark, isSelf: isSelf) {
            return cachedText
        }

        var result = AttributedString()
        let baseColor: Color = isSelf ? .orange : peerColor(for: message, isDark: isDark)

        if message.sender != "system" {
            let (baseName, suffix) = message.sender.splitSuffix()
            var senderStyle = AttributeContainer()
            senderStyle.foregroundColor = baseColor
            let fontWeight: Font.Weight = isSelf ? .bold : .medium
            senderStyle.font = .bitchatSystem(size: 14, weight: fontWeight, design: .monospaced)
            if let spid = message.senderPeerID,
               let url = URL(string: "bitchat://user/\(spid.toPercentEncoded())") {
                senderStyle.link = url
            }

            result.append(AttributedString("<@").mergingAttributes(senderStyle))
            result.append(AttributedString(baseName).mergingAttributes(senderStyle))
            if !suffix.isEmpty {
                var suffixStyle = senderStyle
                suffixStyle.foregroundColor = baseColor.opacity(0.6)
                result.append(AttributedString(suffix).mergingAttributes(suffixStyle))
            }
            result.append(AttributedString("> ").mergingAttributes(senderStyle))

            let content = message.content
            let nsContent = content as NSString
            let nsLen = nsContent.length
            let containsCashuEarly: Bool = {
                let regex = Patterns.quickCashuPresence
                return regex.numberOfMatches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) > 0
            }()

            if (content.count > 4000 || content.hasVeryLongToken(threshold: 1024)) && !containsCashuEarly {
                var plainStyle = AttributeContainer()
                plainStyle.foregroundColor = baseColor
                plainStyle.font = isSelf
                    ? .bitchatSystem(size: 14, weight: .bold, design: .monospaced)
                    : .bitchatSystem(size: 14, design: .monospaced)
                result.append(AttributedString(content).mergingAttributes(plainStyle))
            } else {
                let hashtagRegex = Patterns.hashtag
                let mentionRegex = Patterns.mention
                let cashuRegex = Patterns.cashu
                let bolt11Regex = Patterns.bolt11
                let lnurlRegex = Patterns.lnurl
                let lightningSchemeRegex = Patterns.lightningScheme
                let detector = Patterns.linkDetector
                let hasMentionsHint = content.contains("@")
                let hasHashtagsHint = content.contains("#")
                let hasURLHint = content.contains("://") || content.contains("www.") || content.contains("http")
                let hasLightningHint = content.lowercased().contains("ln") || content.lowercased().contains("lightning:")
                let hasCashuHint = content.lowercased().contains("cashu")

                let hashtagMatches = hasHashtagsHint
                    ? hashtagRegex.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen))
                    : []
                let mentionMatches = hasMentionsHint
                    ? mentionRegex.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen))
                    : []
                let urlMatches = hasURLHint
                    ? (detector?.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) ?? [])
                    : []
                let cashuMatches = hasCashuHint
                    ? cashuRegex.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen))
                    : []
                let lightningMatches = hasLightningHint
                    ? lightningSchemeRegex.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen))
                    : []
                let bolt11Matches = hasLightningHint
                    ? bolt11Regex.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen))
                    : []
                let lnurlMatches = hasLightningHint
                    ? lnurlRegex.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen))
                    : []

                let mentionRanges = mentionMatches.map { $0.range(at: 0) }
                func overlapsMention(_ range: NSRange) -> Bool {
                    for mentionRange in mentionRanges where NSIntersectionRange(range, mentionRange).length > 0 {
                        return true
                    }
                    return false
                }

                func attachedToMention(_ range: NSRange) -> Bool {
                    if let swiftRange = Range(range, in: content), swiftRange.lowerBound > content.startIndex {
                        var index = content.index(before: swiftRange.lowerBound)
                        while true {
                            let character = content[index]
                            if character.isWhitespace || character.isNewline { break }
                            if character == "@" { return true }
                            if index == content.startIndex { break }
                            index = content.index(before: index)
                        }
                    }
                    return false
                }

                func isStandaloneHashtag(_ range: NSRange) -> Bool {
                    guard let swiftRange = Range(range, in: content) else { return false }
                    if swiftRange.lowerBound == content.startIndex { return true }
                    let previous = content.index(before: swiftRange.lowerBound)
                    return content[previous].isWhitespace || content[previous].isNewline
                }

                var allMatches: [(range: NSRange, type: String)] = []
                for match in hashtagMatches
                where !overlapsMention(match.range(at: 0))
                    && !attachedToMention(match.range(at: 0))
                    && isStandaloneHashtag(match.range(at: 0)) {
                    allMatches.append((match.range(at: 0), "hashtag"))
                }
                for match in mentionMatches {
                    allMatches.append((match.range(at: 0), "mention"))
                }
                for match in urlMatches where !overlapsMention(match.range) {
                    allMatches.append((match.range, "url"))
                }
                for match in cashuMatches where !overlapsMention(match.range(at: 0)) {
                    allMatches.append((match.range(at: 0), "cashu"))
                }
                for match in lightningMatches where !overlapsMention(match.range(at: 0)) {
                    allMatches.append((match.range(at: 0), "lightning"))
                }

                let occupied = urlMatches.map(\.range) + lightningMatches.map { $0.range(at: 0) }
                func overlapsOccupied(_ range: NSRange) -> Bool {
                    for occupiedRange in occupied where NSIntersectionRange(range, occupiedRange).length > 0 {
                        return true
                    }
                    return false
                }

                for match in bolt11Matches
                where !overlapsMention(match.range(at: 0)) && !overlapsOccupied(match.range(at: 0)) {
                    allMatches.append((match.range(at: 0), "bolt11"))
                }
                for match in lnurlMatches
                where !overlapsMention(match.range(at: 0)) && !overlapsOccupied(match.range(at: 0)) {
                    allMatches.append((match.range(at: 0), "lnurl"))
                }
                allMatches.sort { $0.range.location < $1.range.location }

                var lastEnd = content.startIndex
                let isMentioned = message.mentions?.contains(viewModel.nickname) ?? false

                for (range, type) in allMatches {
                    guard let swiftRange = Range(range, in: content) else { continue }

                    if lastEnd < swiftRange.lowerBound {
                        let beforeText = String(content[lastEnd..<swiftRange.lowerBound])
                        if !beforeText.isEmpty {
                            var beforeStyle = AttributeContainer()
                            beforeStyle.foregroundColor = baseColor
                            beforeStyle.font = isSelf
                                ? .bitchatSystem(size: 14, weight: .bold, design: .monospaced)
                                : .bitchatSystem(size: 14, design: .monospaced)
                            if isMentioned {
                                beforeStyle.font = beforeStyle.font?.bold()
                            }
                            result.append(AttributedString(beforeText).mergingAttributes(beforeStyle))
                        }
                    }

                    let matchText = String(content[swiftRange])
                    if type == "mention" {
                        let (mentionBase, mentionSuffix) = matchText.splitSuffix()
                        let mySuffix: String? = {
                            if case .location(let channel) = viewModel.activeChannel,
                               let identity = try? viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash) {
                                return String(identity.publicKeyHex.suffix(4))
                            }
                            return String(viewModel.meshService.myPeerID.id.prefix(4))
                        }()
                        let isMentionToMe: Bool = {
                            if mentionBase == viewModel.nickname {
                                if let mySuffix, !mentionSuffix.isEmpty {
                                    return mentionSuffix == "#\(mySuffix)"
                                }
                                return mentionSuffix.isEmpty
                            }
                            return false
                        }()

                        var mentionStyle = AttributeContainer()
                        mentionStyle.font = .bitchatSystem(
                            size: 14,
                            weight: isSelf ? .bold : .semibold,
                            design: .monospaced
                        )
                        let mentionColor: Color = isMentionToMe ? .orange : baseColor
                        mentionStyle.foregroundColor = mentionColor
                        let at = "@"
                        result.append(AttributedString("\(at)").mergingAttributes(mentionStyle))
                        result.append(AttributedString(mentionBase).mergingAttributes(mentionStyle))
                        if !mentionSuffix.isEmpty {
                            var lightStyle = mentionStyle
                            lightStyle.foregroundColor = mentionColor.opacity(0.6)
                            result.append(AttributedString(mentionSuffix).mergingAttributes(lightStyle))
                        }
                    } else if type == "hashtag" {
                        let token = String(matchText.dropFirst()).lowercased()
                        let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
                        let isGeohash = (2...12).contains(token.count) && token.allSatisfy { allowed.contains($0) }
                        let attachedToMentionToken: Bool = {
                            if swiftRange.lowerBound > content.startIndex {
                                var index = content.index(before: swiftRange.lowerBound)
                                while true {
                                    let character = content[index]
                                    if character.isWhitespace || character.isNewline { break }
                                    if character == "@" { return true }
                                    if index == content.startIndex { break }
                                    index = content.index(before: index)
                                }
                            }
                            return false
                        }()
                        let standalone: Bool = {
                            if swiftRange.lowerBound == content.startIndex { return true }
                            let previous = content.index(before: swiftRange.lowerBound)
                            return content[previous].isWhitespace || content[previous].isNewline
                        }()

                        var tagStyle = AttributeContainer()
                        tagStyle.font = isSelf
                            ? .bitchatSystem(size: 14, weight: .bold, design: .monospaced)
                            : .bitchatSystem(size: 14, design: .monospaced)
                        tagStyle.foregroundColor = baseColor
                        if isGeohash && !attachedToMentionToken && standalone,
                           let url = URL(string: "bitchat://geohash/\(token)") {
                            tagStyle.link = url
                            tagStyle.underlineStyle = .single
                        }
                        result.append(AttributedString(matchText).mergingAttributes(tagStyle))
                    } else if type == "cashu" || type == "lightning" || type == "bolt11" || type == "lnurl" {
                        var spacer = AttributeContainer()
                        spacer.foregroundColor = baseColor
                        spacer.font = isSelf
                            ? .bitchatSystem(size: 14, weight: .bold, design: .monospaced)
                            : .bitchatSystem(size: 14, design: .monospaced)
                        result.append(AttributedString(" ").mergingAttributes(spacer))
                    } else {
                        var matchStyle = AttributeContainer()
                        matchStyle.font = .bitchatSystem(
                            size: 14,
                            weight: isSelf ? .bold : .semibold,
                            design: .monospaced
                        )
                        if type == "url" {
                            matchStyle.foregroundColor = isSelf ? .orange : .blue
                            matchStyle.underlineStyle = .single
                            if let url = URL(string: matchText) {
                                matchStyle.link = url
                            }
                        }
                        result.append(AttributedString(matchText).mergingAttributes(matchStyle))
                    }

                    if lastEnd < swiftRange.upperBound {
                        lastEnd = swiftRange.upperBound
                    }
                }

                if lastEnd < content.endIndex {
                    let remainingText = String(content[lastEnd...])
                    var remainingStyle = AttributeContainer()
                    remainingStyle.foregroundColor = baseColor
                    remainingStyle.font = isSelf
                        ? .bitchatSystem(size: 14, weight: .bold, design: .monospaced)
                        : .bitchatSystem(size: 14, design: .monospaced)
                    if isMentioned {
                        remainingStyle.font = remainingStyle.font?.bold()
                    }
                    result.append(AttributedString(remainingText).mergingAttributes(remainingStyle))
                }
            }

            let timestamp = AttributedString(" [\(message.formattedTimestamp)]")
            var timestampStyle = AttributeContainer()
            timestampStyle.foregroundColor = Color.gray.opacity(0.7)
            timestampStyle.font = .bitchatSystem(size: 10, design: .monospaced)
            result.append(timestamp.mergingAttributes(timestampStyle))
        } else {
            var contentStyle = AttributeContainer()
            contentStyle.foregroundColor = Color.gray
            let content = AttributedString("* \(message.content) *")
            contentStyle.font = .bitchatSystem(size: 12, design: .monospaced).italic()
            result.append(content.mergingAttributes(contentStyle))

            let timestamp = AttributedString(" [\(message.formattedTimestamp)]")
            var timestampStyle = AttributeContainer()
            timestampStyle.foregroundColor = Color.gray.opacity(0.5)
            timestampStyle.font = .bitchatSystem(size: 10, design: .monospaced)
            result.append(timestamp.mergingAttributes(timestampStyle))
        }

        message.setCachedFormattedText(result, isDark: isDark, isSelf: isSelf)
        return result
    }

    func formatMessageHeader(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        let isSelf: Bool = {
            if let spid = message.senderPeerID {
                if case .location(let channel) = viewModel.activeChannel, spid.id.hasPrefix("nostr:"),
                   let myGeo = try? viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash) {
                    return spid == PeerID(nostr: myGeo.publicKeyHex)
                }
                return spid == viewModel.meshService.myPeerID
            }
            if message.sender == viewModel.nickname { return true }
            if message.sender.hasPrefix(viewModel.nickname + "#") { return true }
            return false
        }()

        let isDark = colorScheme == .dark
        let baseColor: Color = isSelf ? .orange : peerColor(for: message, isDark: isDark)

        if message.sender == "system" {
            var style = AttributeContainer()
            style.foregroundColor = baseColor
            style.font = .bitchatSystem(size: 14, weight: .medium, design: .monospaced)
            return AttributedString(message.sender).mergingAttributes(style)
        }

        var result = AttributedString()
        let (baseName, suffix) = message.sender.splitSuffix()
        var senderStyle = AttributeContainer()
        senderStyle.foregroundColor = baseColor
        senderStyle.font = .bitchatSystem(size: 14, weight: isSelf ? .bold : .medium, design: .monospaced)
        if let spid = message.senderPeerID,
           let url = URL(string: "bitchat://user/\(spid.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? spid.id)") {
            senderStyle.link = url
        }

        result.append(AttributedString("<@").mergingAttributes(senderStyle))
        result.append(AttributedString(baseName).mergingAttributes(senderStyle))
        if !suffix.isEmpty {
            var suffixStyle = senderStyle
            suffixStyle.foregroundColor = baseColor.opacity(0.6)
            result.append(AttributedString(suffix).mergingAttributes(suffixStyle))
        }
        result.append(AttributedString("> ").mergingAttributes(senderStyle))
        return result
    }

    func isSelfMessage(_ message: BitchatMessage) -> Bool {
        if let spid = message.senderPeerID {
            if case .location(let channel) = viewModel.activeChannel, spid.isGeoChat {
                let myGeo: NostrIdentity? = {
                    if let cached = viewModel.cachedGeohashIdentity, cached.geohash == channel.geohash {
                        return cached.identity
                    }
                    if let identity = try? viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash) {
                        viewModel.cachedGeohashIdentity = (channel.geohash, identity)
                        return identity
                    }
                    return nil
                }()
                if let myGeo {
                    return spid == PeerID(nostr: myGeo.publicKeyHex)
                }
            }
            return spid == viewModel.meshService.myPeerID
        }
        if message.sender == viewModel.nickname { return true }
        if message.sender.hasPrefix(viewModel.nickname + "#") { return true }
        return false
    }

    func senderColor(for message: BitchatMessage, isDark: Bool) -> Color {
        peerColor(for: message, isDark: isDark)
    }

    func peerURL(for peerID: PeerID) -> URL? {
        URL(string: "bitchat://user/\(peerID.toPercentEncoded())")
    }

    func colorForNostrPubkey(_ pubkeyHexLowercased: String, isDark: Bool) -> Color {
        getNostrPaletteColor(for: pubkeyHexLowercased.lowercased(), isDark: isDark)
    }

    func colorForMeshPeer(id peerID: PeerID, isDark: Bool) -> Color {
        getPeerPaletteColor(for: peerID, isDark: isDark)
    }
}

private extension ChatMessageFormatter {
    func peerColor(for message: BitchatMessage, isDark: Bool) -> Color {
        if let spid = message.senderPeerID {
            if spid.isGeoChat || spid.isGeoDM {
                let full = viewModel.nostrKeyMapping[spid]?.lowercased() ?? spid.bare.lowercased()
                return getNostrPaletteColor(for: full, isDark: isDark)
            } else if spid.id.count == 16 {
                return getPeerPaletteColor(for: spid, isDark: isDark)
            } else {
                return getPeerPaletteColor(for: PeerID(str: spid.id.lowercased()), isDark: isDark)
            }
        }
        return Color(peerSeed: message.sender.lowercased(), isDark: isDark)
    }

    func meshSeed(for peerID: PeerID) -> String {
        if let full = viewModel.cachedStablePeerID(for: peerID)?.id.lowercased() {
            return "noise:" + full
        }
        return peerID.id.lowercased()
    }

    func getPeerPaletteColor(for peerID: PeerID, isDark: Bool) -> Color {
        if peerID == viewModel.meshService.myPeerID {
            return .orange
        }

        meshPalette.ensurePalette(for: currentMeshPaletteSeeds())
        if let color = meshPalette.color(for: peerID.id, isDark: isDark) {
            return color
        }
        return Color(peerSeed: meshSeed(for: peerID), isDark: isDark)
    }

    func currentMeshPaletteSeeds() -> [String: String] {
        let myID = viewModel.meshService.myPeerID
        var seeds: [String: String] = [:]
        for peer in viewModel.allPeers where peer.peerID != myID {
            seeds[peer.peerID.id] = meshSeed(for: peer.peerID)
        }
        return seeds
    }

    func getNostrPaletteColor(for pubkeyHexLowercased: String, isDark: Bool) -> Color {
        let myHex = currentGeohashIdentityHex()
        if let myHex, pubkeyHexLowercased == myHex {
            return .orange
        }

        nostrPalette.ensurePalette(for: currentNostrPaletteSeeds(excluding: myHex))
        if let color = nostrPalette.color(for: pubkeyHexLowercased, isDark: isDark) {
            return color
        }
        return Color(peerSeed: "nostr:" + pubkeyHexLowercased, isDark: isDark)
    }

    func currentNostrPaletteSeeds(excluding myHex: String?) -> [String: String] {
        var seeds: [String: String] = [:]
        let excluded = myHex ?? ""
        for person in viewModel.visibleGeohashPeople() where person.id != excluded {
            seeds[person.id] = "nostr:" + person.id
        }
        return seeds
    }

    func currentGeohashIdentityHex() -> String? {
        if case .location(let channel) = viewModel.activeChannel,
           let identity = try? viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash) {
            return identity.publicKeyHex.lowercased()
        }
        return nil
    }
}
