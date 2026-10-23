//
// MessageListChannelPolicy.swift
// bitchat
//
// What a message list draws around its rows (the nearby-notes strip and its
// counter hold, the empty-timeline narration, the ambient footer), decided by
// the timeline the list renders. Kept free of SwiftUI so the decisions are
// unit-testable.
//

import BitFoundation

struct MessageListChannelPolicy {
    /// The narration an empty public timeline shows.
    enum EmptyState: Equatable {
        /// The mesh radar, sightings and nearby hints.
        case mesh
        /// Names the geohash and points at the channel switcher.
        case location(geohash: String)
    }

    /// The public channel the list renders; nil for a private conversation.
    private let publicChannel: ChannelID?

    /// - Parameters:
    ///   - channel: The channel of the list's own timeline model, never the
    ///     selection: the split layout's #mesh list renders beside a selected
    ///     geohash. Nil for a private timeline model.
    ///   - privatePeer: The private conversation the list shows, if any.
    init(channel: ChannelID?, privatePeer: PeerID?) {
        publicChannel = privatePeer == nil ? channel : nil
    }

    /// Whether the list holds the nearby-notes counter: the #mesh timeline
    /// only, whose notes strip needs a live count before it can show.
    var holdsNotesCounter: Bool {
        publicChannel?.isMesh == true
    }

    /// Whether the strip of notes left at this place sits above the rows.
    func showsNotesStrip(noteCount: Int) -> Bool {
        holdsNotesCounter && noteCount > 0
    }

    /// What the list shows while its timeline is empty; nil for a private
    /// conversation.
    var emptyState: EmptyState? {
        switch publicChannel {
        case .mesh:
            return .mesh
        case .location(let channel):
            return .location(geohash: channel.geohash)
        case nil:
            return nil
        }
    }

    /// Whether the ambient layer (radar, sightings, live hints) follows the
    /// rows: on #mesh, while they are only carried history and system lines,
    /// i.e. no live conversation yet.
    func showsAmbientFooter<Rows: Collection>(below rows: Rows) -> Bool where Rows.Element == BitchatMessage {
        guard publicChannel?.isMesh == true, !rows.isEmpty else { return false }
        return rows.allSatisfy { $0.isArchivedEcho || $0.sender == "system" }
    }
}
