// ChatViewModel+Stickers.swift
// bitchat
//
// Sonar sticker send support for ChatViewModel.

import BitFoundation
import BitLogger
import Foundation

/// Sonar sticker send + service accessors for `ChatViewModel`.
///
/// A sticker is an ordinary text message whose content is the `StickerRef`
/// wire string (`␟sticker␟<coordinate>␟<shortcode>␟<sha256>`). It rides the
/// same private/public router as plain text, so sending only needs to build
/// the validated ref and hand its `.content` to `sendMessage(_:)` — the
/// existing dispatch (selected DM peer vs active public/geohash channel)
/// decides exactly where it lands, identical to typing the message.
extension ChatViewModel {

    /// Shared pack metadata + image resolver (see `StickerPackService`).
    var stickerPackService: StickerPackService { .shared }

    /// Installed-pack list + opt-in Nostr sync (kind 10031).
    ///
    /// `StickerInstallStore` persists its installed list and `syncEnabled`
    /// flag to `UserDefaults.standard` and a deterministic file under
    /// Application Support, so every instance observes the same state. A
    /// Swift extension cannot add a stored property, so this returns a fresh
    /// instance per access — actor construction is cheap (it reads one JSON
    /// sidecar) and the persisted state is shared. This keeps `AppRuntime`
    /// wiring untouched, since the store works with no constructor args
    /// (it builds its own `NostrIdentityBridge` internally).
    var stickerInstallStore: StickerInstallStore { StickerInstallStore() }

    /// Sends a sticker reference as an ordinary message in the current
    /// conversation (selected private peer, public mesh, or geohash channel).
    ///
    /// Routing reuses `sendMessage(_:)`, which already dispatches to the
    /// selected private peer or the active public channel — exactly the
    /// conversation the picker was presented in. `peerID` is accepted for API
    /// clarity; the actual target matches where a plain text send would land,
    /// which is how existing sends (private and public) already work.
    @MainActor
    func sendSticker(
        packCoordinate: String,
        shortcode: String,
        plaintextSha256: String,
        to peerID: PeerID?
    ) {
        guard let ref = StickerRef(
            packCoordinate: packCoordinate,
            shortcode: shortcode,
            plaintextSha256: plaintextSha256
        ) else {
            SecureLogger.warning(
                "Sticker send rejected: invalid ref fields",
                category: .session
            )
            return
        }
        sendMessage(ref.content)
    }
}
