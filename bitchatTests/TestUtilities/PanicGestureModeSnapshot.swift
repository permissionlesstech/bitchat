//
// PanicGestureModeSnapshot.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
@testable import bitchat

/// A completed wipe arms `panic.gestureMode` in UserDefaults.standard. Take and
/// restore this in one @MainActor test body; a suite `deinit` can run off that actor.
struct PanicGestureModeSnapshot {
    private let value = UserDefaults.standard.object(forKey: PanicGestureSettings.storageKey)

    func restore() {
        if let value {
            UserDefaults.standard.set(value, forKey: PanicGestureSettings.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PanicGestureSettings.storageKey)
        }
    }
}
