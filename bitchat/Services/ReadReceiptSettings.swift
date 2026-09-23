//
// ReadReceiptSettings.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Controls whether this device tells senders when their private messages
/// were read.
///
/// A read receipt is a presence oracle: it says the person is awake, holding
/// their phone, and opened the app at a specific moment — exactly the
/// metadata someone under observation may need to withhold. Receipts were
/// previously unconditional; this is the switch every mainstream messenger
/// ships.
///
/// Defaults to on (the existing behavior). Turning it off only withholds
/// receipts this device SENDS — receipts from others still display. While
/// off, read messages are still recorded locally as receipted, so turning
/// the setting back on never fires a retroactive burst that would disclose
/// past reading activity.
enum ReadReceiptSettings {
    private static let sendReadReceiptsKey = "privacy.sendReadReceipts"

    static var sendReadReceipts: Bool {
        get { sendReadReceipts(in: .standard) }
        set { setSendReadReceipts(newValue, in: .standard) }
    }

    /// Store-injecting forms, so tests can assert the default and both
    /// settings without touching the shared preferences other tests read.
    static func sendReadReceipts(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: sendReadReceiptsKey) as? Bool ?? true
    }

    static func setSendReadReceipts(_ send: Bool, in defaults: UserDefaults) {
        defaults.set(send, forKey: sendReadReceiptsKey)
    }

    /// Panic-wipe hook: removing the key restores the default.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: sendReadReceiptsKey)
    }
}
