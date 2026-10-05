//
// MessageClipboard.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Clipboard helpers for message actions. Kept out of the view so unit tests
/// can assert quote formatting without standing up SwiftUI.
enum MessageClipboard {
    /// Plain message body for the pasteboard.
    static func copyPlaintext(_ content: String) {
        #if os(iOS)
        UIPasteboard.general.string = content
        #elseif os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        #endif
    }

    /// Builds a composer-ready quote block (`> line` per line, trailing blank).
    static func quoteForComposer(_ content: String, sender: String?) -> String {
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "" }
        let header: String
        if let sender, !sender.isEmpty, sender != "system" {
            header = "> @\(sender):\n"
        } else {
            header = ""
        }
        let quoted = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        return header + quoted + "\n\n"
    }

    /// Appends a quote to an existing composer draft without wiping it.
    static func appendQuote(to draft: String, content: String, sender: String?) -> String {
        let quote = quoteForComposer(content, sender: sender)
        guard !quote.isEmpty else { return draft }
        if draft.isEmpty { return quote }
        if draft.hasSuffix("\n") || draft.hasSuffix(" ") {
            return draft + quote
        }
        return draft + "\n" + quote
    }
}
