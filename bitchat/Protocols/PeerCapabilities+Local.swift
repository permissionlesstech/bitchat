import BitFoundation

extension PeerCapabilities {
    /// Understands and may send Sonar sticker references (`␟sticker␟…`
    /// message content; see `docs/SONAR-STICKERS.md`).
    ///
    /// Bit 10 stays reserved (`nonDestructiveNoiseReplacement`, kept
    /// decodable in BitFoundation), so stickers takes bit 11. The canonical
    /// bitfield lives in `localPackages/BitFoundation/.../PeerCapabilities.swift`;
    /// this declaration should move there with the next BitFoundation bump.
    static let stickers = PeerCapabilities(rawValue: 1 << 11)

    /// Capabilities this build advertises in its announce packets.
    /// Each feature adds its bit here when it ships.
    static let localSupported: PeerCapabilities = [
        .vouch,
        .prekeys,
        .groups,
        .privateMedia,
        .privateMediaReceipts,
        .stickers
    ]
}
