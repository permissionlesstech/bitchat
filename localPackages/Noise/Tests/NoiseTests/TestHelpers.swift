//
// TestHelpers.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit
import BitFoundation

// TODO: Combine with the one from the main target
final class TestHelpers {
    static func generateRandomData(length: Int) -> Data {
        var data = Data(count: length)
        _ = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, length, bytes.baseAddress!)
        }
        return data
    }

    @MainActor
    static func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.01
    ) async -> Bool {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                return condition()
            }
            try? await sleep(pollInterval)
        }
        return true
    }
}

func sleep(_ seconds: TimeInterval) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}
