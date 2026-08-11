import BitFoundation

extension PeerCapabilities {
    // NOTE: a `.stickers` bit is RESERVED at bit 13 but intentionally not
    // declared or advertised in v1 — sticker refs ride as ordinary message
    // content and need no capability negotiation (old clients render the
    // literal text; see `docs/SONAR-STICKERS.md`). Bit 11 is claimed by
    // #1107 (double ratchet) and bit 12 by #1438 (spray recovery); bit 10
    // stays reserved (`nonDestructiveNoiseReplacement`). Declare the bit
    // here — or in BitFoundation on the next bump — when inline-BLE sticker
    // delivery (Approach B) ships.

    /// Capabilities this build advertises in its announce packets.
    /// Each feature adds its bit here when it ships.
    static let localSupported: PeerCapabilities = [
        .vouch,
        .prekeys,
        .groups,
        .privateMedia,
        .privateMediaReceipts
    ]
}
