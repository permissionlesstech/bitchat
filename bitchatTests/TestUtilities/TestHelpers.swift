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
@testable import bitchat

final class TestHelpers {

    // MARK: - Message Creation
    
    static func createTestMessage(
        content: String = TestConstants.testMessage1,
        sender: String = TestConstants.testNickname1,
        senderPeerID: PeerID = PeerID(str: UUID().uuidString),
        isPrivate: Bool = false,
        recipientNickname: String? = nil,
        mentions: [String]? = nil
    ) -> BitchatMessage {
        return BitchatMessage(
            id: UUID().uuidString,
            sender: sender,
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: isPrivate,
            recipientNickname: recipientNickname,
            senderPeerID: senderPeerID,
            mentions: mentions
        )
    }
    
    static func createTestPacket(
        type: UInt8 = 0x01,
        senderID: PeerID = PeerID(str: UUID().uuidString),
        recipientID: PeerID? = nil,
        payload: Data = Data("test payload".utf8),
        signature: Data? = nil,
        ttl: UInt8 = 3
    ) -> BitchatPacket {
        return BitchatPacket(
            type: type,
            senderID: Data(senderID.id.utf8),
            recipientID: recipientID?.id.data(using: .utf8),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: signature,
            ttl: ttl
        )
    }
    
    // MARK: - Data Generation
    
    static func generateRandomData(length: Int) -> Data {
        var data = Data(count: length)
        _ = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, length, bytes.baseAddress!)
        }
        return data
    }

    // MARK: - Async Helpers
    
    static func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = TestConstants.defaultTimeout) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                throw TestError.timeout
            }
            try await sleep(0.01)
        }
    }

    @MainActor
    static func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = TestConstants.defaultTimeout,
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

enum TestError: Error {
    case timeout
}

// MARK: - Private chat seeding (ConversationStore migration)

extension ChatViewModel {
    /// Test-only replacement for the deleted `privateChats` setter: seeds a
    /// peer's chat through the single-writer `ConversationStore` intents
    /// (upsert keeps re-seeding with updated copies working the way the old
    /// dictionary assignment did).
    @MainActor
    func seedPrivateChat(_ messages: [BitchatMessage], for peerID: PeerID) {
        _ = conversations.conversation(for: .directPeer(peerID))
        for message in messages {
            conversations.upsertByID(message, in: .directPeer(peerID))
        }
    }

    /// Test-only replacement for the deleted `messages` setter: seeds a
    /// public channel's conversation through the single-writer
    /// `ConversationStore` intents (upsert keeps re-seeding with updated
    /// copies working the way the old array assignment did).
    @MainActor
    func seedPublicMessages(_ messages: [BitchatMessage], for channel: ChannelID = .mesh) {
        for message in messages {
            conversations.upsertByID(message, in: ConversationID(channelID: channel))
        }
    }

}

func sleep(_ seconds: TimeInterval) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}
