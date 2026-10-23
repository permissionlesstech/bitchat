//
// ConversationTarget.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

/// Where something the person does in one composer goes: its text, its
/// commands and their output, its photos and its voice.
///
/// The selection (the store's active channel plus the open DM) says what the
/// screen shows. A target says where an action lands, captured when the
/// person commits to it. On a one-pane screen the two agree, and
/// `ChatViewModel.selectionTarget` is the selection as a target. With two
/// composers on screen each holds its own target, so nothing on the send
/// path has to read the selection to pick a destination.
struct ConversationTarget: Hashable {
    /// The channel for a public target. For a private one, the scope the
    /// conversation lives in: the channel whose identity signs a geohash DM,
    /// and the one its commands resolve names in and are checked against.
    let channel: ChannelID
    /// The DM: a mesh peer, a group (`group_`) or a geohash DM (`nostr_`).
    /// Nil for a public timeline.
    let privatePeer: PeerID?

    static let mesh = ConversationTarget(channel: .mesh, privatePeer: nil)

    static func publicChannel(_ channel: ChannelID) -> ConversationTarget {
        ConversationTarget(channel: channel, privatePeer: nil)
    }
}

extension ConversationTarget {
    var isPrivate: Bool { privatePeer != nil }

    /// The conversation this target writes into: the DM's thread, or the
    /// channel's timeline.
    var conversationID: ConversationID {
        privatePeer.map(ConversationID.directPeer) ?? ConversationID(channelID: channel)
    }

    /// Whether photos and voice can go here: #mesh and mesh DMs. Geohash
    /// channels and geohash DMs have no media transport, and groups don't
    /// carry media in v1 (the group recipient isn't a routable peer, so a
    /// placeholder would never send).
    var allowsMedia: Bool {
        if let peer = privatePeer {
            return !(peer.isGeoDM || peer.isGeoChat || peer.isGroup)
        }
        return channel.isMesh
    }

    /// The key this conversation's unsent text is parked under.
    /// `fingerprint` is the DM peer's Noise fingerprint when known, so a
    /// peer-ID handoff keeps the draft, and a held mic, with the person.
    func draftKey(fingerprint: String?) -> ComposerDraftStore.Key {
        .from(peerID: privatePeer, fingerprint: fingerprint, channel: channel)
    }
}

extension ChannelID {
    /// Whether this channel is live, `selected` being the store's selected
    /// channel. #mesh always is. A geohash only while it is the selected
    /// one: the app subscribes to that geohash alone and tracks only its
    /// participants and nicknames. A public send goes out only to a live
    /// channel, since a target still naming another geohash can only be
    /// stale, and a geohash's people are only known while it is live.
    func isLive(whileSelected selected: ChannelID) -> Bool {
        switch self {
        case .mesh:
            return true
        case .location:
            return ConversationID(channelID: self) == ConversationID(channelID: selected)
        }
    }
}

/// Where a composer lives, so state that belongs to one composer can tell
/// two composers apart: who owns the mic hold today, and each composer's
/// text and suggestions once the views move onto targets. `.primary` is the
/// composer under the main timeline. `.secondary` is the other
/// conversation's: the DM sheet's, or the trailing pane's on a split layout.
enum ComposerSlot: Hashable {
    case primary
    case secondary
}
