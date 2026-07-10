//
// TestConstants.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
@testable import bitchat

struct TestConstants {
    static let defaultTimeout: TimeInterval = 5.0
    static let shortTimeout: TimeInterval = 1.0
    /// For positive waits on work that hops through `Task.detached` or
    /// background queues: those contend with every parallel test worker for
    /// the global executor, so a loaded CI runner can exceed
    /// `defaultTimeout`. `waitUntil` returns as soon as the condition holds,
    /// so passing runs never pay the longer timeout.
    static let longTimeout: TimeInterval = 10.0
    
    static let testNickname1 = "Alice"
    static let testNickname2 = "Bob"
    static let testNickname3 = "Charlie"
    static let testNickname4 = "David"
    
    static let testMessage1 = "Hello, World!"
    static let testLongMessage = String(repeating: "This is a long message. ", count: 100)
}
