//
// BLEProximityWakeSettings.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Controls background wake-on-proximity: pending BLE connects that let iOS
/// relaunch the app when a recent peer returns into range (#1396).
///
/// On iOS 26 that relaunch surfaces as an "accessory would like to open
/// bitchat" consent sheet (#1427). Default remains on so the mesh stays
/// reachable while backgrounded; people who prefer not to see the prompt
/// can turn it off.
enum BLEProximityWakeSettings {
    private static let enabledKey = "ble.proximityWakeEnabled"

    /// When false, bitchat will not arm pending background connects.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}
