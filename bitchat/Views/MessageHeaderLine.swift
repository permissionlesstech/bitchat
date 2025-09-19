// MessageHeaderLine.swift
// bitchat
//
// Renders a header like normal messages: "<@nickname> [HH:mm:ss]"
// Used above media rows (images, audio) to match text message style.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct MessageHeaderLine: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    let message: BitchatMessage

    var body: some View {
        Text(formattedHeader())
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
    }

    private func formattedHeader() -> AttributedString {
        var result = AttributedString()
        let isDark = colorScheme == .dark
        let baseColor = viewModel.peerColor(for: message, isDark: isDark)

        // Determine self to bold our own name
        let isSelf: Bool = {
            if let spid = message.senderPeerID {
                return spid == viewModel.meshService.myPeerID
            }
            return message.sender == viewModel.nickname || message.sender.hasPrefix(viewModel.nickname + "#")
        }()

        // Split suffix like name#abcd
        let (base, suffix) = message.sender.splitSuffix()

        var senderStyle = AttributeContainer()
        senderStyle.foregroundColor = baseColor
        senderStyle.font = .system(size: 14, weight: isSelf ? .bold : .medium, design: .monospaced)
        if let spid = message.senderPeerID,
           let url = URL(string: "bitchat://user/\(spid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? spid)") {
            senderStyle.link = url
        }

        // "<@"
        result.append(AttributedString("<@").mergingAttributes(senderStyle))
        // base name
        result.append(AttributedString(base).mergingAttributes(senderStyle))
        // optional suffix with lighter color
        if !suffix.isEmpty {
            var suf = senderStyle
            suf.foregroundColor = baseColor.opacity(0.6)
            result.append(AttributedString(suffix).mergingAttributes(suf))
        }
        // Close angle without adding content or ">"
        result.append(AttributedString("> ").mergingAttributes(senderStyle))

        // Timestamp like normal messages
        let ts = AttributedString("[\(message.formattedTimestamp)]")
        var tsStyle = AttributeContainer()
        tsStyle.foregroundColor = Color.gray.opacity(0.7)
        tsStyle.font = .system(size: 10, design: .monospaced)
        result.append(ts.mergingAttributes(tsStyle))

        return result
    }
}
