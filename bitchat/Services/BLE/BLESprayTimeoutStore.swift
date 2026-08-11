import Foundation

/// Identifies one outstanding spray offer. Mirrors `CourierStore`'s own
/// pending-offer key so an ack, a decline, or the assume-delivered timeout
/// all resolve the same entry.
struct BLESprayTimeoutKey: Hashable {
    let ciphertextHash: Data
    let courierNoiseKey: Data
}

/// Lock-backed assume-delivered timeouts for spray copies handed to a
/// `.courierAck`-capable taker.
///
/// This holds only the `DispatchWorkItem`s, for cancellation. The offer and
/// budget state lives in `CourierStore` behind its own serial queue; the
/// transport just calls `offerSprayCopies`/`confirmSpray`/`cancelSpray`.
///
/// Lock-backed rather than engine-confined because the two ends run in
/// different contexts: offers are armed on the main actor (inside the
/// `notifyUI` hop that decides whether to hand mail to a peer), while acks,
/// declines, and the timeout itself run on the engine queue. A leaf lock is
/// safe from both; re-entering the engine from the main actor is not.
///
/// Every method is one whole transition under the lock, so an ack and the
/// timeout racing for the same offer cannot both claim it.
final class BLESprayTimeoutStore: @unchecked Sendable {
    private let lock = NSLock()
    private var timeouts: [BLESprayTimeoutKey: DispatchWorkItem] = [:]

    /// Arms the timeout for one offer, cancelling any prior timeout for the
    /// same key. Commit-time revalidation in `offerSprayCopies` means at most
    /// one copy per courier is committed for an envelope, but a re-announce
    /// can arm a timeout before the losing commit no-ops — so the latest wins.
    func arm(_ key: BLESprayTimeoutKey, timeout: DispatchWorkItem) {
        lock.withLock {
            timeouts.removeValue(forKey: key)?.cancel()
            timeouts[key] = timeout
        }
    }

    /// Cancels the timeout for a resolved offer. A no-op when the timeout
    /// already fired or the offer was never armed.
    func cancel(_ key: BLESprayTimeoutKey) {
        lock.withLock { timeouts.removeValue(forKey: key)?.cancel() }
    }

    /// Claims the offer on behalf of a firing timeout. Returns false when an
    /// ack or decline already resolved it, so the timeout must not commit the
    /// spend a second time.
    func claim(_ key: BLESprayTimeoutKey) -> Bool {
        lock.withLock { timeouts.removeValue(forKey: key) != nil }
    }
}
