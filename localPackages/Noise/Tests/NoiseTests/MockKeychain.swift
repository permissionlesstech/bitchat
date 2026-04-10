//
// MockKeychain.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
@testable import Noise

// TODO: Combine with the one from the main target
final class MockKeychain: SecureMemoryCleaner {
    /// Thread-safe counter for secureClear calls
    private let lock = NSLock()
    private var _secureClearDataCallCount = 0

    var secureClearDataCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _secureClearDataCallCount
    }

    func secureClear(_ data: inout Data) {
        lock.lock()
        _secureClearDataCallCount += 1
        lock.unlock()
        data = Data()
    }

    func secureClear(_ string: inout String) {
        string = ""
    }
}
