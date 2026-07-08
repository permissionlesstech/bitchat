//
// StoreAndForwardMetrics.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

/// Privacy-safe local counters for the store-and-forward stack: bare event
/// tallies with no message IDs, peer identities, or timestamps, so delivery
/// behavior can be measured on-device without recording who talked to whom.
/// Log-only surface — nothing here ever leaves the device.
final class StoreAndForwardMetrics {
    enum Event: String, CaseIterable {
        /// A private message entered the outbox (no prompt route available).
        case outboxQueued = "outbox.queued"
        /// A retained message was re-sent on a flush.
        case outboxResent = "outbox.resent"
        /// A delivery/read ack cleared a retained message.
        case outboxDelivered = "outbox.delivered"
        /// A retained message was dropped (attempt cap, TTL, or overflow).
        case outboxDropped = "outbox.dropped"
        /// We handed sealed mail to a courier.
        case courierDeposited = "courier.deposited"
        /// We accepted sealed mail to carry for a third party.
        case courierAccepted = "courier.accepted"
        /// We handed carried mail to its recipient over a direct link.
        case courierHandedOver = "courier.handedOver"
        /// We pushed carried mail toward a recipient heard via relay.
        case courierRemoteHandover = "courier.remoteHandover"
        /// We split spray copies to another courier.
        case courierSprayed = "courier.sprayed"
        /// Couriered mail addressed to us was opened and delivered.
        case courierOpened = "courier.opened"
    }

    static let shared = StoreAndForwardMetrics()

    private let lock = NSLock()
    private var counts: [String: Int]
    private let defaults: UserDefaults
    private static let defaultsKey = "chat.bitchat.storeAndForwardMetrics"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.counts = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Int] ?? [:]
    }

    func record(_ event: Event) {
        lock.lock()
        let total = (counts[event.rawValue] ?? 0) + 1
        counts[event.rawValue] = total
        defaults.set(counts, forKey: Self.defaultsKey)
        lock.unlock()
        SecureLogger.debug("📊 S&F \(event.rawValue) → \(total)", category: .session)
    }

    /// Included in the panic wipe alongside the stores it describes.
    func reset() {
        lock.lock()
        counts = [:]
        defaults.removeObject(forKey: Self.defaultsKey)
        lock.unlock()
    }
}
