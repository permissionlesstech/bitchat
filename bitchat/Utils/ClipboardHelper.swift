//
// ClipboardHelper.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#elseif os(macOS)
import AppKit
#endif

enum ClipboardHelper {
    #if os(iOS)
    /// Auto-expire copied messages, fingerprints, and tokens after two minutes
    /// on iOS and keep clipboard entries strictly local to this device so
    /// Universal Clipboard / Handoff never broadcasts them to nearby Apple devices.
    private static let expirationInterval: TimeInterval = 120
    #elseif os(macOS)
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    #endif

    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(expirationInterval)
            ]
        )
        #elseif os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: transientType)
        pasteboard.setData(Data(), forType: concealedType)
        #endif
    }

    static func clearForPanic() {
        #if os(iOS)
        UIPasteboard.general.items = []
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        #endif
    }
}
