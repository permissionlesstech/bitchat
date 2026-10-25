import BitFoundation

extension PeerCapabilities {
    /// Base capabilities, combined with transport-specific runtime bits.
    /// BLEService adds NDR according to its configured feature gate.
    static let localSupported: PeerCapabilities = [
        .vouch,
        .prekeys,
        .groups,
        .privateMedia,
        .privateMediaReceipts
    ]
}
