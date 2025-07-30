//
// ChatViewModelTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

@MainActor
final class ChatViewModelTests: XCTestCase {
    private let sut = ChatViewModel()

    func testFormattingMessageAsTextWithAtInUrl() {
        let content = "https://www.example.com/@mention"
        let message = BitchatMessage(
            id: "",
            sender: "me",
            content: content,
            timestamp: .from(string: "21:37:00")!,
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: nil,
            mentions: nil
        )
        let attributed = sut.formatMessageAsText(message, colorScheme: .light)
        let string = String(attributed.characters)
        XCTAssertEqual(string, "<@me> https://www.example.com/@mention [21:37:00]")
    }
}

private extension Date {
    static func from(string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        return formatter.date(from: string)
    }
}
