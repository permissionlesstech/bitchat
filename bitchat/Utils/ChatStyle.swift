//
// ChatStyle.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// How the chat transcript lays out messages. Independent of `AppTheme`:
/// the theme picks colors, fonts and chrome; the style only picks the row
/// layout.
///
/// `bubbles` is the messenger layout (the Android app's default since
/// 2.0): messages hug their content inside rounded bubbles, own messages
/// on the right and everyone else on the left, each bubble washed with its
/// author's peer color. `irc` is the original flat `<@name> text [time]`
/// transcript.
enum ChatStyle: String, CaseIterable, Identifiable {
    case bubbles
    case irc

    var id: String { rawValue }

    /// UserDefaults key backing the style selection.
    static let storageKey = "chatStyle"

    var displayNameKey: LocalizedStringKey {
        switch self {
        case .bubbles: return "app_info.chat_style.bubbles"
        case .irc: return "app_info.chat_style.irc"
        }
    }

    var usesBubbles: Bool { self == .bubbles }
}

private struct ChatStyleKey: EnvironmentKey {
    static let defaultValue: ChatStyle = .bubbles
}

extension EnvironmentValues {
    var chatStyle: ChatStyle {
        get { self[ChatStyleKey.self] }
        set { self[ChatStyleKey.self] = newValue }
    }
}
