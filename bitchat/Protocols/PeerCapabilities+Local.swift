import BitFoundation

extension PeerCapabilities {
    /// Capabilities this build advertises in its announce packets.
    /// Each feature adds its bit here when it ships.
    static let localSupported: PeerCapabilities = {
        let capabilities: PeerCapabilities = [
            .vouch,
            .prekeys,
            .groups,
            .privateMedia,
            .privateMediaReceipts
        ]
        return DoubleRatchetFeature.isEnabled
            ? capabilities.union(.doubleRatchet) : capabilities
    }()
}
