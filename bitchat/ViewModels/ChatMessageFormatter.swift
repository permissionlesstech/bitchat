import BitFoundation
import Foundation
import SwiftUI

@MainActor
final class ChatMessageFormatter {
    typealias Patterns = MessageFormattingEngine.Patterns
    private static let allowedGeohashChars = Set("0123456789bcdefghjkmnpqrstuvwxyz")

    private unowned let viewModel: ChatViewModel
    private let meshPalette = MinimalDistancePalette(config: .mesh)
    private let nostrPalette = MinimalDistancePalette(config: .nostr)
    /// Memoized `PeerID(nostr:)` for the active geohash identity so formatting
    /// hundreds of rows avoids re-allocating a `PeerID` per message.
    private var cachedOwnGeoChatPeerID: (publicKey: Data, peerID: PeerID)?
    /// What the Nostr palette was last built from. Colors are looked up once
    /// per people-sheet row and per formatted geochat message, so the palette
    /// is rebuilt only when the roster's membership (or our own excluded
    /// key) changes rather than recomputing the roster on every lookup.
    private var nostrPaletteKey: NostrPaletteKey?
    /// What the mesh palette was last built from. Guarded by membership and
    /// stable-ID mapping revisions so looking up colors across N rows is O(N)
    /// instead of rebuilding the seed dictionary O(N²) times.
    private var meshPaletteKey: MeshPaletteKey?

    private struct NostrPaletteKey: Equatable {
        // periphery:ignore - read only via the synthesized Equatable
        // conformance (the rebuild check), which the indexer cannot
        // attribute.
        let membershipRevision: UInt64
        // periphery:ignore - see `membershipRevision`.
        let excludedHex: String?
    }

    private struct MeshPaletteKey: Equatable {
        // periphery:ignore - read only via the synthesized Equatable
        // conformance (the rebuild check), which the indexer cannot
        // attribute.
        let membershipRevision: UInt64
        // periphery:ignore - see `membershipRevision`.
        let stablePeerRevision: UInt64
        // periphery:ignore - see `membershipRevision`.
        let myPeerID: PeerID
    }

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    /// Panic-wipe hook: clears cached pre-wipe geohash identity and peer-ID
    /// color palettes from memory.
    func resetForPanic() {
        cachedOwnGeoChatPeerID = nil
        nostrPaletteKey = nil
        meshPaletteKey = nil
        meshPalette.reset()
        nostrPalette.reset()
    }

    func formatMessageAsText(_ message: BitchatMessage, colorScheme: ColorScheme, theme: AppTheme = .matrix) -> AttributedString {
        let design = theme.bodyFontDesign
        let isSelf = isSelfMessage(message)

        let isDark = colorScheme == .dark
        let isVerifiedSender = !isSelf && isVerifiedSender(of: message)
        let cacheVariant = theme.formatCacheVariant + (isVerifiedSender ? "-vf" : "")
        if let cachedText = message.getCachedFormattedText(isDark: isDark, isSelf: isSelf, variant: cacheVariant) {
            return cachedText
        }

        var result = AttributedString()
        let baseColor: Color = isSelf ? .orange : peerColor(for: message, isDark: isDark)

        if message.sender != "system" {
            let (baseName, suffix) = message.sender.splitSuffix()
            var senderStyle = AttributeContainer()
            senderStyle.foregroundColor = baseColor
            let fontWeight: Font.Weight = isSelf ? .bold : .medium
            senderStyle.font = .bitchatSystem(size: 14, weight: fontWeight, design: design)
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
            // Private rows render a filled SF Symbol seal beside the lock
            // (TextMessageView / MediaMessageView); skip the in-string ✓ there
            // so verified DMs don't show two markers.
            if isVerifiedSender, !message.isPrivate {
                appendVerifiedSeal(to: &result, baseColor: baseColor, design: design)
            }
            result.append(AttributedString("> ").mergingAttributes(senderStyle))

            let content = message.content

            if content.isOversizedForRichFormatting() {
                var plainStyle = AttributeContainer()
                plainStyle.foregroundColor = baseColor
                plainStyle.font = isSelf
                    ? .bitchatSystem(size: 14, weight: .bold, design: design)
                    : .bitchatSystem(size: 14, design: design)
                result.append(AttributedString(content).mergingAttributes(plainStyle))
            } else {
                // Single-pass UTF-8 scanner avoids allocating lowercased copies
                // and skips NSString bridging + all regex passes for plain chat
                // messages (the common case in crowded rooms).
                let hints = MessageFormattingEngine.scanContentHints(in: content)
                let isMentioned: Bool
                if let mentions = message.mentions, !mentions.isEmpty {
                    let myNickname = viewModel.nickname.normalizedNickname
                    isMentioned = mentions.contains { $0.normalizedNickname == myNickname }
                } else {
                    isMentioned = false
                }

                if !hints.any {
                    var plainStyle = AttributeContainer()
                    plainStyle.foregroundColor = baseColor
                    plainStyle.font = isSelf
                        ? .bitchatSystem(size: 14, weight: .bold, design: design)
                        : .bitchatSystem(size: 14, design: design)
                    if isMentioned {
                        plainStyle.font = plainStyle.font?.bold()
                    }
                    result.append(AttributedString(content).mergingAttributes(plainStyle))
                } else {
                    let nsContent = content as NSString
                    let fullRange = NSRange(location: 0, length: nsContent.length)

                    let hashtagMatches = hints.hasHashtags
                        ? Patterns.hashtag.matches(in: content, options: [], range: fullRange)
                        : []
                    let mentionMatches = hints.hasMentions
                        ? Patterns.mention.matches(in: content, options: [], range: fullRange)
                        : []
                    let urlMatches = hints.hasURLs
                        ? (Patterns.linkDetector?.matches(in: content, options: [], range: fullRange) ?? [])
                        : []
                    let cashuMatches = hints.hasCashu
                        ? Patterns.cashu.matches(in: content, options: [], range: fullRange)
                        : []
                    let lightningMatches = hints.hasLightning
                        ? Patterns.lightningScheme.matches(in: content, options: [], range: fullRange)
                        : []
                    let bolt11Matches = hints.hasLightning
                        ? Patterns.bolt11.matches(in: content, options: [], range: fullRange)
                        : []
                    let lnurlMatches = hints.hasLightning
                        ? Patterns.lnurl.matches(in: content, options: [], range: fullRange)
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

                    for (range, type) in allMatches {
                        guard let swiftRange = Range(range, in: content) else { continue }

                        if lastEnd < swiftRange.lowerBound {
                            let beforeText = String(content[lastEnd..<swiftRange.lowerBound])
                            if !beforeText.isEmpty {
                                var beforeStyle = AttributeContainer()
                                beforeStyle.foregroundColor = baseColor
                                beforeStyle.font = isSelf
                                    ? .bitchatSystem(size: 14, weight: .bold, design: design)
                                    : .bitchatSystem(size: 14, design: design)
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
                                   let identity = viewModel.geohashIdentity(for: channel.geohash) {
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
                                design: design
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
                            let isGeohash = (2...12).contains(token.count) && token.allSatisfy { Self.allowedGeohashChars.contains($0) }

                            var tagStyle = AttributeContainer()
                            tagStyle.font = isSelf
                                ? .bitchatSystem(size: 14, weight: .bold, design: design)
                                : .bitchatSystem(size: 14, design: design)
                            tagStyle.foregroundColor = baseColor
                            if isGeohash,
                               let url = URL(string: "bitchat://geohash/\(token)") {
                                tagStyle.link = url
                                tagStyle.underlineStyle = .single
                            }
                            result.append(AttributedString(matchText).mergingAttributes(tagStyle))
                        } else if type == "cashu" || type == "lightning" || type == "bolt11" || type == "lnurl" {
                            var spacer = AttributeContainer()
                            spacer.foregroundColor = baseColor
                            spacer.font = isSelf
                                ? .bitchatSystem(size: 14, weight: .bold, design: design)
                                : .bitchatSystem(size: 14, design: design)
                            result.append(AttributedString(" ").mergingAttributes(spacer))
                        } else {
                            var matchStyle = AttributeContainer()
                            matchStyle.font = .bitchatSystem(
                                size: 14,
                                weight: isSelf ? .bold : .semibold,
                                design: design
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
                            ? .bitchatSystem(size: 14, weight: .bold, design: design)
                            : .bitchatSystem(size: 14, design: design)
                        if isMentioned {
                            remainingStyle.font = remainingStyle.font?.bold()
                        }
                        result.append(AttributedString(remainingText).mergingAttributes(remainingStyle))
                    }
                }
            }

            let timestamp = AttributedString(" [\(message.formattedTimestamp)]")
            var timestampStyle = AttributeContainer()
            timestampStyle.foregroundColor = Color.gray.opacity(0.7)
            timestampStyle.font = .bitchatSystem(size: 10, design: design)
            result.append(timestamp.mergingAttributes(timestampStyle))
        } else {
            var contentStyle = AttributeContainer()
            contentStyle.foregroundColor = Color.gray
            let content = AttributedString("* \(message.content) *")
            contentStyle.font = .bitchatSystem(size: 12, design: design).italic()
            result.append(content.mergingAttributes(contentStyle))

            let timestamp = AttributedString(" [\(message.formattedTimestamp)]")
            var timestampStyle = AttributeContainer()
            timestampStyle.foregroundColor = Color.gray.opacity(0.5)
            timestampStyle.font = .bitchatSystem(size: 10, design: design)
            result.append(timestamp.mergingAttributes(timestampStyle))
        }

        message.setCachedFormattedText(result, isDark: isDark, isSelf: isSelf, variant: cacheVariant)
        return result
    }

    /// Prefix of the header's formatted-text cache variants. No full-text
    /// variant starts with it, so the two caches can't collide.
    static let headerCacheNamespace = "hdr:"

    func formatMessageHeader(_ message: BitchatMessage, colorScheme: ColorScheme, theme: AppTheme = .matrix) -> AttributedString {
        let design = theme.bodyFontDesign
        let isSelf = isSelfMessage(message)

        let isDark = colorScheme == .dark
        let isVerifiedSender = !isSelf && isVerifiedSender(of: message)
        // Same key ingredients as the full-text cache, in a namespace of its
        // own so a header and a full text never answer each other's lookups.
        let cacheVariant = Self.headerCacheNamespace + theme.formatCacheVariant + (isVerifiedSender ? "-vf" : "")
        if let cachedHeader = message.getCachedFormattedText(isDark: isDark, isSelf: isSelf, variant: cacheVariant) {
            return cachedHeader
        }

        let baseColor: Color = isSelf ? .orange : peerColor(for: message, isDark: isDark)

        if message.sender == "system" {
            var style = AttributeContainer()
            style.foregroundColor = baseColor
            style.font = .bitchatSystem(size: 14, weight: .medium, design: design)
            let header = AttributedString(message.sender).mergingAttributes(style)
            message.setCachedFormattedText(header, isDark: isDark, isSelf: isSelf, variant: cacheVariant)
            return header
        }

        var result = AttributedString()
        let (baseName, suffix) = message.sender.splitSuffix()
        var senderStyle = AttributeContainer()
        senderStyle.foregroundColor = baseColor
        senderStyle.font = .bitchatSystem(size: 14, weight: isSelf ? .bold : .medium, design: design)
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
        if isVerifiedSender, !message.isPrivate {
            appendVerifiedSeal(to: &result, baseColor: baseColor, design: design)
        }
        result.append(AttributedString("> ").mergingAttributes(senderStyle))
        message.setCachedFormattedText(result, isDark: isDark, isSelf: isSelf, variant: cacheVariant)
        return result
    }

    func isSelfMessage(_ message: BitchatMessage) -> Bool {
        if let spid = message.senderPeerID {
            if case .location(let channel) = viewModel.activeChannel, spid.isGeoChat {
                if let myGeo = viewModel.geohashIdentity(for: channel.geohash) {
                    let ownPeerID: PeerID
                    if let cached = cachedOwnGeoChatPeerID, cached.publicKey == myGeo.publicKey {
                        ownPeerID = cached.peerID
                    } else {
                        let derived = PeerID(nostr: myGeo.publicKeyHex)
                        cachedOwnGeoChatPeerID = (myGeo.publicKey, derived)
                        ownPeerID = derived
                    }
                    return spid == ownPeerID
                }
            }
            return spid == viewModel.meshService.myPeerID
        }
        if message.sender == viewModel.nickname { return true }
        if message.sender.hasPrefix(viewModel.nickname + "#") { return true }
        return false
    }

    func colorForNostrPubkey(_ pubkeyHexLowercased: String, isDark: Bool) -> Color {
        getNostrPaletteColor(for: pubkeyHexLowercased.lowercased(), isDark: isDark)
    }

    func colorForMeshPeer(id peerID: PeerID, isDark: Bool) -> Color {
        getPeerPaletteColor(for: peerID, isDark: isDark)
    }
}

private extension ChatMessageFormatter {
    /// Whether the message sender has a fingerprint the user has verified.
    /// Used for the in-chat seal next to `<@name>` so verification is visible
    /// without opening the fingerprint sheet (#1439).
    func isVerifiedSender(of message: BitchatMessage) -> Bool {
        guard let peerID = message.senderPeerID,
              let fingerprint = viewModel.getFingerprint(for: peerID) else {
            return false
        }
        return viewModel.peerIdentityStore.isVerified(fingerprint)
    }

    func appendVerifiedSeal(
        to result: inout AttributedString,
        baseColor: Color,
        design: Font.Design
    ) {
        var sealStyle = AttributeContainer()
        // Match the peer-list verified seal: filled checkmark in the sender tint.
        sealStyle.foregroundColor = baseColor
        sealStyle.font = .bitchatSystem(size: 11, weight: .semibold, design: design)
        result.append(AttributedString(" ✓").mergingAttributes(sealStyle))
    }

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

        ensureMeshPalette()
        if let color = meshPalette.color(for: peerID.id, isDark: isDark) {
            return color
        }
        return Color(peerSeed: meshSeed(for: peerID), isDark: isDark)
    }

    func ensureMeshPalette() {
        let myID = viewModel.meshService.myPeerID
        let key = MeshPaletteKey(
            membershipRevision: viewModel.meshPeerMembershipRevision,
            stablePeerRevision: viewModel.peerIdentityStore.stablePeerMappingRevision,
            myPeerID: myID
        )
        guard key != meshPaletteKey else { return }
        meshPaletteKey = key

        var seeds: [String: String] = [:]
        for peer in viewModel.allPeers where peer.peerID != myID {
            seeds[peer.peerID.id] = meshSeed(for: peer.peerID)
        }
        meshPalette.ensurePalette(for: seeds)
    }

    func getNostrPaletteColor(for pubkeyHexLowercased: String, isDark: Bool) -> Color {
        let myHex = currentGeohashIdentityHex()
        if let myHex, pubkeyHexLowercased == myHex {
            return .orange
        }

        ensureNostrPalette(excluding: myHex)
        if let color = nostrPalette.color(for: pubkeyHexLowercased, isDark: isDark) {
            return color
        }
        return Color(peerSeed: "nostr:" + pubkeyHexLowercased, isDark: isDark)
    }

    /// Seeds the palette from the tracker's published roster, and only when
    /// its membership changed. Rebuilding it from a fresh roster scan per
    /// lookup made every people-sheet render O(N²) in the participant count.
    func ensureNostrPalette(excluding myHex: String?) {
        let tracker = viewModel.participantTracker
        let key = NostrPaletteKey(
            membershipRevision: tracker.visibleMembershipRevision,
            excludedHex: myHex
        )
        guard key != nostrPaletteKey else { return }
        nostrPaletteKey = key

        var seeds: [String: String] = [:]
        let excluded = myHex ?? ""
        for person in tracker.visiblePeople where person.id != excluded {
            seeds[person.id] = "nostr:" + person.id
        }
        nostrPalette.ensurePalette(for: seeds)
    }

    func currentGeohashIdentityHex() -> String? {
        if case .location(let channel) = viewModel.activeChannel,
           let identity = viewModel.geohashIdentity(for: channel.geohash) {
            return identity.publicKeyHex.lowercased()
        }
        return nil
    }
}
