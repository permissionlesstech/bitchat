//
// ReadReceipt.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import BitFoundation

struct ReadReceipt: Codable {
    let originalMessageID: String
    var readerID: PeerID  // Who read it
    let readerNickname: String
    let timestamp: Date

    init(originalMessageID: String, readerID: PeerID, readerNickname: String) {
        self.originalMessageID = originalMessageID
        self.readerID = readerID
        self.readerNickname = readerNickname
        self.timestamp = Date()
    }
}
