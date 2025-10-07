//
// MessageFormattingService.swift
// bitchat
//
// Service for formatting chat messages with syntax highlighting
// This is free and unencumbered software released into the public domain.
//

import Foundation
import SwiftUI

/// Service that formats BitchatMessages into styled AttributedStrings
/// Handles hashtags, mentions, links, payment tokens, and more
final class MessageFormattingService {

    // MARK: - Precompiled Regexes

    private enum Regexes {
        static let hashtag: NSRegularExpression = {
            try! NSRegularExpression(pattern: "#([a-zA-Z0-9_]+)", options: [])
        }()
        static let mention: NSRegularExpression = {
            try! NSRegularExpression(pattern: "@([\\p{L}0-9_]+(?:#[a-fA-F0-9]{4})?)", options: [])
        }()
        static let cashu: NSRegularExpression = {
            try! NSRegularExpression(pattern: "\\bcashu[AB][A-Za-z0-9._-]{40,}\\b", options: [])
        }()
        static let bolt11: NSRegularExpression = {
            try! NSRegularExpression(pattern: "(?i)\\bln(bc|tb|bcrt)[0-9][a-z0-9]{50,}\\b", options: [])
        }()
        static let lnurl: NSRegularExpression = {
            try! NSRegularExpression(pattern: "(?i)\\blnurl1[a-z0-9]{20,}\\b", options: [])
        }()
        static let lightningScheme: NSRegularExpression = {
            try! NSRegularExpression(pattern: "(?i)\\blightning:[^\\s]+", options: [])
        }()
        static let linkDetector: NSDataDetector? = {
            try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        }()
        static let quickCashuPresence: NSRegularExpression = {
            try! NSRegularExpression(pattern: "\\bcashu[AB][A-Za-z0-9._-]{40,}\\b", options: [])
        }()
    }

    // MARK: - Dependencies

    private let colorPalette: ColorPaletteService

    // MARK: - Initialization

    init(colorPalette: ColorPaletteService) {
        self.colorPalette = colorPalette
    }

    // MARK: - Public API

    /// Format a message with full syntax highlighting (hashtags, mentions, links, payments)
    /// This is the primary formatter used in the main chat view
    func formatMessageAsText(
        _ message: BitchatMessage,
        colorScheme: ColorScheme,
        nickname: String,
        myPeerID: String,
        myNostrPubkey: String?,
        activeChannel: ChannelID,
        nostrKeyMapping: [String: String],
        allPeers: [BitchatPeer],
        geohashPeople: [GeoPerson],
        getNoiseKeyForShortID: @escaping (String) -> String?
    ) -> AttributedString {
        // Determine if this message was sent by self
        let isSelf = isSelfMessage(
            message,
            nickname: nickname,
            myPeerID: myPeerID,
            myNostrPubkey: myNostrPubkey,
            activeChannel: activeChannel
        )

        // Check cache first
        let isDark = colorScheme == .dark
        if let cachedText = message.getCachedFormattedText(isDark: isDark, isSelf: isSelf) {
            return cachedText
        }

        // Not cached, format the message
        var result = AttributedString()

        let baseColor: Color = isSelf ? .orange : colorPalette.peerColor(
            for: message,
            isDark: isDark,
            myPeerID: myPeerID,
            myNostrPubkey: myNostrPubkey,
            nostrKeyMapping: nostrKeyMapping,
            allPeers: allPeers,
            geohashPeople: geohashPeople.map { (id: $0.id, seed: "nostr:" + $0.id) },
            getNoiseKeyForShortID: getNoiseKeyForShortID
        )

        if message.sender != "system" {
            // Sender (at the beginning) with light-gray suffix styling if present
            let (baseName, suffix) = message.sender.splitSuffix()
            var senderStyle = AttributeContainer()
            senderStyle.foregroundColor = baseColor
            let fontWeight: Font.Weight = isSelf ? .bold : .medium
            senderStyle.font = .bitchatSystem(size: 14, weight: fontWeight, design: .monospaced)

            // Make sender clickable: encode senderPeerID into a custom URL
            if let spid = message.senderPeerID?.id,
               let url = URL(string: "bitchat://user/\(spid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? spid)") {
                senderStyle.link = url
            }

            // Format: <@name#suffix>
            result.append(AttributedString("<@").mergingAttributes(senderStyle))
            result.append(AttributedString(baseName).mergingAttributes(senderStyle))
            if !suffix.isEmpty {
                var suffixStyle = senderStyle
                suffixStyle.foregroundColor = baseColor.opacity(0.6)
                result.append(AttributedString(suffix).mergingAttributes(suffixStyle))
            }
            result.append(AttributedString("> ").mergingAttributes(senderStyle))

            // Process content with syntax highlighting
            let content = message.content
            let nsContent = content as NSString
            let nsLen = nsContent.length

            // Check for Cashu presence early to decide rendering strategy
            let containsCashuEarly = Regexes.quickCashuPresence.numberOfMatches(
                in: content,
                options: [],
                range: NSRange(location: 0, length: nsLen)
            ) > 0

            // For extremely long content, render as plain text (unless has Cashu)
            if (content.count > 4000 || content.hasVeryLongToken(threshold: 1024)) && !containsCashuEarly {
                var plainStyle = AttributeContainer()
                plainStyle.foregroundColor = baseColor
                plainStyle.font = isSelf
                    ? .bitchatSystem(size: 14, weight: .bold, design: .monospaced)
                    : .bitchatSystem(size: 14, design: .monospaced)
                result.append(AttributedString(content).mergingAttributes(plainStyle))
            } else {
                // Full syntax highlighting
                result.append(formatContent(
                    content,
                    nsContent: nsContent,
                    nsLen: nsLen,
                    message: message,
                    baseColor: baseColor,
                    isSelf: isSelf,
                    isDark: isDark,
                    nickname: nickname,
                    myPeerID: myPeerID,
                    myNostrPubkey: myNostrPubkey,
                    activeChannel: activeChannel
                ))
            }

            // Add timestamp
            let timestamp = AttributedString(" [\(message.formattedTimestamp)]")
            var timestampStyle = AttributeContainer()
            timestampStyle.foregroundColor = Color.gray.opacity(0.7)
            timestampStyle.font = .bitchatSystem(size: 10, design: .monospaced)
            result.append(timestamp.mergingAttributes(timestampStyle))
        } else {
            // System message
            var contentStyle = AttributeContainer()
            contentStyle.foregroundColor = Color.gray
            let content = AttributedString("* \(message.content) *")
            contentStyle.font = .bitchatSystem(size: 12, design: .monospaced).italic()
            result.append(content.mergingAttributes(contentStyle))

            // Add timestamp
            let timestamp = AttributedString(" [\(message.formattedTimestamp)]")
            var timestampStyle = AttributeContainer()
            timestampStyle.foregroundColor = Color.gray.opacity(0.5)
            timestampStyle.font = .bitchatSystem(size: 10, design: .monospaced)
            result.append(timestamp.mergingAttributes(timestampStyle))
        }

        // Cache the formatted text
        message.setCachedFormattedText(result, isDark: isDark, isSelf: isSelf)

        return result
    }

    /// Simpler message formatter (used in legacy contexts)
    func formatMessage(
        _ message: BitchatMessage,
        colorScheme: ColorScheme,
        nickname: String
    ) -> AttributedString {
        var result = AttributedString()

        let isDark = colorScheme == .dark
        let primaryColor = isDark ? Color.green : Color(red: 0, green: 0.5, blue: 0)

        if message.sender == "system" {
            let content = AttributedString("* \(message.content) *")
            var contentStyle = AttributeContainer()
            contentStyle.foregroundColor = Color.gray
            contentStyle.font = .bitchatSystem(size: 12, design: .monospaced).italic()
            result.append(content.mergingAttributes(contentStyle))

            // Add timestamp
            let timestamp = AttributedString(" [\(message.formattedTimestamp)]")
            var timestampStyle = AttributeContainer()
            timestampStyle.foregroundColor = Color.gray.opacity(0.5)
            timestampStyle.font = .bitchatSystem(size: 10, design: .monospaced)
            result.append(timestamp.mergingAttributes(timestampStyle))
        } else {
            let sender = AttributedString("<@\(message.sender)> ")
            var senderStyle = AttributeContainer()
            senderStyle.foregroundColor = primaryColor
            let fontWeight: Font.Weight = message.sender == nickname ? .bold : .medium
            senderStyle.font = .bitchatSystem(size: 12, weight: fontWeight, design: .monospaced)
            result.append(sender.mergingAttributes(senderStyle))

            // Process content to highlight mentions
            let contentText = message.content
            let pattern = "@([\\p{L}0-9_]+)"
            let regex = try? NSRegularExpression(pattern: pattern, options: [])
            let nsContent = contentText as NSString
            let nsLen = nsContent.length
            let matches = regex?.matches(in: contentText, options: [], range: NSRange(location: 0, length: nsLen)) ?? []

            var processedContent = AttributedString()
            var lastEndIndex = contentText.startIndex

            for match in matches {
                if let range = Range(match.range(at: 0), in: contentText) {
                    // Add text before mention
                    if lastEndIndex < range.lowerBound {
                        let beforeText = String(contentText[lastEndIndex..<range.lowerBound])
                        if !beforeText.isEmpty {
                            var normalStyle = AttributeContainer()
                            normalStyle.font = .bitchatSystem(size: 14, design: .monospaced)
                            normalStyle.foregroundColor = isDark ? Color.white : Color.black
                            processedContent.append(AttributedString(beforeText).mergingAttributes(normalStyle))
                        }
                    }

                    // Add the mention with highlight
                    let mentionText = String(contentText[range])
                    var mentionStyle = AttributeContainer()
                    mentionStyle.font = .bitchatSystem(size: 14, weight: .semibold, design: .monospaced)
                    mentionStyle.foregroundColor = Color.orange
                    processedContent.append(AttributedString(mentionText).mergingAttributes(mentionStyle))

                    if lastEndIndex < range.upperBound { lastEndIndex = range.upperBound }
                }
            }

            // Add remaining text
            if lastEndIndex < contentText.endIndex {
                let remainingText = String(contentText[lastEndIndex...])
                var normalStyle = AttributeContainer()
                normalStyle.font = .bitchatSystem(size: 14, design: .monospaced)
                normalStyle.foregroundColor = isDark ? Color.white : Color.black
                processedContent.append(AttributedString(remainingText).mergingAttributes(normalStyle))
            }

            result.append(processedContent)

            if message.isRelay, let originalSender = message.originalSender {
                let relay = AttributedString(" (via \(originalSender))")
                var relayStyle = AttributeContainer()
                relayStyle.foregroundColor = primaryColor.opacity(0.7)
                relayStyle.font = .bitchatSystem(size: 11, design: .monospaced)
                result.append(relay.mergingAttributes(relayStyle))
            }

            // Add timestamp
            let timestamp = AttributedString(" [\(message.formattedTimestamp)]")
            var timestampStyle = AttributeContainer()
            timestampStyle.foregroundColor = Color.gray.opacity(0.7)
            timestampStyle.font = .bitchatSystem(size: 10, design: .monospaced)
            result.append(timestamp.mergingAttributes(timestampStyle))
        }

        return result
    }

    // MARK: - Private Helpers

    private func isSelfMessage(
        _ message: BitchatMessage,
        nickname: String,
        myPeerID: String,
        myNostrPubkey: String?,
        activeChannel: ChannelID
    ) -> Bool {
        if let spid = message.senderPeerID?.id {
            // In geohash channels, compare against our per-geohash nostr short ID
            if case .location = activeChannel, spid.hasPrefix("nostr:"),
               let myGeo = myNostrPubkey {
                return spid == "nostr:\(myGeo.prefix(TransportConfig.nostrShortKeyDisplayLength))"
            }
            return spid == myPeerID
        }
        // Fallback by nickname
        if message.sender == nickname { return true }
        if message.sender.hasPrefix(nickname + "#") { return true }
        return false
    }

    private func formatContent(
        _ content: String,
        nsContent: NSString,
        nsLen: Int,
        message: BitchatMessage,
        baseColor: Color,
        isSelf: Bool,
        isDark: Bool,
        nickname: String,
        myPeerID: String,
        myNostrPubkey: String?,
        activeChannel: ChannelID
    ) -> AttributedString {
        // Extract all matches
        let hasMentionsHint = content.contains("@")
        let hasHashtagsHint = content.contains("#")
        let hasURLHint = content.contains("://") || content.contains("www.") || content.contains("http")
        let hasLightningHint = content.lowercased().contains("ln") || content.lowercased().contains("lightning:")
        let hasCashuHint = content.lowercased().contains("cashu")

        let hashtagMatches = hasHashtagsHint ? Regexes.hashtag.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) : []
        let mentionMatches = hasMentionsHint ? Regexes.mention.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) : []
        let urlMatches = hasURLHint ? (Regexes.linkDetector?.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) ?? []) : []
        let cashuMatches = hasCashuHint ? Regexes.cashu.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) : []
        let lightningMatches = hasLightningHint ? Regexes.lightningScheme.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) : []
        let bolt11Matches = hasLightningHint ? Regexes.bolt11.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) : []
        let lnurlMatches = hasLightningHint ? Regexes.lnurl.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) : []

        // Combine and sort matches, excluding hashtags/URLs overlapping mentions
        let mentionRanges = mentionMatches.map { $0.range(at: 0) }

        func overlapsMention(_ r: NSRange) -> Bool {
            for mr in mentionRanges {
                if NSIntersectionRange(r, mr).length > 0 { return true }
            }
            return false
        }

        func attachedToMention(_ r: NSRange) -> Bool {
            if let nsRange = Range(r, in: content), nsRange.lowerBound > content.startIndex {
                var i = content.index(before: nsRange.lowerBound)
                while true {
                    let ch = content[i]
                    if ch.isWhitespace || ch.isNewline { break }
                    if ch == "@" { return true }
                    if i == content.startIndex { break }
                    i = content.index(before: i)
                }
            }
            return false
        }

        func isStandaloneHashtag(_ r: NSRange) -> Bool {
            guard let nsRange = Range(r, in: content) else { return false }
            if nsRange.lowerBound == content.startIndex { return true }
            let prev = content.index(before: nsRange.lowerBound)
            return content[prev].isWhitespace || content[prev].isNewline
        }

        var allMatches: [(range: NSRange, type: String)] = []
        for match in hashtagMatches where !overlapsMention(match.range(at: 0)) && !attachedToMention(match.range(at: 0)) && isStandaloneHashtag(match.range(at: 0)) {
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

        // Exclude overlaps with lightning/url for bolt11/lnurl
        let occupied: [NSRange] = urlMatches.map { $0.range } + lightningMatches.map { $0.range(at: 0) }
        func overlapsOccupied(_ r: NSRange) -> Bool {
            for or in occupied {
                if NSIntersectionRange(r, or).length > 0 { return true }
            }
            return false
        }
        for match in bolt11Matches where !overlapsMention(match.range(at: 0)) && !overlapsOccupied(match.range(at: 0)) {
            allMatches.append((match.range(at: 0), "bolt11"))
        }
        for match in lnurlMatches where !overlapsMention(match.range(at: 0)) && !overlapsOccupied(match.range(at: 0)) {
            allMatches.append((match.range(at: 0), "lnurl"))
        }
        allMatches.sort { $0.range.location < $1.range.location }

        // Build content with styling
        var processedContent = AttributedString()
        var lastEnd = content.startIndex
        let isMentioned = message.mentions?.contains(nickname) ?? false

        for (range, type) in allMatches {
            if let nsRange = Range(range, in: content) {
                // Add text before match
                if lastEnd < nsRange.lowerBound {
                    let beforeText = String(content[lastEnd..<nsRange.lowerBound])
                    if !beforeText.isEmpty {
                        var beforeStyle = AttributeContainer()
                        beforeStyle.foregroundColor = baseColor
                        beforeStyle.font = isSelf
                            ? .bitchatSystem(size: 14, weight: .bold, design: .monospaced)
                            : .bitchatSystem(size: 14, design: .monospaced)
                        if isMentioned {
                            beforeStyle.font = beforeStyle.font?.bold()
                        }
                        processedContent.append(AttributedString(beforeText).mergingAttributes(beforeStyle))
                    }
                }

                // Add styled match
                let matchText = String(content[nsRange])
                processedContent.append(formatMatch(
                    matchText,
                    type: type,
                    baseColor: baseColor,
                    isSelf: isSelf,
                    isDark: isDark,
                    nickname: nickname,
                    myPeerID: myPeerID,
                    myNostrPubkey: myNostrPubkey,
                    activeChannel: activeChannel
                ))

                lastEnd = nsRange.upperBound
            }
        }

        // Add remaining text after last match
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
            processedContent.append(AttributedString(remainingText).mergingAttributes(remainingStyle))
        }

        return processedContent
    }

    private func formatMatch(
        _ matchText: String,
        type: String,
        baseColor: Color,
        isSelf: Bool,
        isDark: Bool,
        nickname: String,
        myPeerID: String,
        myNostrPubkey: String?,
        activeChannel: ChannelID
    ) -> AttributedString {
        switch type {
        case "mention":
            return formatMention(
                matchText,
                baseColor: baseColor,
                isSelf: isSelf,
                nickname: nickname,
                myPeerID: myPeerID,
                myNostrPubkey: myNostrPubkey,
                activeChannel: activeChannel
            )
        case "hashtag":
            return formatHashtag(matchText, isDark: isDark, baseColor: baseColor, activeChannel: activeChannel)
        case "url":
            return formatURL(matchText, baseColor: baseColor, isSelf: isSelf)
        case "cashu", "bolt11", "lnurl", "lightning":
            return formatPayment(matchText, type: type, baseColor: baseColor, isSelf: isSelf)
        default:
            return AttributedString(matchText)
        }
    }

    private func formatMention(
        _ matchText: String,
        baseColor: Color,
        isSelf: Bool,
        nickname: String,
        myPeerID: String,
        myNostrPubkey: String?,
        activeChannel: ChannelID
    ) -> AttributedString {
        // Split optional '#abcd' suffix and color suffix light grey
        let (mBase, mSuffix) = matchText.splitSuffix()

        // Determine if this mention targets me
        let mySuffix: String? = {
            if case .location = activeChannel, let myGeo = myNostrPubkey {
                return String(myGeo.suffix(4))
            }
            return String(myPeerID.prefix(4))
        }()

        let isMentionToMe: Bool = {
            if mBase == nickname {
                if let suf = mySuffix, !mSuffix.isEmpty {
                    return mSuffix == "#\(suf)"
                }
                return mSuffix.isEmpty
            }
            return false
        }()

        var mentionStyle = AttributeContainer()
        mentionStyle.font = .bitchatSystem(size: 14, weight: .semibold, design: .monospaced)
        mentionStyle.foregroundColor = isMentionToMe ? .orange : baseColor

        var result = AttributedString()
        result.append(AttributedString(mBase).mergingAttributes(mentionStyle))

        if !mSuffix.isEmpty {
            var suffixStyle = mentionStyle
            suffixStyle.foregroundColor = (isMentionToMe ? Color.orange : baseColor).opacity(0.5)
            result.append(AttributedString(mSuffix).mergingAttributes(suffixStyle))
        }

        return result
    }

    private func formatHashtag(
        _ matchText: String,
        isDark: Bool,
        baseColor: Color,
        activeChannel: ChannelID
    ) -> AttributedString {
        var hashtagStyle = AttributeContainer()
        hashtagStyle.font = .bitchatSystem(size: 14, weight: .medium, design: .monospaced)

        // Determine if this hashtag represents the active channel
        let isActiveChannel: Bool = {
            if matchText.count > 1 {
                let tag = String(matchText.dropFirst()) // Remove '#'
                switch activeChannel {
                case .mesh:
                    return tag.lowercased() == "mesh"
                case .location(let ch):
                    return tag.lowercased() == ch.geohash.lowercased()
                }
            }
            return false
        }()

        if isActiveChannel {
            // Highlight active channel hashtag in green
            hashtagStyle.foregroundColor = isDark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
            hashtagStyle.font = .bitchatSystem(size: 14, weight: .bold, design: .monospaced)
        } else {
            // Link to geohash if valid
            if matchText.count > 1 {
                let tag = String(matchText.dropFirst())
                if tag.count >= 2, tag.count <= 12,
                   tag.allSatisfy({ "0123456789bcdefghjkmnpqrstuvwxyz".contains($0) }) {
                    if let url = URL(string: "bitchat://geohash/\(tag)") {
                        hashtagStyle.link = url
                    }
                }
            }
            hashtagStyle.foregroundColor = baseColor.opacity(0.8)
        }

        return AttributedString(matchText).mergingAttributes(hashtagStyle)
    }

    private func formatURL(_ matchText: String, baseColor: Color, isSelf: Bool) -> AttributedString {
        var urlStyle = AttributeContainer()
        if let url = URL(string: matchText) {
            urlStyle.link = url
        }
        urlStyle.foregroundColor = baseColor
        urlStyle.font = isSelf
            ? .bitchatSystem(size: 14, weight: .bold, design: .monospaced)
            : .bitchatSystem(size: 14, design: .monospaced)
        urlStyle.underlineStyle = .single
        return AttributedString(matchText).mergingAttributes(urlStyle)
    }

    private func formatPayment(
        _ matchText: String,
        type: String,
        baseColor: Color,
        isSelf: Bool
    ) -> AttributedString {
        var paymentStyle = AttributeContainer()
        paymentStyle.foregroundColor = baseColor
        paymentStyle.font = isSelf
            ? .bitchatSystem(size: 14, weight: .bold, design: .monospaced)
            : .bitchatSystem(size: 14, design: .monospaced)

        // Make payment tokens tappable
        if type == "cashu", let url = URL(string: "cashu:\(matchText)") {
            paymentStyle.link = url
        } else if type == "lightning" || type == "bolt11" || type == "lnurl" {
            if let url = URL(string: matchText.lowercased().hasPrefix("lightning:") ? matchText : "lightning:\(matchText)") {
                paymentStyle.link = url
            }
        }

        return AttributedString(matchText).mergingAttributes(paymentStyle)
    }
}
