import BitFoundation
import Foundation

struct BLEPendingPrivateMessage: Equatable {
    let content: String
    let messageID: String
}

struct BLEPendingTypedPayload: Equatable {
    let payload: Data
    /// Present for app-initiated media so handshake queuing preserves the
    /// fragment scheduler's progress/cancellation identity.
    let transferId: String?
}

struct BLENoiseSessionQueues {
    private var privateMessagesByPeerID: [PeerID: [BLEPendingPrivateMessage]] = [:]
    private var typedPayloadsByPeerID: [PeerID: [BLEPendingTypedPayload]] = [:]

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

    mutating func appendTypedPayload(_ payload: Data, transferId: String? = nil, for peerID: PeerID) {
        typedPayloadsByPeerID[peerID, default: []].append(
            BLEPendingTypedPayload(payload: payload, transferId: transferId)
        )
    }

    mutating func takeTypedPayloads(for peerID: PeerID) -> [BLEPendingTypedPayload] {
        let payloads = typedPayloadsByPeerID[peerID] ?? []
        typedPayloadsByPeerID.removeValue(forKey: peerID)
        return payloads
    }

    @discardableResult
    mutating func removeTypedPayload(transferId: String) -> Bool {
        for peerID in Array(typedPayloadsByPeerID.keys) {
            guard var payloads = typedPayloadsByPeerID[peerID],
                  let index = payloads.firstIndex(where: { $0.transferId == transferId }) else {
                continue
            }
            payloads.remove(at: index)
            typedPayloadsByPeerID[peerID] = payloads.isEmpty ? nil : payloads
            return true
        }
        return false
    }
}
