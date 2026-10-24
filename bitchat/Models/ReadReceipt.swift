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
    let receiptID: String
    var readerID: PeerID  // Who read it
    let readerNickname: String
    let timestamp: Date
    
    init(originalMessageID: String, readerID: PeerID, readerNickname: String) {
        self.originalMessageID = originalMessageID
        self.receiptID = UUID().uuidString
        self.readerID = readerID
        self.readerNickname = readerNickname
        self.timestamp = Date()
    }
    
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> ReadReceipt? {
        try? JSONDecoder().decode(ReadReceipt.self, from: data)
    }
}
