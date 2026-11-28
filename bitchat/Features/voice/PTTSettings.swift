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
    static let toneCuesEnabledKey = "ptt.toneCuesEnabled"
    static let liveVoiceDidChangeNotification = Notification.Name("chat.bitchat.ptt.liveVoiceDidChange")

    static var liveVoiceEnabled: Bool {
        get { liveVoiceEnabled(in: .standard) }
        set { setLiveVoiceEnabled(newValue, in: .standard) }
    }

    static var toneCuesEnabled: Bool {
        get { toneCuesEnabled(in: .standard) }
        set { setToneCuesEnabled(newValue, in: .standard) }
    }

    /// Store-injecting forms, so tests can assert the default and both settings
    /// without touching the shared preferences other tests read.
    static func liveVoiceEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: liveVoiceEnabledKey) as? Bool ?? false
    }

    static func setLiveVoiceEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: liveVoiceEnabledKey)
        if defaults === UserDefaults.standard {
            NotificationCenter.default.post(name: liveVoiceDidChangeNotification, object: nil)
        }
    }

    static func toneCuesEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: toneCuesEnabledKey) as? Bool ?? true
    }

    static func setToneCuesEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: toneCuesEnabledKey)
        if defaults === UserDefaults.standard {
            NotificationCenter.default.post(name: liveVoiceDidChangeNotification, object: nil)
        }
    }

    /// Session-only mute for incoming live speaker autoplay. Lets users silence
    /// incoming live voices with one tap without turning off live sending.
    @MainActor
    static var isAutoListenMuted: Bool = false {
        didSet {
            if oldValue != isAutoListenMuted {
                NotificationCenter.default.post(name: liveVoiceDidChangeNotification, object: nil)
            }
        }
    }

    /// Panic-wipe hook. Removing the key restores the off default, so a wiped
    /// device cannot come back streaming live.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: liveVoiceEnabledKey)
        defaults.removeObject(forKey: toneCuesEnabledKey)
        if defaults === UserDefaults.standard {
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    isAutoListenMuted = false
                }
            } else {
                Task { @MainActor in
                    isAutoListenMuted = false
                }
            }
            NotificationCenter.default.post(name: liveVoiceDidChangeNotification, object: nil)
        }
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

/// Observable SwiftUI bridge over `PTTSettings` so Settings, headers, composer,
/// and the Walkie-Talkie deck stay instantly synchronized.
@MainActor
final class PTTPreferences: ObservableObject {
    static let shared = PTTPreferences()

    @Published private(set) var liveVoiceEnabled: Bool
    @Published private(set) var toneCuesEnabled: Bool
    @Published private(set) var isAutoListenMuted: Bool

    private var observer: NSObjectProtocol?

    private init() {
        self.liveVoiceEnabled = PTTSettings.liveVoiceEnabled
        self.toneCuesEnabled = PTTSettings.toneCuesEnabled
        self.isAutoListenMuted = PTTSettings.isAutoListenMuted
        observer = NotificationCenter.default.addObserver(
            forName: PTTSettings.liveVoiceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncFromSettings()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func setLiveVoiceEnabled(_ enabled: Bool) {
        PTTSettings.liveVoiceEnabled = enabled
        syncFromSettings()
    }

    func setToneCuesEnabled(_ enabled: Bool) {
        PTTSettings.toneCuesEnabled = enabled
        syncFromSettings()
    }

    func setAutoListenMuted(_ muted: Bool) {
        PTTSettings.isAutoListenMuted = muted
        syncFromSettings()
    }

    func toggleAutoListenMuted() {
        setAutoListenMuted(!isAutoListenMuted)
    }

    private func syncFromSettings() {
        let live = PTTSettings.liveVoiceEnabled
        let tones = PTTSettings.toneCuesEnabled
        let muted = PTTSettings.isAutoListenMuted
        if liveVoiceEnabled != live { liveVoiceEnabled = live }
        if toneCuesEnabled != tones { toneCuesEnabled = tones }
        if isAutoListenMuted != muted { isAutoListenMuted = muted }
    }
}
