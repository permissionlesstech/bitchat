//
// TestEnvironment.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Process-level test-environment detection for singletons that must swap a
/// real OS-backed dependency (keychain, persistent defaults, notifications)
/// for an in-memory one under test. Mirrors the detection already used by
/// `NotificationService` and `LocationStateManager`.
enum TestEnvironment {
    /// True when running under XCTest / Swift Testing or in CI.
    /// Compiled out of Release builds so shell environment variables such as
    /// `CI` cannot disable persistence, notifications, location, or panic-wipe
    /// cleanup in shipping binaries.
    static let isRunningTests: Bool = {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return NSClassFromString("XCTestCase") != nil ||
               env["XCTestConfigurationFilePath"] != nil ||
               env["XCTestBundlePath"] != nil ||
               env["GITHUB_ACTIONS"] != nil ||
               env["CI"] != nil
        #else
        return false
        #endif
    }()
}
