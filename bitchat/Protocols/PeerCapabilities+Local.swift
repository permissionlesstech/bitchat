import BitFoundation

extension PeerCapabilities {
    /// Capabilities this build advertises in its announce packets.
    /// Each feature adds its bit here when it ships.
    static let localSupported: PeerCapabilities = {
        var caps: PeerCapabilities = [.prekeys, .vouch, .groups]
        if TransportConfig.wifiBulkEnabled { caps.insert(.wifiBulk) }
        return caps
    }()
}
