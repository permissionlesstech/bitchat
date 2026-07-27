import BitFoundation
import Foundation

struct BLEDirectedRelaySpoolEntry {
    let recipient: PeerID
    let packet: BitchatPacket
}

struct BLEDirectedRelaySpool {
    private struct StoredPacket {
        let packet: BitchatPacket
        let enqueuedAt: Date
    }

    private var packetsByRecipient: [PeerID: [String: StoredPacket]] = [:]

    var isEmpty: Bool {
        packetsByRecipient.isEmpty
    }

    var count: Int {
        packetsByRecipient.values.reduce(0) { $0 + $1.count }
    }

    @discardableResult
    mutating func enqueue(
        packet: BitchatPacket,
        recipient: PeerID,
        messageID: String,
        enqueuedAt: Date
    ) -> Bool {
        var packets = packetsByRecipient[recipient] ?? [:]
        guard packets[messageID] == nil else {
            return false
        }

        packets[messageID] = StoredPacket(packet: packet, enqueuedAt: enqueuedAt)
        packetsByRecipient[recipient] = packets
        return true
    }

    mutating func drainUnexpired(now: Date, window: TimeInterval) -> [BLEDirectedRelaySpoolEntry] {
        var entries: [BLEDirectedRelaySpoolEntry] = []

        for (recipient, packets) in packetsByRecipient {
            for stored in packets.values where now.timeIntervalSince(stored.enqueuedAt) <= window {
                entries.append(BLEDirectedRelaySpoolEntry(recipient: recipient, packet: stored.packet))
            }
        }

        packetsByRecipient.removeAll()
        return entries
    }

    mutating func pruneExpired(now: Date, window: TimeInterval) {
        guard !packetsByRecipient.isEmpty else { return }

        var pruned: [PeerID: [String: StoredPacket]] = [:]
        for (recipient, packets) in packetsByRecipient {
            let freshPackets = packets.filter { now.timeIntervalSince($0.value.enqueuedAt) <= window }
            if !freshPackets.isEmpty {
                pruned[recipient] = freshPackets
            }
        }
        packetsByRecipient = pruned
    }

    mutating func removeAll() {
        packetsByRecipient.removeAll()
    }
}
