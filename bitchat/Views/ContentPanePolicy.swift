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

    /// The pane `slot`'s composer sits in: #mesh's is the primary, the
    /// trailing pane's the secondary.
    init(composer slot: ComposerSlot) {
        self = slot == .primary ? .leading : .trailing
    }

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
    /// A geohash selected for the pane that the timeline hasn't landed on
    /// yet: an unfold re-selecting the parked geohash, a launch with a
    /// persisted one, a choice still on its way. A neutral placeholder
    /// holds the pane meanwhile: the picker would mount and ask for a
    /// location fix for a pane about to show the geohash.
    case landing(GeohashChannel)

    /// - Parameters:
    ///   - conversation: The open DM, if any.
    ///   - channel: The channel the trailing timeline renders: the selected
    ///     location channel, where `.mesh` means none (the idle picker).
    ///   - selection: The location channel selected for the pane, which
    ///     runs a hop or more ahead of the timeline.
    ///   - isBrowsing: The person tapped the trailing bar's #geohash badge
    ///     to switch channels.
    static func resolve(
        conversation: PeerID?,
        channel: ChannelID,
        selection: ChannelID,
        isBrowsing: Bool
    ) -> TrailingPaneContent {
        if let conversation { return .conversation(conversation) }
        guard case .location(let geohash) = channel else {
            // No geohash on screen: one on its way holds the pane;
            // otherwise the idle picker (browsing without a channel is the
            // idle picker too).
            if case .location(let landing) = selection {
                return .landing(landing)
            }
            return .picker(returnTo: nil)
        }
        return isBrowsing ? .picker(returnTo: geohash) : .channel(geohash)
    }

    /// Whether a screenshot of the pane reveals a place (E10): a geohash
    /// timeline, the picker with its nearby cells and bookmarks, or a
    /// geohash about to show. A DM gets today's DM handling and no location
    /// warning.
    var showsLocation: Bool {
        if case .conversation = self { return false }
        return true
    }

    /// The geohash the trailing composer works in
    /// (`ComposerTargets.split`): the channel on screen or, for a DM
    /// covering it, the geohash that DM was opened over, which scopes a
    /// geohash DM. Never the timeline under a DM: a selection made beside
    /// it (a #geohash link or the nearby hint in #mesh) must not move a
    /// geohash DM onto another geohash's identity. Nil for the picker,
    /// which has no composer, and for a DM opened over no geohash.
    /// - Parameter conversationGeohash: The geohash the open DM was opened
    ///   over (`SplitPaneState.conversationGeohash`).
    func composerGeohash(conversationGeohash: GeohashChannel?) -> GeohashChannel? {
        switch self {
        case .channel(let geohash):
            return geohash
        case .conversation:
            return conversationGeohash
        case .picker, .landing:
            return nil
        }
    }
}

/// Which public timeline model a pane's message list renders. Each list is
/// keyed by it, so a mounted list never has its `PublicChatModel` swapped
/// for another (#1790's deferred scroll closures read the previous render).
enum PaneRole: Hashable {
    /// The pinned #mesh timeline (`AppRuntime.meshPaneTimeline`): the
    /// split layout's leading pane.
    case mesh
    /// The selection's timeline: the single column's, and the split
    /// layout's trailing geohash.
    case following
}

/// Screenshot routing's view of the layout: `AppChromeModel
/// .splitLayoutShowsLocation` (E10), whether a screenshot of the split layout
/// shows a place. Nil for the single column, where the selection and the DM
/// sheet decide.
enum SplitLayoutScreenshotPolicy {
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
        /// picker on #mesh (where a geohash DM opened while folded stays).
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
        // a DM opened while folded wins over the parked one. A geohash DM
        // opened while folded keeps #mesh, where its sends fail into the
        // thread as they did in the single column: re-selecting the parked
        // geohash under it would sign it with that geohash's identity,
        // which nobody chose for it (E3's exception, mirrored).
        let keepsMesh = openPeer.map(isGeohashConversation) == true
        return Unfold(
            reselect: keepsMesh ? nil : parked.channel,
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
        case .channel(let geohash), .landing(let geohash):
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

/// The split layout's own state, and how each event moves it: the
/// last-touched pane (E1), browsing (E7), the people popovers (E13), what a
/// fold parks (E2-E6, E8) and what a panic wipes (I4). Pure: `ContentView`
/// keeps one, hands it every event, and carries out the effects an event
/// returns. It never reads the selection or the open DM itself; each event
/// brings what it needs.
struct SplitPaneState: Equatable {
    /// The last-touched pane: the one a fold keeps on screen.
    private(set) var focus: ContentPane = .leading
    /// The trailing pane shows the picker over the selected geohash: the
    /// person tapped the trailing #geohash badge to switch channels.
    private(set) var isBrowsing = false
    /// The pane whose people popover is up.
    private(set) var popover: ContentPane?
    /// What a fold from #mesh set aside for the next unfold. In memory
    /// only, and wiped by panic (E6).
    private(set) var parked = PaneFoldPolicy.Parked.none
    /// The channel a fold selected for the single column, until the
    /// timeline lands on it: the single column's composer sends there
    /// meanwhile, so the fold never routes it through the channel it
    /// leaves.
    private(set) var foldChannel: ChannelID?
    /// The open DM as last reported. A report repeating it changes
    /// nothing, so the DM a fold ends or an unfold reopens, already
    /// recorded here, doesn't count again when its own report comes in;
    /// nor does a report handing it to another ID of the same person.
    private(set) var conversation: PeerID?
    /// The geohash the open DM was opened over, when it is a geohash DM in
    /// the split layout: the trailing pane's geohash as the DM opened over
    /// it, or the single column's as one moved across on unfold. It scopes
    /// the DM, the identity that signs it (`composerTargets`), for as long
    /// as the DM stays open, whatever is selected beside it; the DM ends
    /// once the trailing timeline leaves it. Nil for a mesh DM or group, for
    /// a geohash DM opened over no geohash (the idle picker, or #mesh before
    /// an unfold), which stays on #mesh and fails closed there as in the
    /// single column, and while folded, where the selection scopes it.
    private(set) var conversationGeohash: GeohashChannel?
    /// The parked geohash an unfold selected again, until the selection
    /// says so itself or the trailing timeline lands on a geohash: `select`
    /// applies a hop after the unfold, and the timeline follows later
    /// still. The trailing pane holds its placeholder for it meanwhile
    /// (`TrailingPaneContent.landing`) rather than mount the picker.
    private(set) var landingChannel: GeohashChannel?

    /// What `ContentView` does for an event, besides the state change.
    struct Effects: Equatable {
        /// Select this channel.
        var select: ChannelID?
        /// End the open DM.
        var endsConversation = false
        /// Open the DM with this peer.
        var reopensConversation: PeerID?
        /// Close the location channels sheet.
        var closesLocationSheet = false
        /// Close the notices sheet: the selection it opened over is about to
        /// change under it.
        var closesNoticesSheet = false
    }

    // MARK: Layout changes

    /// The device folds (E2, E3): the single column shows the last-touched
    /// pane, and a fold from #mesh parks the trailing pane. Browsing ends
    /// and the popovers close.
    /// - Parameters:
    ///   - trailing: What the trailing pane showed.
    ///   - timelineChannel: The channel the trailing timeline rendered.
    ///   - selection: The selected channel, which can be a hop ahead of the
    ///     timeline. Selecting it again would resubscribe it.
    ///   - openPeer: The open DM, if any.
    mutating func fold(
        trailing: TrailingPaneContent,
        timelineChannel: ChannelID,
        selection: ChannelID,
        openPeer: PeerID?
    ) -> Effects {
        let fold = PaneFoldPolicy.fold(
            focus: focus,
            trailing: trailing,
            selectedChannel: timelineChannel,
            openPeer: openPeer
        )
        parked = fold.parked
        isBrowsing = false
        popover = PeoplePopoverPolicy.pane(popover, after: .layoutChange)
        foldChannel = fold.channel == timelineChannel ? nil : fold.channel
        // The single column scopes a DM by its selection.
        conversationGeohash = nil
        landingChannel = nil
        if fold.endsConversation {
            conversation = nil
        }
        let select = fold.channel == selection ? nil : fold.channel
        return Effects(
            select: select,
            endsConversation: fold.endsConversation,
            // A notices sheet up across the fold opened over the selection
            // this changes (E3's #mesh). It keeps the scope it opened with
            // whatever the selection does, but closes rather than sit over
            // a #mesh it never showed.
            closesNoticesSheet: select != nil
        )
    }

    /// The device unfolds (E4, E8): the parked geohash returns, or the
    /// single column's moves to the trailing pane; a DM open in the sheet
    /// moves across, or else the parked one reopens. What was parked is
    /// consumed either way.
    /// - Parameters:
    ///   - timelineChannel: The channel the single column's timeline
    ///     rendered.
    ///   - openPeer: The DM open in the sheet, if any.
    ///   - locationSheetIsUp: The location channels sheet is up. It closes,
    ///     and the trailing pane shows the picker in its place: browsing
    ///     if a geohash is selected, idle if not (E8). A DM the fold parked
    ///     doesn't reopen over it: it goes with the rest of what was
    ///     parked.
    ///   - canReopen: Whether a parked DM can open again: not a group left
    ///     (or removed from) while folded, nor a peer blocked meanwhile.
    mutating func unfold(
        timelineChannel: ChannelID,
        openPeer: PeerID?,
        locationSheetIsUp: Bool,
        canReopen: (PeerID) -> Bool
    ) -> Effects {
        let compactChannel = foldChannel ?? timelineChannel
        let unfold = PaneFoldPolicy.unfold(
            compactChannel: compactChannel,
            openPeer: openPeer,
            parked: parked
        )
        // Always selected, even if it reads as the selection already: a
        // fold's #mesh selection may still be on its way.
        var effects = Effects(select: unfold.reselect.map(ChannelID.location))
        landingChannel = unfold.reselect
        // The DM in the sheet moves across scoped as the single column had
        // it: a geohash DM over the geohash on screen keeps that geohash,
        // one over #mesh stays there. (A parked DM is never a geohash DM.)
        conversationGeohash = openPeer.flatMap { peer in
            PaneFoldPolicy.isGeohashConversation(peer) ? Self.geohash(of: compactChannel) : nil
        }
        // E8 over E4: a reopened DM would cover the picker the sheet turns
        // into, and take the focus it has.
        if !locationSheetIsUp, let peer = unfold.reopenConversation, canReopen(peer) {
            // The unfold's own: it doesn't take the focus (E4).
            effects.reopensConversation = peer
            conversation = peer
        }
        focus = unfold.focus
        parked = .none
        foldChannel = nil
        popover = PeoplePopoverPolicy.pane(popover, after: .layoutChange)
        isBrowsing = false
        if locationSheetIsUp {
            effects.closesLocationSheet = true
            isBrowsing = unfold.reselect != nil || compactChannel.isLocation
            focus = .trailing
        }
        return effects
    }

    // MARK: Selection and conversations

    /// The open DM is now `peer` (nil: none). Split: a DM opening takes
    /// the focus (E1), closes the popovers (E13) and ends browsing.
    /// Folded: opening any DM drops the parked one (E5). Report it as it
    /// happens, so a touch or a fold that follows sees it.
    ///
    /// The open DM handed to another peer ID of the same person (a
    /// reconnect under a new short ID, a disconnect handing it to the Noise
    /// key's ID, a send re-resolving its route) opens nothing: only the ID
    /// it is recorded under changes. The focus, the popovers, browsing and
    /// anything parked stay as they were.
    /// - Parameters:
    ///   - timelineChannel: The channel the trailing timeline renders: a
    ///     geohash DM opening over a geohash is scoped to it
    ///     (`conversationGeohash`).
    ///   - isSameConversation: Whether two peer IDs name one
    ///     conversation, compared the way drafts and mic holds are
    ///     (`ChatViewModel.isSameDirectConversation`).
    mutating func conversationChanged(
        to peer: PeerID?,
        isSplit: Bool,
        timelineChannel: ChannelID,
        isSameConversation: (PeerID, PeerID) -> Bool
    ) {
        guard peer != conversation else { return }
        if let peer, let current = conversation, isSameConversation(current, peer) {
            conversation = peer
            return
        }
        conversation = peer
        let isGeohashConversation = peer.map(PaneFoldPolicy.isGeohashConversation) == true
        conversationGeohash = isSplit && isGeohashConversation ? Self.geohash(of: timelineChannel) : nil
        guard isSplit else {
            parked = PaneFoldPolicy.parked(parked, afterCompactConversationChange: peer)
            return
        }
        guard peer != nil else { return }
        focus = .trailing
        popover = PeoplePopoverPolicy.pane(popover, after: .conversationOpened)
        isBrowsing = false
    }

    /// The selection changed while folded (E5): a location channel drops
    /// everything parked; #mesh, the fold's own selection included, keeps
    /// it.
    mutating func compactSelectionChanged(to channel: ChannelID) {
        parked = PaneFoldPolicy.parked(parked, afterCompactSelection: channel)
    }

    /// The selection changed in the split layout. Once it names a location
    /// channel, an unfold's re-selection has been applied (or overtaken):
    /// the selection itself says what the trailing pane waits for.
    mutating func splitSelectionChanged(to channel: ChannelID) {
        if channel.isLocation {
            landingChannel = nil
        }
    }

    /// The selection landed in the timeline. Leaving a geohash ends
    /// browsing whatever moved it (a choice in the picker, a link, a panic
    /// wipe), so the picker never stays up for a geohash that is gone, and
    /// a choice never brings the old geohash back while it lands. A fold's
    /// channel has landed, or been overtaken.
    ///
    /// A geohash DM whose geohash the timeline leaves (a #geohash link or
    /// the nearby hint in #mesh moving the selection beside it) ends: it
    /// can't follow onto the new geohash's identity, and a geohash DM needs
    /// its geohash live (E3's premise). The trailing pane then shows the
    /// channel that was asked for.
    mutating func timelineChannelChanged(from old: ChannelID, to new: ChannelID) -> Effects {
        guard old != new else { return Effects() }
        if old.isLocation {
            isBrowsing = false
        }
        foldChannel = nil
        // Landed, or overtaken: nothing is on its way any more that the
        // selection doesn't name.
        landingChannel = nil
        guard let geohash = conversationGeohash, new != .location(geohash) else { return Effects() }
        conversation = nil
        conversationGeohash = nil
        return Effects(endsConversation: true)
    }

    /// What the trailing pane shows changed: its bar may have gone with it
    /// (E13).
    mutating func trailingContentChanged(from old: TrailingPaneContent, to new: TrailingPaneContent) {
        popover = PeoplePopoverPolicy.pane(popover, after: .trailingContentChange(from: old, to: new))
    }

    // MARK: Touches and controls

    /// A touch went down in `pane` (E1).
    mutating func touched(_ pane: ContentPane) {
        focus = pane
    }

    /// A composer took the keyboard, or was typed in: its pane is the last
    /// touched (E1).
    mutating func composerFocused(_ slot: ComposerSlot) {
        focus = ContentPane(composer: slot)
    }

    /// The trailing #geohash badge: the picker, to switch channels.
    mutating func browse() {
        isBrowsing = true
        focus = .trailing
    }

    /// A channel was chosen in the inline picker (E1, E7). Browsing ends
    /// now if the timeline already shows the selection (the selected
    /// geohash chosen again, or a choice from the idle picker, which
    /// isn't browsing); otherwise the timeline's move to the choice ends
    /// it, so the geohash being left never comes back meanwhile.
    mutating func choseChannel(timelineShowsSelection: Bool) {
        focus = .trailing
        if timelineShowsSelection {
            isBrowsing = false
        }
    }

    /// The picker's close control: back to the geohash.
    mutating func endBrowsing() {
        isBrowsing = false
    }

    mutating func openPopover(_ pane: ContentPane) {
        popover = pane
        focus = pane
    }

    /// The popover closed itself (its close button, a row's DM, a tap
    /// outside).
    mutating func popoverClosed(_ pane: ContentPane) {
        if popover == pane {
            popover = nil
        }
    }

    // MARK: Panic

    /// Panic (I4): nothing parked survives, the focus goes back to #mesh
    /// and the popovers close. Browsing over a geohash ends as the wipe's
    /// own #mesh selection lands (`timelineChannelChanged`), so the picker
    /// never gives way to the wiped geohash meanwhile; without a geohash
    /// it ends now.
    /// - Parameter timelineChannel: The channel the trailing timeline
    ///   renders.
    mutating func panic(timelineChannel: ChannelID) {
        focus = .leading
        popover = PeoplePopoverPolicy.pane(popover, after: .panic)
        parked = .none
        foldChannel = nil
        conversationGeohash = nil
        landingChannel = nil
        if !timelineChannel.isLocation {
            isBrowsing = false
        }
    }

    // MARK: What the panes show

    /// What the trailing pane shows (`TrailingPaneContent.resolve`), with
    /// what this state holds: browsing, and an unfold's re-selection still
    /// on its way.
    /// - Parameters:
    ///   - openPeer: The open DM, if any.
    ///   - timelineChannel: The channel the trailing timeline renders.
    ///   - selection: The selected location channel.
    func trailingContent(
        openPeer: PeerID?,
        timelineChannel: ChannelID,
        selection: ChannelID
    ) -> TrailingPaneContent {
        .resolve(
            conversation: openPeer,
            channel: timelineChannel,
            selection: landingChannel.map(ChannelID.location) ?? selection,
            isBrowsing: isBrowsing
        )
    }

    /// The split layout's composer targets: #mesh, and the trailing pane's
    /// conversation (`ComposerTargets.split`). A geohash DM is scoped to the
    /// geohash it was opened over (`conversationGeohash`), never to the
    /// timeline under it.
    /// - Parameters:
    ///   - trailing: What the trailing pane shows.
    ///   - openPeer: The open DM, if any.
    func composerTargets(trailing: TrailingPaneContent, openPeer: PeerID?) -> ComposerTargets {
        .split(
            trailingChannel: trailing.composerGeohash(conversationGeohash: conversationGeohash),
            privatePeer: openPeer
        )
    }

    private static func geohash(of channel: ChannelID) -> GeohashChannel? {
        guard case .location(let geohash) = channel else { return nil }
        return geohash
    }
}
#endif
