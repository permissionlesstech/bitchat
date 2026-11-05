//
//  NicknameClipboard.swift
//  bitchat
//
//  This is free and unencumbered software released into the public domain.
//  For more information, see <https://unlicense.org>
//

import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Pasteboard writes for people-sheet nickname / display-name copy actions.
///
/// Callers pass the full `displayName` (including any `#abcd` suffix) so a
/// pasted `/msg` target matches what the roster shows.
enum NicknameClipboard {
    static func copy(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
