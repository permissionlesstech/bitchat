//
// ContentPanePolicy.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)
import BitFoundation
import CoreGraphics

/// The two panes of the split layout (regular width with room for two
/// columns: the iPhone Duo's inner display).
enum ContentPane: Hashable {
    /// #mesh, always: its own bar, timeline and composer.
    case leading
    /// One of the open DM, the selected geohash channel or the inline
    /// location-channel picker (`TrailingPaneContent`).
    case trailing

    /// The pane a touch landed in, from both panes' frames in the touch's
    /// coordinate space (the window's). The frames decide, never the side:
    /// right to left, the leading pane is the one on the right. Nil in the
    /// gap between the panes or outside both.
    static func containing(
        _ point: CGPoint,
        leading: CGRect,
        trailing: CGRect
    ) -> ContentPane? {
        if leading.contains(point) { return .leading }
        if trailing.contains(point) { return .trailing }
        return nil
    }
}

/// What the split layout's trailing pane shows: exactly one of these.
enum TrailingPaneContent: Hashable {
    /// The open DM (mesh DM, group or geohash DM). It covers the channel
    /// for as long as it is open; ending it brings the channel, or the
    /// picker, back.
    case conversation(PeerID)
    /// The selected geohash channel: its bar, timeline and composer.
    case channel(GeohashChannel)
    /// The location-channel picker, inline. `returnTo` is the geohash a
    /// person is browsing away from (its close control returns there); nil
    /// is the idle picker: no location channel is selected.
    case picker(returnTo: GeohashChannel?)

    /// - Parameters:
    ///   - conversation: The open DM, if any.
    ///   - channel: The channel the trailing timeline renders: the selected
    ///     location channel, where `.mesh` means none (the idle picker).
    ///   - isBrowsing: The person tapped the trailing bar's #geohash badge
    ///     to switch channels.
    static func resolve(
        conversation: PeerID?,
        channel: ChannelID,
        isBrowsing: Bool
    ) -> TrailingPaneContent {
        if let conversation { return .conversation(conversation) }
        guard case .location(let geohash) = channel else {
            // Nothing to browse away from: browsing without a channel is
            // the idle picker.
            return .picker(returnTo: nil)
        }
        return isBrowsing ? .picker(returnTo: geohash) : .channel(geohash)
    }

    /// Whether a screenshot of the pane reveals a place (E10): a geohash
    /// timeline, or the picker with its nearby cells and bookmarks. A DM
    /// gets today's DM handling and no location warning.
    var showsLocation: Bool {
        if case .conversation = self { return false }
        return true
    }

    /// Whether the pane has a channel bar (E13): the trailing people
    /// popover's anchor, so the popover can't outlive it.
    var hostsChannelHeader: Bool {
        if case .channel = self { return true }
        return false
    }
}

/// Screenshot routing's view of the layout: `AppChromeModel
/// .splitLayoutShowsLocation` (E10), whether a screenshot of the split layout
/// shows a place. Nil for the single column, where the selection and the DM
/// sheet decide.
enum SplitLayoutScreenshotPolicy {
    /// #1792's two columns, until the panes replace them: the selected
    /// channel's timeline leads, beside the people list or a DM, so the
    /// selection alone says whether a place is on screen.
    static func columnsShowLocation(isSplit: Bool, selectedChannel: ChannelID) -> Bool? {
        isSplit ? selectedChannel.isLocation : nil
    }

    /// The panes: #mesh leads and shows no place, so the trailing pane
    /// decides. Re-read on every change of what it shows, the landing of an
    /// asynchronous selection included.
    static func panesShowLocation(isSplit: Bool, trailing: TrailingPaneContent) -> Bool? {
        isSplit ? trailing.showsLocation : nil
    }
}

/// Fold and unfold between the split layout and the single column (E2-E5).
/// Folding shows the last-touched pane; unfolding restores the other one
/// from what the fold set aside.
enum PaneFoldPolicy {
    /// What a fold with the focus on #mesh set aside for the next unfold. In
    /// memory only: it must not survive a relaunch, and panic drops it (E6).
    struct Parked: Equatable {
        var channel: GeohashChannel?
        var conversation: PeerID?

        static let none = Parked()
    }

    struct Fold: Equatable {
        /// What the single column shows: the selection, or #mesh where the
        /// fold parks a geohash (select it if it differs from the
        /// selection).
        let channel: ChannelID
        /// End the open DM: its peer is parked. False keeps an open DM,
        /// which comes along as today's sheet.
        let endsConversation: Bool
        let parked: Parked
    }

    struct Unfold: Equatable {
        /// The parked geohash to select again for the trailing pane. Nil
        /// keeps the selection: the single column's geohash, or the idle
        /// picker on #mesh.
        let reselect: GeohashChannel?
        /// The parked DM to reopen over the trailing pane.
        let reopenConversation: PeerID?
        let focus: ContentPane
    }

    /// - Parameters:
    ///   - focus: The last-touched pane (E1).
    ///   - trailing: What the trailing pane shows. It names the geohash on
    ///     screen, or the one a person is browsing away from.
    ///   - selectedChannel: The selected location channel: the channel
    ///     under an open DM.
    ///   - openPeer: The open DM, if any.
    static func fold(
        focus: ContentPane,
        trailing: TrailingPaneContent,
        selectedChannel: ChannelID,
        openPeer: PeerID?
    ) -> Fold {
        let geohash = trailingGeohash(trailing, selectedChannel: selectedChannel)
        // A geohash DM needs its geohash live, so a fold from #mesh keeps
        // it as a fold from the trailing pane would (E3's exception).
        let keepsTrailing = focus == .trailing
            || openPeer.map(isGeohashConversation) == true
        guard !keepsTrailing else {
            // E2: the selected channel, with any open DM as the sheet over
            // it. The idle picker folds to #mesh.
            return Fold(
                channel: geohash.map(ChannelID.location) ?? .mesh,
                endsConversation: false,
                parked: .none
            )
        }
        // E3: #mesh; the geohash and a mesh DM or group wait for the unfold.
        return Fold(
            channel: .mesh,
            endsConversation: openPeer != nil,
            parked: Parked(channel: geohash, conversation: openPeer)
        )
    }

    /// The parked state is consumed: whatever the unfold doesn't restore is
    /// dropped (E4).
    /// - Parameters:
    ///   - compactChannel: What the single column showed.
    ///   - openPeer: The DM open in the single column (its sheet), if any.
    static func unfold(
        compactChannel: ChannelID,
        openPeer: PeerID?,
        parked: Parked
    ) -> Unfold {
        if case .location = compactChannel {
            // The geohash moves to the trailing pane, with an open DM over
            // it. Nothing parked survives a location choice anyway (E5).
            return Unfold(reselect: nil, reopenConversation: nil, focus: .trailing)
        }
        // From #mesh: the parked geohash returns (else the idle picker);
        // a DM opened while folded wins over the parked one.
        return Unfold(
            reselect: parked.channel,
            reopenConversation: openPeer == nil ? parked.conversation : nil,
            focus: openPeer == nil ? .leading : .trailing
        )
    }

    /// E5: choosing any location channel while folded drops everything
    /// parked. #mesh changes nothing: neither re-selecting it while on it,
    /// nor the echo of the fold's own `select(.mesh)`, which lands
    /// asynchronously after the parked state is set.
    static func parked(
        _ parked: Parked,
        afterCompactSelection channel: ChannelID
    ) -> Parked {
        channel.isLocation ? .none : parked
    }

    /// E5: opening any DM while folded drops the parked peer. A DM closing
    /// drops nothing: while a peer is parked, the only DM that can close is
    /// one opened since (whose opening already dropped it) or the parked
    /// DM itself, ended by the fold (the echo, which must keep it).
    /// - Parameter openPeer: The DM open after the change; nil after a
    ///   close.
    static func parked(
        _ parked: Parked,
        afterCompactConversationChange openPeer: PeerID?
    ) -> Parked {
        guard openPeer != nil else { return parked }
        return Parked(channel: parked.channel, conversation: nil)
    }

    /// A geohash DM (or a DM keyed by a geohash participant): it signs with
    /// the geohash identity, so it needs its geohash live.
    static func isGeohashConversation(_ peer: PeerID) -> Bool {
        peer.isGeoDM || peer.isGeoChat
    }

    /// The geohash on screen in the trailing pane, the one being browsed
    /// away from, or, under a DM, the selected one.
    private static func trailingGeohash(
        _ trailing: TrailingPaneContent,
        selectedChannel: ChannelID
    ) -> GeohashChannel? {
        switch trailing {
        case .channel(let geohash):
            return geohash
        case .picker(let returnTo):
            return returnTo
        case .conversation:
            guard case .location(let geohash) = selectedChannel else { return nil }
            return geohash
        }
    }
}

/// When the split layout's people popovers close (E13). SwiftUI dismisses a
/// popover whose anchor leaves without writing its binding back, which
/// would keep the root's alerts deferred for good; each of these events
/// clears the state instead.
enum PeoplePopoverPolicy {
    enum Event: Equatable {
        /// The device folded or unfolded.
        case layoutChange
        case panic
        /// A DM opened, from anywhere.
        case conversationOpened
        /// The trailing pane's content changed; its bar may have gone.
        case trailingContentChange(from: TrailingPaneContent, to: TrailingPaneContent)
    }

    /// The pane whose popover stays open after `event`, if any.
    static func pane(_ open: ContentPane?, after event: Event) -> ContentPane? {
        switch event {
        case .layoutChange, .panic, .conversationOpened:
            return nil
        case .trailingContentChange(let from, let to):
            // #mesh's bar never leaves the split layout; the trailing bar
            // comes and goes with the trailing content.
            return open == .trailing && from != to ? nil : open
        }
    }
}
#endif
