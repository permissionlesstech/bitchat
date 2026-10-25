//
// InMemoryUserDefaults.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// A `UserDefaults` whose values live in memory only. Every typed accessor
/// (`string(forKey:)`, `set(_:forKey:)` for Int, Bool, Data, ...) funnels
/// through the three primitives overridden here, so nothing reaches
/// cfprefsd and a test leaves no plist in Library/Preferences. A real suite
/// leaves one even after `removePersistentDomain(forName:)`.
///
/// Domain-level calls (`removePersistentDomain(forName:)`,
/// `dictionaryRepresentation()`, `register(defaults:)`) are not covered:
/// code under test that needs them should keep a real suite.
class InMemoryUserDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    /// A fresh, empty instance. The suite name is never written.
    convenience init() {
        self.init(suiteName: "bitchat.tests.inMemory")!
    }

    override func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        values[defaultName] = nil
    }
}
