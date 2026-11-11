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
///
/// Off by default: live mode sends audio to other people before the hold is
/// released and plays strangers' voices out of the speaker unprompted. Both
/// are consequences someone must opt into, not discover.
enum PTTSettings {
    static let liveVoiceEnabledKey = "ptt.liveVoiceEnabled"

    static var liveVoiceEnabled: Bool {
        get { liveVoiceEnabled(in: .standard) }
        set { setLiveVoiceEnabled(newValue, in: .standard) }
    }

    /// Store-injecting forms, so tests can assert the default and both settings
    /// without touching the shared preferences other tests read.
    static func liveVoiceEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: liveVoiceEnabledKey) as? Bool ?? false
    }

    static func setLiveVoiceEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: liveVoiceEnabledKey)
    }

    /// Panic-wipe hook. Removing the key restores the off default, so a wiped
    /// device cannot come back streaming live.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: liveVoiceEnabledKey)
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
