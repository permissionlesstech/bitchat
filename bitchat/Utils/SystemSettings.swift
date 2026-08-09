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
    /// The radio power toggle, distinct from the `.bluetooth` privacy
    /// permission anchor: an already-authorized person whose radio is
    /// switched off can't fix anything from the privacy pane.
    case bluetoothPower
    case location
    case microphone

    #if os(macOS)
    private static let baseURL = "x-apple.systempreferences:com.apple.preference.security"

    private var macURLString: String {
        switch self {
        case .bluetooth: "\(Self.baseURL)?Privacy_Bluetooth"
        case .bluetoothPower: "x-apple.systempreferences:com.apple.BluetoothSettings"
        case .location: "\(Self.baseURL)?Privacy_LocationServices"
        case .microphone: "\(Self.baseURL)?Privacy_Microphone"
        }
    }
    #endif

    func open() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: macURLString) {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
