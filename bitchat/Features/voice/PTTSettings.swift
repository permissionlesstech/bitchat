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
/// Per-conversation live voice speaker auto-play override.
enum PTTAutoListenPolicy: String, CaseIterable, Identifiable {
    case automatic
    case always
    case never

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return String(localized: "walkie.autolisten.automatic", defaultValue: "Automatic", comment: "Per-chat auto-listen option using default rules")
        case .always:
            return String(localized: "walkie.autolisten.always", defaultValue: "Always Auto-Play", comment: "Per-chat auto-listen option to always play incoming live voice aloud")
        case .never:
            return String(localized: "walkie.autolisten.never", defaultValue: "Tap to Play Only", comment: "Per-chat auto-listen option disabling automatic speaker playback")
        }
    }

    var shortLabel: String {
        switch self {
        case .automatic:
            return String(localized: "walkie.autolisten.short.automatic", defaultValue: "Auto", comment: "Short label for automatic per-chat auto-listen")
        case .always:
            return String(localized: "walkie.autolisten.short.always", defaultValue: "Always", comment: "Short label for always per-chat auto-listen")
        case .never:
            return String(localized: "walkie.autolisten.short.never", defaultValue: "Manual", comment: "Short label for manual tap-to-play per-chat auto-listen")
        }
    }
}

enum PTTSettings {
    static let liveVoiceEnabledKey = "ptt.liveVoiceEnabled"
    static let toneCuesEnabledKey = "ptt.toneCuesEnabled"
    static let publicAutoPlayEnabledKey = "ptt.publicAutoPlayEnabled"
    static let chatAutoListenPoliciesKey = "ptt.chatAutoListenPolicies"
    static let liveVoiceDidChangeNotification = Notification.Name("chat.bitchat.ptt.liveVoiceDidChange")

    static var liveVoiceEnabled: Bool {
        get { liveVoiceEnabled(in: .standard) }
        set { setLiveVoiceEnabled(newValue, in: .standard) }
    }

    static var toneCuesEnabled: Bool {
        get { toneCuesEnabled(in: .standard) }
        set { setToneCuesEnabled(newValue, in: .standard) }
    }

    /// Controls whether unprompted incoming live bursts in public Nearby (`#mesh`)
    /// auto-play aloud when Live Voice is enabled. Off by default so trusted DMs
    /// and groups can auto-play without strangers' voices playing out loud in public.
    static var publicAutoPlayEnabled: Bool {
        get { publicAutoPlayEnabled(in: .standard) }
        set { setPublicAutoPlayEnabled(newValue, in: .standard) }
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

    static func publicAutoPlayEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: publicAutoPlayEnabledKey) as? Bool ?? false
    }

    static func setPublicAutoPlayEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: publicAutoPlayEnabledKey)
        if defaults === UserDefaults.standard {
            NotificationCenter.default.post(name: liveVoiceDidChangeNotification, object: nil)
        }
    }

    static func chatAutoListenPolicy(for key: String, in defaults: UserDefaults = .standard) -> PTTAutoListenPolicy {
        guard let map = defaults.dictionary(forKey: chatAutoListenPoliciesKey) as? [String: String],
              let raw = map[key],
              let policy = PTTAutoListenPolicy(rawValue: raw) else {
            return .automatic
        }
        return policy
    }

    static func setChatAutoListenPolicy(_ policy: PTTAutoListenPolicy, for key: String, in defaults: UserDefaults = .standard) {
        var map = (defaults.dictionary(forKey: chatAutoListenPoliciesKey) as? [String: String]) ?? [:]
        if policy == .automatic {
            map.removeValue(forKey: key)
        } else {
            map[key] = policy.rawValue
        }
        if map.isEmpty {
            defaults.removeObject(forKey: chatAutoListenPoliciesKey)
        } else {
            defaults.set(map, forKey: chatAutoListenPoliciesKey)
        }
        if defaults === UserDefaults.standard {
            NotificationCenter.default.post(name: liveVoiceDidChangeNotification, object: nil)
        }
    }

    /// Evaluates whether an inbound live burst should auto-play aloud given
    /// global settings, speaker mute state, scope, and per-chat override.
    static func shouldAutoPlayInbound(
        isPublicMesh: Bool,
        chatKey: String?,
        isChatMuted: Bool,
        liveEnabled: Bool = PTTSettings.liveVoiceEnabled,
        publicAutoPlay: Bool = PTTSettings.publicAutoPlayEnabled,
        isSpeakerMuted: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard liveEnabled, !isSpeakerMuted else { return false }
        if isPublicMesh {
            return publicAutoPlay
        }
        let policy = chatKey.map { chatAutoListenPolicy(for: $0, in: defaults) } ?? .automatic
        switch policy {
        case .always:
            return true
        case .never:
            return false
        case .automatic:
            return !isChatMuted
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
        defaults.removeObject(forKey: publicAutoPlayEnabledKey)
        defaults.removeObject(forKey: chatAutoListenPoliciesKey)
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
    @Published private(set) var publicAutoPlayEnabled: Bool
    @Published private(set) var isAutoListenMuted: Bool
    @Published private(set) var policyRevision: UInt64 = 0

    private var observer: NSObjectProtocol?

    private init() {
        self.liveVoiceEnabled = PTTSettings.liveVoiceEnabled
        self.toneCuesEnabled = PTTSettings.toneCuesEnabled
        self.publicAutoPlayEnabled = PTTSettings.publicAutoPlayEnabled
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

    func setPublicAutoPlayEnabled(_ enabled: Bool) {
        PTTSettings.publicAutoPlayEnabled = enabled
        syncFromSettings()
    }

    func setAutoListenMuted(_ muted: Bool) {
        PTTSettings.isAutoListenMuted = muted
        syncFromSettings()
    }

    func toggleAutoListenMuted() {
        setAutoListenMuted(!isAutoListenMuted)
    }

    func chatAutoListenPolicy(for key: String) -> PTTAutoListenPolicy {
        PTTSettings.chatAutoListenPolicy(for: key)
    }

    func setChatAutoListenPolicy(_ policy: PTTAutoListenPolicy, for key: String) {
        PTTSettings.setChatAutoListenPolicy(policy, for: key)
        policyRevision &+= 1
        syncFromSettings()
    }

    private func syncFromSettings() {
        let live = PTTSettings.liveVoiceEnabled
        let tones = PTTSettings.toneCuesEnabled
        let publicAuto = PTTSettings.publicAutoPlayEnabled
        let muted = PTTSettings.isAutoListenMuted
        if liveVoiceEnabled != live { liveVoiceEnabled = live }
        if toneCuesEnabled != tones { toneCuesEnabled = tones }
        if publicAutoPlayEnabled != publicAuto { publicAutoPlayEnabled = publicAuto }
        if isAutoListenMuted != muted { isAutoListenMuted = muted }
    }
}
