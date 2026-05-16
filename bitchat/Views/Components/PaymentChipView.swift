//
// PaymentChipView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct PaymentChipView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    
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
    
    private var fgColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    private var bgColor: Color {
        colorScheme == .dark ? Color.gray.opacity(0.18) : Color.gray.opacity(0.12)
    }
    private var border: Color { fgColor.opacity(0.25) }
    
    var body: some View {
        Button {
            #if os(iOS)
            if let url = paymentType.url { openURL(url) }
            #else
            if let url = paymentType.url { NSWorkspace.shared.open(url) }
            #endif
        } label: {
            HStack(spacing: 6) {
                Text(paymentType.emoji)
                Text(paymentType.label)
                    .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
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
