//
// AlternateAppIconSettings.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
#if os(iOS)
import UIKit
#endif
import BitLogger

/// Low-profile alternate home-screen icons (#1447). Neutral / notes / quiet
/// variants live as App Icon sets in the asset catalog and are enabled via
/// `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS`.
enum AlternateAppIconSettings {
    static let storageKey = "appearance.alternateAppIcon"

    /// Catalog names. `nil` means the primary AppIcon.
    enum Icon: String, CaseIterable, Identifiable {
        case primary
        case neutral = "AppIconNeutral"
        case notes = "AppIconNotes"
        case quiet = "AppIconQuiet"

        var id: String { rawValue }

        /// Name passed to `UIApplication.setAlternateIconName`. Primary is nil.
        var systemName: String? {
            switch self {
            case .primary: return nil
            case .neutral, .notes, .quiet: return rawValue
            }
        }

        var title: String {
            switch self {
            case .primary:
                return String(
                    localized: "app_info.settings.icon.primary",
                    defaultValue: "bitchat",
                    comment: "Label for the default bitchat home-screen icon"
                )
            case .neutral:
                return String(
                    localized: "app_info.settings.icon.neutral",
                    defaultValue: "neutral",
                    comment: "Label for the grayscale low-profile alternate app icon"
                )
            case .notes:
                return String(
                    localized: "app_info.settings.icon.notes",
                    defaultValue: "notes",
                    comment: "Label for the blue-gray notes-like alternate app icon"
                )
            case .quiet:
                return String(
                    localized: "app_info.settings.icon.quiet",
                    defaultValue: "quiet",
                    comment: "Label for the dark monochrome alternate app icon"
                )
            }
        }
    }

    static var selected: Icon {
        get { selected(in: .standard) }
        set { setSelected(newValue, in: .standard, applySystem: true) }
    }

    static func selected(in defaults: UserDefaults) -> Icon {
        let raw = defaults.string(forKey: storageKey) ?? Icon.primary.rawValue
        return Icon(rawValue: raw) ?? .primary
    }

    static func setSelected(_ icon: Icon, in defaults: UserDefaults, applySystem: Bool = true) {
        if icon == .primary {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(icon.rawValue, forKey: storageKey)
        }
        if applySystem {
            apply(icon)
        }
    }

    /// Apply the stored preference to the system (iOS only). Safe no-op elsewhere.
    static func applyStoredPreference() {
        apply(selected(in: .standard))
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
        apply(.primary)
    }

    private static func apply(_ icon: Icon) {
        #if os(iOS)
        // Unit tests and early launch may not have a ready UIApplication.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { apply(icon) }
            return
        }
        guard UIApplication.shared.supportsAlternateIcons else { return }
        let target = icon.systemName
        // Avoid a no-op system prompt when already on the desired icon.
        let current = UIApplication.shared.alternateIconName
        guard current != target else { return }
        UIApplication.shared.setAlternateIconName(target) { error in
            if let error {
                SecureLogger.warning(
                    "alternate icon change failed: \(error.localizedDescription)",
                    category: .session
                )
            }
        }
        #endif
    }
}
