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
    /// Bounds queued pre-handshake control/media payloads per peer so a peer
    /// that never finishes a handshake cannot grow RAM without bound.
    static let maxTypedPayloadsPerPeer = 128

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
        let entry = BLEPendingTypedPayload(payload: payload, transferId: transferId)
        var queue = typedPayloadsByPeerID[peerID] ?? []
        // Deduplicate identical control payloads (e.g. repeated read/delivery
        // receipts queued before handshake completion).
        if transferId == nil, queue.contains(entry) {
            return
        }
        queue.append(entry)
        if queue.count > Self.maxTypedPayloadsPerPeer {
            // Prefer evicting the oldest non-media control payload over an
            // in-flight media transfer tracked by TransferProgressManager.
            if let controlIndex = queue.firstIndex(where: { $0.transferId == nil }) {
                queue.remove(at: controlIndex)
            } else {
                queue.removeFirst()
            }
        }
        typedPayloadsByPeerID[peerID] = queue
    }

    mutating func takeTypedPayloads(for peerID: PeerID) -> [BLEPendingTypedPayload] {
        let payloads = typedPayloadsByPeerID[peerID] ?? []
        typedPayloadsByPeerID.removeValue(forKey: peerID)
        return payloads
    }

    func containsTypedPayload(transferId: String) -> Bool {
        typedPayloadsByPeerID.values.contains { payloads in
            payloads.contains { $0.transferId == transferId }
        }
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
