import BitFoundation
import Foundation

struct BLEPendingPrivateMessage: Equatable {
    let content: String
    let messageID: String
}

struct BLENoiseSessionQueues {
    private var privateMessagesByPeerID: [PeerID: [BLEPendingPrivateMessage]] = [:]
    private var typedPayloadsByPeerID: [PeerID: [Data]] = [:]

    var isEmpty: Bool {
        privateMessagesByPeerID.isEmpty && typedPayloadsByPeerID.isEmpty
    }

    mutating func removeAll() {
        privateMessagesByPeerID.removeAll()
        typedPayloadsByPeerID.removeAll()
    }

    mutating func appendPrivateMessage(content: String, messageID: String, for peerID: PeerID) {
        privateMessagesByPeerID[peerID, default: []].append(BLEPendingPrivateMessage(content: content, messageID: messageID))
    }

    mutating func takePrivateMessages(for peerID: PeerID) -> [BLEPendingPrivateMessage] {
        let messages = privateMessagesByPeerID[peerID] ?? []
        privateMessagesByPeerID.removeValue(forKey: peerID)
        return messages
    }

    mutating func prependPrivateMessages(_ messages: [BLEPendingPrivateMessage], for peerID: PeerID) {
        guard !messages.isEmpty else { return }
        privateMessagesByPeerID[peerID, default: []].insert(contentsOf: messages, at: 0)
    }

    mutating func appendTypedPayload(_ payload: Data, for peerID: PeerID) {
        typedPayloadsByPeerID[peerID, default: []].append(payload)
    }

    mutating func takeTypedPayloads(for peerID: PeerID) -> [Data] {
        let payloads = typedPayloadsByPeerID[peerID] ?? []
        typedPayloadsByPeerID.removeValue(forKey: peerID)
        return payloads
    }
}
