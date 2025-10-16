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
    static let longTimeout: TimeInterval = 10.0
    
    static let testNickname1 = "Alice"
    static let testNickname2 = "Bob"
    static let testNickname3 = "Charlie"
    static let testNickname4 = "David"
    
    static let testMessage1 = "Hello, World!"
    static let testMessage2 = "How are you?"
    static let testMessage3 = "This is a test message"
    static let testLongMessage = String(repeating: "This is a long message. ", count: 100)
    
    static let testSignature = Data(repeating: 0xAB, count: 64)
}
