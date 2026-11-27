import CoreBluetooth
import Foundation

/// The downward half of the link-layer port: the physical admissions the engine
/// asks of the bleQueue link layer, as an enumerable surface mirroring `BLELinkEvent`.
///
/// Slice 1 covers the peripheral-notify path (`notifyCentrals` and
/// `clearPendingNotifications`) while preserving the existing `engine ──sync──▶ bleQueue`
/// queue contract pinned by `BLEQueueContractTests`.
enum BLELinkCommand {
    /// Attempt to notify subscribed centrals on the peripheral characteristic.
    /// When `enqueueOnBackpressure` is true, a failed `updateValue` falls back to
    /// the peripheral pending-notification queue under `context`.
    case notifyCentrals(
        data: Data,
        characteristic: CBMutableCharacteristic,
        centrals: [CBCentral]?,
        enqueueOnBackpressure: Bool,
        context: String
    )

    /// Drop all queued peripheral notifications (e.g. during graceful shutdown).
    case clearPendingNotifications
}
