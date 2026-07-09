//
// MeshMessageIdentity.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

/// Content-derived identity for public mesh messages.
///
/// The BLE wire carries no message ID for public broadcasts, so every device
/// recomputes the same stable ID from the signed wire fields (sender ID,
/// millisecond timestamp, content). That gives the mesh bridge a
/// cross-device-consistent dedup/attribution key with zero wire change — and
/// because receivers derive the key themselves instead of trusting a claimed
/// ID, a forged bridge tag cannot suppress or impersonate a genuine message.
enum MeshMessageIdentity {
    /// Matches the wire truncation in `BLEService.sendMessage`.
    static func millisecondTimestamp(_ date: Date) -> UInt64 {
        UInt64(date.timeIntervalSince1970 * 1000)
    }

    static func stableID(senderIDHex: String, timestampMs: UInt64, content: String) -> String {
        let input = senderIDHex.lowercased() + "|" + String(timestampMs) + "|" + content.trimmed
        return String(Data(input.utf8).sha256Hex().prefix(32))
    }
}
