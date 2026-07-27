import Foundation

enum BLEPacketFreshnessPolicy {
    static let defaultMaxAgeSeconds: TimeInterval = 900

    static func isBroadcastRecipient(_ recipientID: Data?) -> Bool {
        guard let recipientID else { return true }
        return recipientID.count == 8 && recipientID.allSatisfy { $0 == 0xFF }
    }

    static func isStale(
        timestampMilliseconds: UInt64,
        now: Date,
        maxAgeSeconds: TimeInterval = defaultMaxAgeSeconds
    ) -> Bool {
        let nowMilliseconds = UInt64(now.timeIntervalSince1970 * 1000)
        let maxAgeMilliseconds = UInt64(maxAgeSeconds * 1000)
        guard nowMilliseconds >= maxAgeMilliseconds else { return false }
        return timestampMilliseconds < nowMilliseconds - maxAgeMilliseconds
    }

    static func ageSeconds(timestampMilliseconds: UInt64, now: Date) -> Double {
        let nowMilliseconds = UInt64(now.timeIntervalSince1970 * 1000)
        guard nowMilliseconds >= timestampMilliseconds else { return 0 }
        return Double(nowMilliseconds - timestampMilliseconds) / 1000.0
    }
}
