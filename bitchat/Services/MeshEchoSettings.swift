//
// MeshEchoSettings.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Watermark for "heard here earlier" echoes: clearing the mesh timeline
/// (triple-tap or /clear) records the moment, and the next launch only
/// re-seeds archived messages heard after it. The archive itself is left
/// alone — the device keeps carrying those messages for peers; the user
/// just doesn't want to see them again.
enum MeshEchoSettings {
    private static let clearedThroughKey = "meshEchoes.clearedThrough"

    static var clearedThrough: Date? {
        get { UserDefaults.standard.object(forKey: clearedThroughKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: clearedThroughKey) }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: clearedThroughKey)
    }
}
