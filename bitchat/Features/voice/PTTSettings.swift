//
// PTTSettings.swift
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

/// User preference for live push-to-talk voice. One switch controls both
/// directions: streaming your holds live, and auto-playing inbound bursts.
/// Off means voice messages behave exactly like classic voice notes.
enum PTTSettings {
    private static let liveVoiceEnabledKey = "ptt.liveVoiceEnabled"

    static var liveVoiceEnabled: Bool {
        get { UserDefaults.standard.object(forKey: liveVoiceEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: liveVoiceEnabledKey) }
    }

    /// Autoplay is foreground-only: audio must never start from the
    /// background.
    @MainActor
    static var isAppActive: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState == .active
        #elseif os(macOS)
        return NSApplication.shared.isActive
        #else
        return true
        #endif
    }
}
