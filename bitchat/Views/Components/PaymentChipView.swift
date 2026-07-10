//
// PaymentChipView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct PaymentChipView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @ThemedPalette private var palette

    enum PaymentType {
        case cashu(String)
        case lightning(String)

        private static let cashuAllowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

        private static func cashuURL(from link: String) -> URL? {
            if let url = URL(string: link), url.scheme != nil {
                return url
            }
            let enc = link.addingPercentEncoding(withAllowedCharacters: cashuAllowedCharacters) ?? link
            return URL(string: "cashu:\(enc)")
        }

        var url: URL? {
            switch self {
            case .cashu(let link):
                return Self.cashuURL(from: link)
            case .lightning(let link):
                return URL(string: link)
            }
        }

        /// The bare `cashuA…`/`cashuB…` bearer string, when this is a Cashu chip.
        var cashuToken: String? {
            if case .cashu(let link) = self {
                return CashuTokenDecoder.bareToken(from: link)
            }
            return nil
        }

        /// Web fallback for redemption when no wallet handles `cashu:` URLs.
        /// The token only reaches the site the user's browser loads; the app
        /// itself never contacts a mint.
        var cashuWebRedeemURL: URL? {
            guard let token = cashuToken,
                  let enc = token.addingPercentEncoding(withAllowedCharacters: Self.cashuAllowedCharacters) else {
                return nil
            }
            return URL(string: "https://redeem.cashu.me/?token=\(enc)")
        }

        var emoji: String {
            switch self {
            case .cashu:        "🥜"
            case .lightning:    "⚡"
            }
        }

        var label: String {
            switch self {
            case .cashu:
                String(localized: "content.payment.cashu", comment: "Label for Cashu payment chip")
            case .lightning:
                String(localized: "content.payment.lightning", comment: "Label for Lightning payment chip")
            }
        }
    }

    let paymentType: PaymentType
    /// Decoded once at construction; tokens are capped in size so this is
    /// cheap, and rows re-render often enough that lazy decode in `body`
    /// would just repeat the work.
    private let cashuInfo: CashuTokenDecoder.TokenInfo?

    init(paymentType: PaymentType) {
        self.paymentType = paymentType
        if case .cashu(let link) = paymentType {
            self.cashuInfo = CashuTokenDecoder.decode(link)
        } else {
            self.cashuInfo = nil
        }
    }

    private var fgColor: Color { palette.primary }
    private var bgColor: Color {
        palette.secondary.opacity(colorScheme == .dark ? 0.18 : 0.12)
    }
    private var border: Color { fgColor.opacity(0.25) }

    /// "500 sat · mint.example.com", degrading to the generic label when the
    /// token didn't decode (V4 payloads we can't walk, malformed input…).
    private var primaryLabel: String {
        guard let info = cashuInfo else { return paymentType.label }
        var parts: [String] = []
        if let amount = info.displayAmount { parts.append(amount) }
        if let host = info.mintHost { parts.append(host) }
        return parts.isEmpty ? paymentType.label : parts.joined(separator: " · ")
    }

    private var memoLabel: String? { cashuInfo?.memo }

    var body: some View {
        Button {
            primaryAction()
        } label: {
            HStack(spacing: 6) {
                Text(paymentType.emoji)
                VStack(alignment: .leading, spacing: 1) {
                    Text(primaryLabel)
                        .bitchatFont(size: 12, weight: .semibold)
                    if let memoLabel {
                        Text(memoLabel)
                            .bitchatFont(size: 10)
                            .opacity(0.7)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(bgColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(border, lineWidth: 1)
            )
            .foregroundColor(fgColor)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let token = paymentType.cashuToken {
                Button {
                    copyToPasteboard(token)
                } label: {
                    Label(String(localized: "content.payment.copy_token", comment: "Context menu action copying a Cashu token to the pasteboard"), systemImage: "doc.on.doc")
                }
                Button {
                    redeemCashu()
                } label: {
                    Label(String(localized: "content.payment.redeem_wallet", comment: "Context menu action opening a Cashu token in an ecash wallet app"), systemImage: "wallet.pass")
                }
                if let webURL = paymentType.cashuWebRedeemURL {
                    Button {
                        openExternalURL(webURL)
                    } label: {
                        Label(String(localized: "content.payment.redeem_web", comment: "Context menu action opening a Cashu token in the web redemption page"), systemImage: "safari")
                    }
                }
            }
        }
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private var accessibilityText: String {
        var text = "\(paymentType.label): \(primaryLabel)"
        if let memoLabel { text += ", \(memoLabel)" }
        return text
    }

    // MARK: - Actions

    private func primaryAction() {
        switch paymentType {
        case .cashu:
            redeemCashu()
        case .lightning:
            #if os(iOS)
            if let url = paymentType.url { openURL(url) }
            #else
            if let url = paymentType.url { NSWorkspace.shared.open(url) }
            #endif
        }
    }

    /// Redemption is delegated: try a wallet registered for `cashu:` URLs
    /// first, then fall back to the web redemption page. Uses the platform
    /// opener directly (not the `openURL` environment) because the message
    /// list overrides that action for cashu/lightning schemes without a
    /// fallback path.
    private func redeemCashu() {
        let walletURL = paymentType.url
        let webURL = paymentType.cashuWebRedeemURL
        #if os(iOS)
        if let walletURL {
            UIApplication.shared.open(walletURL, options: [:]) { accepted in
                if !accepted, let webURL {
                    UIApplication.shared.open(webURL)
                }
            }
        } else if let webURL {
            UIApplication.shared.open(webURL)
        }
        #else
        if let walletURL, NSWorkspace.shared.urlForApplication(toOpen: walletURL) != nil {
            NSWorkspace.shared.open(walletURL)
        } else if let webURL {
            NSWorkspace.shared.open(webURL)
        } else if let walletURL {
            NSWorkspace.shared.open(walletURL)
        }
        #endif
    }

    private func openExternalURL(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    private func copyToPasteboard(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

#Preview {
    let cashuLink = "https://example.com/cashu"
    let lightningLink = "https://example.com/lightning"

    List {
        HStack {
            PaymentChipView(paymentType: .cashu(cashuLink))
            PaymentChipView(paymentType: .lightning(lightningLink))
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
        .listRowBackground(EmptyView())
    }
    .environment(\.colorScheme, .light)

    List {
        HStack {
            PaymentChipView(paymentType: .cashu(cashuLink))
            PaymentChipView(paymentType: .lightning(lightningLink))
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
        .listRowBackground(EmptyView())
    }
    .environment(\.colorScheme, .dark)
}
