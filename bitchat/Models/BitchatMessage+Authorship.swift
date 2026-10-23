//
// BitchatMessage+Authorship.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation

extension BitchatMessage {
    /// Whether this device wrote the row, judged by the sender ID it carries
    /// and never by its display name. Names collide: geochat shows everyone
    /// as `nick#<pubkey suffix>`, so a namesake reads `<my nick>#xxxx` and a
    /// stranger without a nickname tag reads `anon#xxxx`, while mesh peers,
    /// group members and bridged senders can carry my exact name.
    ///
    /// - A `system` row is never mine, although local DM system lines carry
    ///   my mesh peer ID.
    /// - A row without a sender ID (public system lines) is not mine.
    /// - A geochat row (`nostr:` + 8 hex) is mine when it carries the ID of my
    ///   identity for the location channel on screen, `myGeoChatPeerID`.
    /// - Every other row I write carries my mesh peer ID, `myPeerID`: mesh
    ///   public text and its echoes, mesh and geo DMs, group messages, media.
    ///
    /// Each ID is evaluated only for the kind of row that needs it.
    func isOwn(
        myPeerID: @autoclosure () -> PeerID,
        myGeoChatPeerID: @autoclosure () -> PeerID?
    ) -> Bool {
        guard sender != "system", let senderPeerID else { return false }
        if senderPeerID.isGeoChat {
            return senderPeerID == myGeoChatPeerID()
        }
        let myPeerID = myPeerID()
        return !myPeerID.isEmpty && senderPeerID == myPeerID
    }
}
