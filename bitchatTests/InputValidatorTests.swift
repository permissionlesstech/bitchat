//
// InputValidatorTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

struct InputValidatorTests {

    // MARK: - Basic Validation Tests

    @Test func validStringPassesValidation() throws {
        let result = InputValidator.validateUserString("Hello World", maxLength: 100)
        #expect(result == "Hello World")
    }

    @Test func emptyStringReturnsNil() throws {
        let result = InputValidator.validateUserString("", maxLength: 100)
        #expect(result == nil)
    }

    @Test func whitespaceOnlyStringReturnsNil() throws {
        let result = InputValidator.validateUserString("   \n\t  ", maxLength: 100)
        #expect(result == nil)
    }

    @Test func stringExceedingMaxLengthReturnsNil() throws {
        let longString = String(repeating: "a", count: 101)
        let result = InputValidator.validateUserString(longString, maxLength: 100)
        #expect(result == nil)
    }

    @Test func stringAtMaxLengthIsAccepted() throws {
        let exactString = String(repeating: "a", count: 100)
        let result = InputValidator.validateUserString(exactString, maxLength: 100)
        #expect(result == exactString)
    }

    @Test func whitespaceIsTrimmed() throws {
        let result = InputValidator.validateUserString("  Hello  ", maxLength: 100)
        #expect(result == "Hello")
    }

    // MARK: - Control Character Tests

    @Test func nullCharacterIsRejected() throws {
        let stringWithNull = "Hello\u{0000}World"
        let result = InputValidator.validateUserString(stringWithNull, maxLength: 100)
        #expect(result == nil)
    }

    @Test func bellCharacterIsRejected() throws {
        let stringWithBell = "Hello\u{0007}World"
        let result = InputValidator.validateUserString(stringWithBell, maxLength: 100)
        #expect(result == nil)
    }

    @Test func backspaceCharacterIsRejected() throws {
        let stringWithBackspace = "Hello\u{0008}World"
        let result = InputValidator.validateUserString(stringWithBackspace, maxLength: 100)
        #expect(result == nil)
    }

    @Test func escapeCharacterIsRejected() throws {
        let stringWithEscape = "Hello\u{001B}World"
        let result = InputValidator.validateUserString(stringWithEscape, maxLength: 100)
        #expect(result == nil)
    }

    @Test func deleteCharacterIsRejected() throws {
        let stringWithDelete = "Hello\u{007F}World"
        let result = InputValidator.validateUserString(stringWithDelete, maxLength: 100)
        #expect(result == nil)
    }

    @Test func multipleControlCharactersAreRejected() throws {
        let stringWithMultiple = "Hello\u{0000}\u{0007}\u{001B}World"
        let result = InputValidator.validateUserString(stringWithMultiple, maxLength: 100)
        #expect(result == nil)
    }

    // MARK: - Unicode and Special Character Tests

    @Test func emojiIsAccepted() throws {
        let result = InputValidator.validateUserString("Hello 👋 World", maxLength: 100)
        #expect(result == "Hello 👋 World")
    }

    @Test func unicodeCharactersAreAccepted() throws {
        let result = InputValidator.validateUserString("Hello 世界 مرحبا", maxLength: 100)
        #expect(result == "Hello 世界 مرحبا")
    }

    @Test func specialCharactersAreAccepted() throws {
        let result = InputValidator.validateUserString("Hello!@#$%^&*()_+-=[]{}|;':\",./<>?", maxLength: 100)
        #expect(result == "Hello!@#$%^&*()_+-=[]{}|;':\",./<>?")
    }

    // MARK: - Nickname Validation Tests

    @Test func validNicknameIsAccepted() throws {
        let result = InputValidator.validateNickname("Alice")
        #expect(result == "Alice")
    }

    @Test func nicknameWithEmojiIsAccepted() throws {
        let result = InputValidator.validateNickname("Alice 🚀")
        #expect(result == "Alice 🚀")
    }

    @Test func nicknameTooLongIsRejected() throws {
        let longNickname = String(repeating: "a", count: 51)
        let result = InputValidator.validateNickname(longNickname)
        #expect(result == nil)
    }

    @Test func nicknameAtMaxLengthIsAccepted() throws {
        let exactNickname = String(repeating: "a", count: 50)
        let result = InputValidator.validateNickname(exactNickname)
        #expect(result == exactNickname)
    }

    @Test func nicknameWithControlCharacterIsRejected() throws {
        let result = InputValidator.validateNickname("Alice\u{0000}")
        #expect(result == nil)
    }

    // MARK: - Timestamp Validation Tests
    // BCH-01-011: Window reduced from ±1 hour to ±5 minutes

    @Test func currentTimestampIsValid() throws {
        let now = Date()
        let result = InputValidator.validateTimestamp(now)
        #expect(result == true)
    }

    @Test func timestampWithinFiveMinutesIsValid() throws {
        // 2 minutes ago should be valid (within 5-minute window)
        let twoMinutesAgo = Date().addingTimeInterval(-2 * 60)
        let result = InputValidator.validateTimestamp(twoMinutesAgo)
        #expect(result == true)
    }

    @Test func timestampThirtyMinutesAgoIsInvalid() throws {
        // BCH-01-011: 30 minutes is now outside the 5-minute window
        let thirtyMinutesAgo = Date().addingTimeInterval(-30 * 60)
        let result = InputValidator.validateTimestamp(thirtyMinutesAgo)
        #expect(result == false)
    }

    @Test func timestampTenMinutesAgoIsInvalid() throws {
        // 10 minutes is outside the 5-minute window
        let tenMinutesAgo = Date().addingTimeInterval(-10 * 60)
        let result = InputValidator.validateTimestamp(tenMinutesAgo)
        #expect(result == false)
    }

    @Test func timestampTenMinutesInFutureIsInvalid() throws {
        // 10 minutes in future is outside the 5-minute window
        let tenMinutesFromNow = Date().addingTimeInterval(10 * 60)
        let result = InputValidator.validateTimestamp(tenMinutesFromNow)
        #expect(result == false)
    }

    @Test func timestampAtFiveMinuteBoundaryIsValid() throws {
        // Just slightly within the five-minute window (299 seconds)
        let almostFiveMinutesAgo = Date().addingTimeInterval(-299)
        let result = InputValidator.validateTimestamp(almostFiveMinutesAgo)
        #expect(result == true)
    }

    @Test func timestampJustOutsideFiveMinuteWindowIsInvalid() throws {
        // Just outside the five-minute window (301 seconds)
        let justOverFiveMinutesAgo = Date().addingTimeInterval(-301)
        let result = InputValidator.validateTimestamp(justOverFiveMinutesAgo)
        #expect(result == false)
    }

    // MARK: - Edge Cases

    @Test func singleCharacterStringIsAccepted() throws {
        let result = InputValidator.validateUserString("a", maxLength: 100)
        #expect(result == "a")
    }

    @Test func stringWithOnlyNewlinesIsRejected() throws {
        let result = InputValidator.validateUserString("\n\n\n", maxLength: 100)
        #expect(result == nil)
    }

    @Test func stringWithMixedWhitespaceIsTrimmed() throws {
        let result = InputValidator.validateUserString(" \t\nHello\n\t ", maxLength: 100)
        #expect(result == "Hello")
    }

    @Test func stringWithLeadingControlCharacterIsRejected() throws {
        let result = InputValidator.validateUserString("\u{0000}Hello", maxLength: 100)
        #expect(result == nil)
    }

    @Test func stringWithTrailingControlCharacterIsRejected() throws {
        let result = InputValidator.validateUserString("Hello\u{0000}", maxLength: 100)
        #expect(result == nil)
    }
}
