//
// SystemSettings.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum SystemSettings {
    case bluetooth
    case location
    case microphone

    #if os(macOS)
    private static let baseURL = "x-apple.systempreferences:com.apple.preference.security"

    private var macPrivacyAnchor: String {
        switch self {
        case .bluetooth: "Privacy_Bluetooth"
        case .location: "Privacy_LocationServices"
        case .microphone: "Privacy_Microphone"
        }
    }
    #endif

    func open() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        let urlString = "\(Self.baseURL)?\(macPrivacyAnchor)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
