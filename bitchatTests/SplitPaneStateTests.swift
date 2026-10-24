//
// SplitPaneStateTests.swift
// bitchatTests
//
// The split layout's own state as ContentView drives it: the last-touched
// pane (E1), browsing (E7), the people popovers (E13), what a fold parks and
// an unfold restores (E2-E6, E8), and what a panic wipes (I4). Each event
// runs as ContentView hands it over, the asynchronous echoes of the fold's
// own selection and ended DM included.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)
import BitFoundation
import Testing
@testable import bitchat

struct SplitPaneStateTests {
    private let geohash = GeohashChannel(level: .city, geohash: "u4pru")
    private let otherGeohash = GeohashChannel(level: .neighborhood, geohash: "9q8yyk")
    private let meshPeer = PeerID(str: "0102030405060708")
    private let otherMeshPeer = PeerID(str: "1112131415161718")
    private let group = PeerID(str: "group_" + String(repeating: "ab", count: 16))
    private let geoDM = PeerID(nostr_: String(repeating: "ef", count: 32))
    /// The mesh peer's Noise key ID: the DM moves there when the peer drops
    /// out of range, and back to a short ID when it reconnects.
    private let meshPeerStableID = PeerID(str: String(repeating: "0a", count: 32))

    /// The world around the panes: what is selected, what the trailing
    /// timeline renders, and the open DM. Effects land as they do in the
    /// app: the selection first, the timeline a hop later, a DM at once.
    private struct World {
        var state = SplitPaneState()
        var isSplit = true
        var selection: ChannelID = .mesh
        var timeline: ChannelID = .mesh
        var openPeer: PeerID?
        var isLocationSheetUp = false
        var canReopen: (PeerID) -> Bool = { _ in true }
        /// The peer IDs that name one person, as `isSameDirectConversation`
        /// resolves them.
        var people: [Set<PeerID>] = []

        var trailing: TrailingPaneContent {
            state.trailingContent(openPeer: openPeer, timelineChannel: timeline, selection: selection)
        }

        /// The composer targets, as ContentView builds them: the split
        /// layout's, or the single column's, which scopes a DM by the
        /// channel it shows.
        var targets: ComposerTargets {
            guard isSplit else {
                return .single(activeChannel: state.foldChannel ?? timeline, privatePeer: openPeer)
            }
            return state.composerTargets(trailing: trailing, openPeer: openPeer)
        }

        /// A selection that lands in the timeline, as `select` does, with
        /// what its landing asks for (a geohash DM left behind ends).
        mutating func land(_ channel: ChannelID) {
            select(channel)
            let old = timeline
            timeline = channel
            if state.timelineChannelChanged(from: old, to: channel).endsConversation {
                open(nil)
            }
        }

        /// The selection changing, a hop before the timeline follows.
        mutating func select(_ channel: ChannelID) {
            selection = channel
            if isSplit {
                state.splitSelectionChanged(to: channel)
            } else {
                state.compactSelectionChanged(to: channel)
            }
        }

        mutating func open(_ peer: PeerID?) {
            openPeer = peer
            let people = people
            state.conversationChanged(
                to: peer,
                isSplit: isSplit,
                timelineChannel: timeline,
                selection: selection
            ) { lhs, rhs in
                lhs == rhs || people.contains { $0.contains(lhs) && $0.contains(rhs) }
            }
        }

        /// Folds and lets the fold's own selection and DM end land.
        @discardableResult
        mutating func fold() -> SplitPaneState.Effects {
            let effects = state.fold(
                timelineChannel: timeline,
                selection: selection,
                openPeer: openPeer
            )
            isSplit = false
            if effects.endsConversation {
                open(nil)
            }
            if let channel = effects.select {
                land(channel)
            }
            return effects
        }

        /// Unfolds and lets the reselection and the reopened DM land.
        @discardableResult
        mutating func unfold() -> SplitPaneState.Effects {
            let effects = state.unfold(
                timelineChannel: timeline,
                openPeer: openPeer,
                locationSheetIsUp: isLocationSheetUp,
                canReopen: canReopen
            )
            isSplit = true
            if effects.closesLocationSheet {
                isLocationSheetUp = false
            }
            if let channel = effects.select {
                land(channel)
            }
            if let peer = effects.reopensConversation {
                open(peer)
            }
            return effects
        }
    }

    // MARK: - Fold (E2, E3)

    /// E3: #mesh; the geohash is parked and selected away, the mesh DM
    /// parked and ended.
    @Test
    func aFoldFromMeshParksTheGeohashAndTheMeshDM() {
        var world = World()
        world.land(.location(geohash))
        world.open(meshPeer)
        world.state.touched(.leading)

        let effects = world.state.fold(
            timelineChannel: world.timeline,
            selection: world.selection,
            openPeer: world.openPeer
        )

        #expect(effects == .init(select: .mesh, endsConversation: true, closesNoticesSheet: true))
        #expect(world.state.parked == .init(channel: geohash, conversation: meshPeer))
        // The single column's composer sends to #mesh while that lands.
        #expect(world.state.foldChannel == .mesh)
    }

    /// E2: the geohash and the DM stay, the DM as the sheet; nothing parked.
    @Test
    func aFoldFromTheTrailingPaneKeepsEverything() {
        var world = World()
        world.land(.location(geohash))
        world.open(meshPeer)
        #expect(world.state.focus == .trailing)

        let effects = world.fold()

        #expect(effects == .init())
        #expect(world.state.parked == .none)
        #expect(world.state.foldChannel == nil)
        #expect(world.selection == .location(geohash))
        #expect(world.openPeer == meshPeer)
    }

    /// A notices sheet up across a fold opened over the selection the fold
    /// changes: an E3 fold that selects #mesh closes it (it keeps its own
    /// scope regardless). A fold that leaves the selection leaves it.
    @Test
    func aFoldThatSelectsAwayClosesTheNoticesSheet() {
        var fromMesh = World()
        fromMesh.land(.location(geohash))
        fromMesh.state.touched(.leading)
        #expect(fromMesh.fold().closesNoticesSheet)

        for selected in [ChannelID.mesh, .location(geohash)] {
            var fromTrailing = World()
            fromTrailing.land(selected)
            fromTrailing.state.touched(.trailing)
            #expect(!fromTrailing.fold().closesNoticesSheet, "\(selected)")
        }
        var idle = World()
        idle.state.touched(.leading)
        #expect(!idle.fold().closesNoticesSheet)
    }

    /// E3's exception: a geohash DM needs its geohash live.
    @Test
    func aGeohashDMFoldsWithItsGeohashFromMesh() {
        var world = World()
        world.land(.location(geohash))
        world.open(geoDM)
        world.state.touched(.leading)

        #expect(world.fold() == .init())
        #expect(world.state.parked == .none)
        #expect(world.selection == .location(geohash))
        #expect(world.openPeer == geoDM)
    }

    /// The fold selects only what isn't selected: selecting again would
    /// resubscribe. A selection still landing counts as made.
    @Test
    func aFoldSelectsOnlyWhatIsNotSelected() {
        var state = SplitPaneState()
        state.touched(.leading)
        // #mesh is already selected; the timeline still shows the geohash.
        let effects = state.fold(
            timelineChannel: .location(geohash),
            selection: .mesh,
            openPeer: nil
        )
        #expect(effects.select == nil)
        #expect(state.foldChannel == .mesh)
        #expect(state.parked == .init(channel: geohash))

        // Its landing hands the single column back to the timeline.
        #expect(state.timelineChannelChanged(from: .location(geohash), to: .mesh) == .init())
        #expect(state.foldChannel == nil)
    }

    /// A geohash still landing (an unfold's re-selection, a launch with a
    /// persisted geohash, a choice on its way) folds, and parks, as the
    /// geohash the pane is about to show, not as the #mesh the timeline
    /// still renders.
    @Test
    func aGeohashOnItsWayFoldsAsThatGeohash() {
        var fromTrailing = World()
        fromTrailing.select(.location(geohash))
        #expect(fromTrailing.trailing == .landing(geohash))
        fromTrailing.state.touched(.trailing)
        let kept = fromTrailing.fold()
        // Already selected: nothing to select again; the single column's
        // composer works in it until it lands.
        #expect(kept == .init())
        #expect(fromTrailing.state.foldChannel == .location(geohash))
        #expect(fromTrailing.state.parked == .none)

        var fromMesh = World()
        fromMesh.select(.location(geohash))
        fromMesh.state.touched(.leading)
        let parked = fromMesh.fold()
        #expect(parked.select == .mesh)
        #expect(fromMesh.state.parked == .init(channel: geohash))
    }

    @Test
    func aFoldEndsBrowsingAndClosesThePopovers() {
        for pane in [ContentPane.leading, .trailing] {
            var world = World()
            world.land(.location(geohash))
            world.state.browse()
            world.state.openPopover(pane)
            world.fold()
            #expect(world.state.popover == nil)
            #expect(!world.state.isBrowsing)
        }
    }

    // MARK: - Unfold (E4, E8)

    /// The fold's echoes keep what is parked; the unfold brings back the
    /// geohash and the DM, focused on #mesh, which the single column
    /// showed. The reopening doesn't move the focus.
    @Test
    func anUnfoldRestoresTheParkedGeohashAndDM() {
        var world = World()
        world.land(.location(geohash))
        world.open(meshPeer)
        world.state.touched(.leading)
        world.fold()
        #expect(world.selection == .mesh)
        #expect(world.openPeer == nil)
        #expect(world.state.parked == .init(channel: geohash, conversation: meshPeer))

        let effects = world.unfold()

        #expect(effects == .init(select: .location(geohash), reopensConversation: meshPeer))
        #expect(world.selection == .location(geohash))
        #expect(world.openPeer == meshPeer)
        #expect(world.state.focus == .leading)
        #expect(world.state.parked == .none)
        #expect(world.state.conversation == meshPeer)
        #expect(world.trailing == .conversation(meshPeer))
    }

    /// A group left, or a peer blocked, while folded doesn't come back.
    @Test
    func anUnfoldReopensOnlyWhatCanReopen() {
        var world = World()
        world.open(group)
        world.state.touched(.leading)
        world.fold()
        world.canReopen = { _ in false }

        let effects = world.unfold()

        #expect(effects.reopensConversation == nil)
        #expect(world.openPeer == nil)
        #expect(world.state.parked == .none)
        #expect(world.state.conversation == nil)
    }

    /// The single column's geohash moves to the trailing pane, focused;
    /// nothing parked survives (E4).
    @Test
    func anUnfoldMovesTheCompactGeohashAcross() {
        var world = World()
        world.isSplit = false
        world.land(.location(otherGeohash))

        #expect(world.unfold() == .init())
        #expect(world.state.focus == .trailing)
        #expect(world.trailing == .channel(otherGeohash))
    }

    /// E8: the location sheet closes into the trailing picker: browsing
    /// when a geohash comes back or stays, idle otherwise.
    @Test
    func anUnfoldTurnsTheLocationSheetIntoThePicker() {
        // The single column's geohash: browsing from it.
        var onGeohash = World()
        onGeohash.isSplit = false
        onGeohash.land(.location(geohash))
        onGeohash.isLocationSheetUp = true
        #expect(onGeohash.unfold().closesLocationSheet)
        #expect(!onGeohash.isLocationSheetUp)
        #expect(onGeohash.trailing == .picker(returnTo: geohash))
        #expect(onGeohash.state.focus == .trailing)

        // A parked geohash comes back: browsing, once it lands, from it.
        var parked = World()
        parked.land(.location(geohash))
        parked.state.touched(.leading)
        parked.fold()
        parked.isLocationSheetUp = true
        parked.unfold()
        #expect(parked.trailing == .picker(returnTo: geohash))
        #expect(parked.state.focus == .trailing)

        // Nothing to browse from: the idle picker.
        var idle = World()
        idle.isSplit = false
        idle.isLocationSheetUp = true
        idle.unfold()
        #expect(!idle.state.isBrowsing)
        #expect(idle.trailing == .picker(returnTo: nil))
    }

    /// E4 with E3's exception mirrored: a geohash DM opened while folded on
    /// #mesh unfolds over the idle picker, scoped to #mesh as the single
    /// column had it, where its sends fail into the thread. The parked
    /// geohash isn't selected under it: that would sign the DM with that
    /// geohash's identity, which nobody chose for it.
    @Test
    func anUnfoldUnderAGeohashDMOpenedWhileFoldedKeepsMesh() {
        var world = World()
        world.land(.location(geohash))
        world.state.touched(.leading)
        world.fold()
        #expect(world.state.parked == .init(channel: geohash))

        world.open(geoDM)
        let effects = world.unfold()

        #expect(effects == .init())
        #expect(world.selection == .mesh)
        #expect(world.trailing == .conversation(geoDM))
        #expect(world.state.conversationScope == .mesh)
        #expect(world.targets.secondary == ConversationTarget(channel: .mesh, privatePeer: geoDM))
        #expect(world.state.parked == .none)
    }

    /// A geohash DM folded with its geohash (E3's exception) unfolds over
    /// it, scoped to it as the single column had it.
    @Test
    func aGeohashDMUnfoldsScopedToTheGeohashItFoldedWith() {
        var world = World()
        world.land(.location(geohash))
        world.open(geoDM)
        world.state.touched(.leading)
        world.fold()
        #expect(world.state.conversationScope == nil)

        #expect(world.unfold() == .init())
        #expect(world.state.conversationScope == .location(geohash))
        #expect(world.targets.secondary == ConversationTarget(channel: .location(geohash), privatePeer: geoDM))
    }

    // MARK: - Geohash DM scope

    /// A geohash DM signs with the geohash it was opened over. A selection
    /// made beside it (a #geohash link or the nearby hint in #mesh) never
    /// moves it onto the new geohash's identity: once the timeline leaves
    /// its geohash the DM ends, and until that lands its target falls back
    /// to #mesh, where sends fail closed, never to the new geohash.
    @Test
    func aTimelineMoveUnderAGeohashDMNeverRescopesIt() {
        for peer in [geoDM, PeerID(nostr: String(repeating: "12", count: 32))] {
            var world = World()
            world.land(.location(geohash))
            world.open(peer)
            #expect(world.state.conversationScope == .location(geohash))
            #expect(world.targets.secondary == ConversationTarget(channel: .location(geohash), privatePeer: peer))

            // The timeline lands on the other geohash; the DM's end is on
            // its way.
            let old = world.timeline
            world.timeline = .location(otherGeohash)
            world.selection = world.timeline
            let effects = world.state.timelineChannelChanged(from: old, to: world.timeline)
            #expect(effects == .init(endsConversation: true))
            #expect(world.targets.secondary?.channel != .location(otherGeohash))
            #expect(world.targets.secondary == ConversationTarget(channel: .mesh, privatePeer: peer))

            world.open(nil)
            #expect(world.trailing == .channel(otherGeohash))
            #expect(world.targets.secondary == .publicChannel(.location(otherGeohash)))
        }
    }

    /// A geohash DM over no geohash is scoped to #mesh, where its sends
    /// fail closed: one opened over the idle picker (from the #mesh
    /// popover's recent chats, say), or brought across from #mesh by an
    /// unfold. A geohash selected beside it ends it once the timeline lands
    /// there, as leaving a geohash ends one scoped to it. Kept, it would
    /// fold into the single column, which scopes a DM by its selection,
    /// and sign with that geohash's identity, which nobody chose for it.
    /// Until the timeline lands its target stays on #mesh.
    @Test
    func aGeohashDMScopedToMeshEndsOnceAGeohashLandsBesideIt() {
        func overIdlePicker() -> World {
            var world = World()
            world.open(geoDM)
            return world
        }
        func unfoldedFromMesh() -> World {
            var world = World()
            world.land(.location(otherGeohash))
            world.state.touched(.leading)
            world.fold()
            world.open(geoDM)
            world.unfold()
            return world
        }
        for (label, start) in [("idle picker", overIdlePicker), ("unfolded from #mesh", unfoldedFromMesh)] {
            for focus in [ContentPane.leading, .trailing] {
                var world = start()
                #expect(world.state.conversationScope == .mesh, "\(label)")
                #expect(world.targets.secondary == ConversationTarget(channel: .mesh, privatePeer: geoDM), "\(label)")

                // A #geohash link in a #mesh message: the selection moves
                // first, the timeline a hop later.
                world.select(.location(geohash))
                #expect(world.openPeer == geoDM, "\(label)")
                #expect(world.targets.secondary == ConversationTarget(channel: .mesh, privatePeer: geoDM), "\(label)")
                world.land(.location(geohash))
                #expect(world.openPeer == nil, "\(label)")
                #expect(world.state.conversationScope == nil, "\(label)")
                #expect(world.trailing == .channel(geohash), "\(label)")

                // A fold from either pane has no DM to carry onto it.
                world.state.touched(focus)
                world.fold()
                #expect(world.openPeer == nil, "\(label), \(focus)")
                #expect(world.targets.secondary == nil, "\(label), \(focus)")
            }
        }
    }

    /// A geohash DM opened while the trailing pane's geohash is still on
    /// its way is scoped to that geohash, the one the pane is about to
    /// show, so its landing ends nothing. A fold before it lands keeps the
    /// geohash for the DM, from either pane: the single column's composer
    /// works in it at once.
    @Test
    func aGeohashDMOpenedOverAGeohashOnItsWayIsScopedToIt() {
        var world = World()
        world.select(.location(geohash))
        #expect(world.trailing == .landing(geohash))
        world.open(geoDM)
        #expect(world.state.conversationScope == .location(geohash))
        #expect(world.targets.secondary == ConversationTarget(channel: .location(geohash), privatePeer: geoDM))
        world.land(.location(geohash))
        #expect(world.openPeer == geoDM)
        #expect(world.targets.secondary == ConversationTarget(channel: .location(geohash), privatePeer: geoDM))

        for focus in [ContentPane.leading, .trailing] {
            var early = World()
            early.select(.location(geohash))
            early.open(geoDM)
            early.state.touched(focus)
            let effects = early.state.fold(
                timelineChannel: early.timeline,
                selection: early.selection,
                openPeer: early.openPeer
            )
            early.isSplit = false
            #expect(effects == .init(), "\(focus)")
            #expect(early.state.foldChannel == .location(geohash), "\(focus)")
            #expect(early.targets.secondary == ConversationTarget(channel: .location(geohash), privatePeer: geoDM), "\(focus)")
        }
    }

    /// Only leaving a geohash DM's own channel ends it: a mesh DM stays
    /// through any move, and a geohash DM through its geohash chosen again.
    @Test
    func onlyLeavingAGeohashDMsOwnChannelEndsIt() {
        var mesh = World()
        mesh.land(.location(geohash))
        mesh.open(meshPeer)
        #expect(mesh.state.conversationScope == nil)
        mesh.land(.location(otherGeohash))
        #expect(mesh.openPeer == meshPeer)
        #expect(mesh.targets.secondary == ConversationTarget(channel: .mesh, privatePeer: meshPeer))
        mesh.land(.mesh)
        #expect(mesh.openPeer == meshPeer)

        var same = World()
        same.land(.location(geohash))
        same.open(geoDM)
        same.land(.location(geohash))
        #expect(same.openPeer == geoDM)
        #expect(same.state.conversationScope == .location(geohash))
    }

    /// I4: a wipe forgets the scope with everything else.
    @Test
    func aPanicForgetsAGeohashDMsScope() {
        var world = World()
        world.land(.location(geohash))
        world.open(geoDM)
        world.state.panic(timelineChannel: world.timeline)
        #expect(world.state.conversationScope == nil)
    }

    // MARK: - A geohash on its way

    /// An unfold's re-selection of the parked geohash lands a hop or more
    /// later: until the timeline shows it the trailing pane holds a
    /// placeholder rather than mount the picker, first on what the unfold
    /// selected, then on the selection itself.
    @Test
    func anUnfoldsReselectionHoldsThePaneUntilItLands() {
        var world = World()
        world.land(.location(geohash))
        world.state.touched(.leading)
        world.fold()
        #expect(world.timeline == .mesh)

        let effects = world.state.unfold(
            timelineChannel: world.timeline,
            openPeer: world.openPeer,
            locationSheetIsUp: false,
            canReopen: { _ in true }
        )
        world.isSplit = true
        #expect(effects.select == .location(geohash))
        #expect(world.state.landingChannel == geohash)
        #expect(world.trailing == .landing(geohash))

        // The selection applies; the timeline is still on its way.
        world.select(.location(geohash))
        #expect(world.state.landingChannel == nil)
        #expect(world.trailing == .landing(geohash))

        let old = world.timeline
        world.timeline = .location(geohash)
        _ = world.state.timelineChannelChanged(from: old, to: world.timeline)
        #expect(world.trailing == .channel(geohash))
    }

    /// The placeholder never outlives its landing: any timeline change, a
    /// fold or a panic drops what the unfold had on its way, so a timeline
    /// that never moved can't leave it holding the pane later.
    @Test
    func whatAnUnfoldHadOnItsWayNeverOutlivesIt() {
        func unfolded() -> World {
            var world = World()
            world.land(.location(geohash))
            world.state.touched(.leading)
            world.fold()
            _ = world.state.unfold(
                timelineChannel: world.timeline,
                openPeer: nil,
                locationSheetIsUp: false,
                canReopen: { _ in true }
            )
            world.isSplit = true
            #expect(world.state.landingChannel == geohash)
            return world
        }

        var moved = unfolded()
        _ = moved.state.timelineChannelChanged(from: .mesh, to: .location(otherGeohash))
        #expect(moved.state.landingChannel == nil)

        var folded = unfolded()
        folded.fold()
        #expect(folded.state.landingChannel == nil)

        var wiped = unfolded()
        wiped.state.panic(timelineChannel: wiped.timeline)
        #expect(wiped.state.landingChannel == nil)
        #expect(wiped.trailing == .picker(returnTo: nil))
    }

    /// A choice from the idle picker, or a launch with a persisted geohash:
    /// the selection is ahead of the timeline, and the pane waits on it.
    @Test
    func aSelectionAheadOfTheTimelineHoldsThePane() {
        var world = World()
        world.select(.location(geohash))
        #expect(world.trailing == .landing(geohash))
        world.land(.location(geohash))
        #expect(world.trailing == .channel(geohash))
    }

    /// E8 over E4: a DM the fold parked doesn't reopen over the picker the
    /// location sheet turns into; it goes with the rest of what was
    /// parked, and the picker keeps the trailing focus. Over a parked
    /// geohash the picker browses from it; over none it is idle.
    @Test
    func anUnfoldTurnsTheLocationSheetIntoThePickerOverAParkedDM() {
        var world = World()
        world.land(.location(geohash))
        world.open(meshPeer)
        world.state.touched(.leading)
        world.fold()
        #expect(world.state.parked == .init(channel: geohash, conversation: meshPeer))
        world.isLocationSheetUp = true

        let effects = world.unfold()

        #expect(effects.reopensConversation == nil)
        #expect(effects.closesLocationSheet)
        #expect(world.openPeer == nil)
        #expect(world.state.conversation == nil)
        #expect(world.trailing == .picker(returnTo: geohash))
        #expect(world.state.focus == .trailing)
        #expect(world.state.parked == .none)

        var idle = World()
        idle.open(meshPeer)
        idle.state.touched(.leading)
        idle.fold()
        #expect(idle.state.parked == .init(conversation: meshPeer))
        idle.isLocationSheetUp = true
        idle.unfold()
        #expect(idle.openPeer == nil)
        #expect(idle.trailing == .picker(returnTo: nil))
        #expect(idle.state.focus == .trailing)
    }

    // MARK: - While folded (E5)

    @Test
    func aCompactLocationSelectionDropsWhatIsParked() {
        var world = World()
        world.land(.location(geohash))
        world.open(meshPeer)
        world.state.touched(.leading)
        world.fold()

        world.land(.location(otherGeohash))
        #expect(world.state.parked == .none)

        #expect(world.unfold() == .init())
        #expect(world.selection == .location(otherGeohash))
        #expect(world.openPeer == nil)
    }

    @Test
    func aDMOpenedWhileFoldedDropsTheParkedOne() {
        var world = World()
        world.land(.location(geohash))
        world.open(meshPeer)
        world.state.touched(.leading)
        world.fold()

        world.open(otherMeshPeer)
        #expect(world.state.parked == .init(channel: geohash))

        let effects = world.unfold()
        #expect(effects == .init(select: .location(geohash)))
        #expect(world.openPeer == otherMeshPeer)
        // The DM moved across; it has the focus.
        #expect(world.state.focus == .trailing)
    }

    /// Fold and unfold over every focus, selection, browsing state and kind
    /// of DM: the panes come back as they were (browsing aside, E2), with
    /// the focus on the pane the single column showed.
    @Test
    func everyFoldAndUnfoldRestoresThePanes() {
        let peers: [PeerID?] = [nil, meshPeer, group, geoDM]
        for focus in [ContentPane.leading, .trailing] {
            for selected in [ChannelID.mesh, .location(geohash)] {
                for isBrowsing in [false, true] {
                    for openPeer in peers {
                        var world = World()
                        world.land(selected)
                        world.open(openPeer)
                        if isBrowsing {
                            world.state.browse()
                        }
                        world.state.touched(focus)
                        world.fold()
                        let compactShowedMesh = world.timeline == .mesh && world.openPeer == nil
                        world.unfold()

                        let label = "focus \(focus), selected \(selected), browsing \(isBrowsing), DM \(String(describing: openPeer))"
                        #expect(world.selection == selected, "\(label)")
                        #expect(world.openPeer == openPeer, "\(label)")
                        #expect(!world.state.isBrowsing, "\(label)")
                        #expect(world.state.parked == .none, "\(label)")
                        #expect(world.state.focus == (compactShowedMesh ? .leading : .trailing), "\(label)")
                    }
                }
            }
        }
    }

    /// Reports come once per change: a repeat of the open DM changes
    /// nothing, and neither does the report of the DM a fold ended.
    @Test
    func aRepeatedDMReportChangesNothing() {
        var world = World()
        world.land(.location(geohash))
        world.open(meshPeer)
        world.state.touched(.leading)
        world.state.openPopover(.leading)
        world.open(meshPeer)
        #expect(world.state.focus == .leading)
        #expect(world.state.popover == .leading)

        world.fold()
        #expect(world.state.parked.conversation == meshPeer)
        world.open(nil)
        #expect(world.state.parked.conversation == meshPeer)
    }

    /// E1: choosing the DM that is already open (its row in the #mesh
    /// popover, its sender's "direct message" in the #mesh list) is a DM
    /// opening too, though no report repeats it: it takes the focus and
    /// closes the popover, so a fold keeps the DM (E2) instead of parking
    /// it (E3), as choosing anyone else's would.
    @Test
    func choosingTheOpenDMAgainTakesTheFocus() {
        var world = World()
        world.land(.location(geohash))
        world.open(meshPeer)
        world.state.touched(.leading)
        world.state.openPopover(.leading)
        // The selection republished: nothing.
        world.open(meshPeer)
        #expect(world.state.focus == .leading)

        world.state.conversationChosen()

        #expect(world.state.focus == .trailing)
        #expect(world.state.popover == nil)
        #expect(world.fold() == .init())
        #expect(world.openPeer == meshPeer)
        #expect(world.selection == .location(geohash))
    }

    /// The open DM handed to another ID of the same person (a disconnect
    /// moving it to the Noise key's ID, a reconnect under a new short ID)
    /// opens nothing: the focus, the popover and what a fold would do stay
    /// as they were. Another person's DM replacing it does open.
    @Test
    func aPeerIDHandoffOpensNothing() {
        var world = World()
        world.people = [[meshPeer, meshPeerStableID, otherMeshPeer]]
        world.land(.location(geohash))
        world.open(meshPeer)
        world.state.touched(.leading)
        world.state.openPopover(.leading)

        world.open(meshPeerStableID)
        #expect(world.state.conversation == meshPeerStableID)
        #expect(world.state.focus == .leading)
        #expect(world.state.popover == .leading)
        // And back under a new short ID.
        world.open(otherMeshPeer)
        #expect(world.state.focus == .leading)
        #expect(world.state.popover == .leading)

        // E3 still: the geohash and the DM, under the ID it has now, park.
        let effects = world.fold()
        #expect(effects == .init(select: .mesh, endsConversation: true, closesNoticesSheet: true))
        #expect(world.state.parked == .init(channel: geohash, conversation: otherMeshPeer))

        // Someone else's DM is a DM opening.
        var replaced = World()
        replaced.people = [[meshPeer, meshPeerStableID]]
        replaced.open(meshPeer)
        replaced.state.touched(.leading)
        replaced.state.openPopover(.leading)
        replaced.open(otherMeshPeer)
        #expect(replaced.state.focus == .trailing)
        #expect(replaced.state.popover == nil)
    }

    /// E4 reopens a parked DM under the ID it was parked under, and the next
    /// peer update hands it to the ID the person has now: the unfold's
    /// focus on #mesh stands.
    @Test
    func aHandoffAfterAnUnfoldReopenKeepsTheUnfoldsFocus() {
        var world = World()
        world.people = [[meshPeer, meshPeerStableID]]
        world.land(.location(geohash))
        world.open(meshPeer)
        world.state.touched(.leading)
        world.fold()
        world.unfold()
        #expect(world.openPeer == meshPeer)
        #expect(world.state.focus == .leading)

        world.open(meshPeerStableID)

        #expect(world.state.focus == .leading)
        #expect(world.trailing == .conversation(meshPeerStableID))
    }

    // MARK: - Focus (E1)

    @Test
    func touchesComposersAndChoicesMoveTheFocus() {
        var state = SplitPaneState()
        #expect(state.focus == .leading)
        state.touched(.trailing)
        #expect(state.focus == .trailing)
        state.composerFocused(.primary)
        #expect(state.focus == .leading)
        state.composerFocused(.secondary)
        #expect(state.focus == .trailing)
        state.touched(.leading)
        state.choseChannel(selects: true)
        #expect(state.focus == .trailing)
        state.openPopover(.leading)
        #expect(state.focus == .leading)
    }

    /// Any DM opening in the split layout takes the trailing pane's focus,
    /// closes the popovers and ends browsing.
    @Test
    func aDMOpeningTakesTheFocusAndClosesThePopovers() {
        for pane in [ContentPane.leading, .trailing] {
            var world = World()
            world.land(.location(geohash))
            world.state.browse()
            world.state.openPopover(pane)
            world.state.touched(.leading)
            world.open(meshPeer)
            #expect(world.state.focus == .trailing)
            #expect(world.state.popover == nil)
            #expect(!world.state.isBrowsing)
        }
        // A DM closing changes neither.
        var world = World()
        world.open(meshPeer)
        world.state.touched(.leading)
        world.state.openPopover(.leading)
        world.open(nil)
        #expect(world.state.focus == .leading)
        #expect(world.state.popover == .leading)
    }

    // MARK: - Browsing (E7)

    /// A choice ends browsing when the timeline shows it: at once for the
    /// selected geohash chosen again, otherwise as it lands, so the
    /// geohash being left never comes back meanwhile.
    @Test
    func browsingEndsWhenTheChoiceIsOnScreen() {
        var world = World()
        world.land(.location(geohash))
        world.state.browse()
        #expect(world.trailing == .picker(returnTo: geohash))

        // The selected geohash again: no selection, browsing ends.
        world.state.choseChannel(selects: false)
        #expect(world.trailing == .channel(geohash))

        // Another geohash, reported at the tap: the selection moves next,
        // the timeline after.
        world.state.browse()
        world.state.choseChannel(selects: true)
        #expect(world.trailing == .picker(returnTo: geohash))
        world.select(.location(otherGeohash))
        #expect(world.trailing == .picker(returnTo: geohash))
        world.land(.location(otherGeohash))
        #expect(world.trailing == .channel(otherGeohash))

        // #mesh leaves the location channel: the idle picker, the same
        // picker throughout.
        world.state.browse()
        world.land(.mesh)
        #expect(world.trailing == .picker(returnTo: nil))
        #expect(!world.state.isBrowsing)
    }

    @Test
    func theCloseControlEndsBrowsing() {
        var world = World()
        world.land(.location(geohash))
        world.state.browse()
        world.state.endBrowsing()
        #expect(world.trailing == .channel(geohash))
    }

    // MARK: - Popovers (E13)

    @Test
    func popoversCloseWhenTheirBarGoesOrTheyCloseThemselves() {
        var state = SplitPaneState()
        state.openPopover(.trailing)
        state.trailingContentChanged(from: .channel(geohash), to: .conversation(meshPeer))
        #expect(state.popover == nil)

        // The same content reported again (every pane change reports it)
        // leaves its bar, and its popover, up.
        state.openPopover(.trailing)
        state.trailingContentChanged(from: .channel(geohash), to: .channel(geohash))
        #expect(state.popover == .trailing)

        state.openPopover(.leading)
        state.trailingContentChanged(from: .channel(geohash), to: .picker(returnTo: geohash))
        #expect(state.popover == .leading)
        // Another pane's close leaves it.
        state.popoverClosed(.trailing)
        #expect(state.popover == .leading)
        state.popoverClosed(.leading)
        #expect(state.popover == nil)
    }

    @Test
    func popoversCloseOnUnfold() {
        var world = World()
        world.isSplit = false
        world.state.openPopover(.leading)
        world.unfold()
        #expect(world.state.popover == nil)
    }

    // MARK: - Panic (I4)

    /// Nothing the split layout held survives: focus, popover, browsing.
    /// Browsing over a geohash ends as the wipe's #mesh lands, so the
    /// picker never gives way to the wiped geohash.
    @Test
    func aPanicWipesTheSplitLayoutsState() {
        var world = World()
        world.land(.location(geohash))
        world.state.browse()
        world.state.openPopover(.trailing)

        world.state.panic(timelineChannel: world.timeline)

        #expect(world.state.focus == .leading)
        #expect(world.state.popover == nil)
        #expect(world.trailing == .picker(returnTo: geohash))
        world.land(.mesh)
        #expect(!world.state.isBrowsing)
        #expect(world.trailing == .picker(returnTo: nil))
        #expect(world.state == SplitPaneState())
    }

    /// I4/E6: a wipe while folded leaves nothing to rejoin on unfold.
    @Test
    func aPanicWhileFoldedLeavesNothingToRestore() {
        var world = World()
        world.land(.location(geohash))
        world.open(meshPeer)
        world.state.touched(.leading)
        world.fold()
        #expect(world.state.parked != .none)

        world.state.panic(timelineChannel: world.timeline)

        #expect(world.state == SplitPaneState())
        #expect(world.unfold() == .init())
        #expect(world.selection == .mesh)
        #expect(world.openPeer == nil)
    }

    /// A fold's selection still on its way when the wipe comes: the single
    /// column's composer follows the timeline again.
    @Test
    func aPanicDropsAFoldsPendingChannel() {
        var state = SplitPaneState()
        _ = state.fold(
            timelineChannel: .location(geohash),
            selection: .location(geohash),
            openPeer: nil
        )
        #expect(state.foldChannel == .mesh)
        state.panic(timelineChannel: .location(geohash))
        #expect(state.foldChannel == nil)
        #expect(state.parked == .none)
    }
}
#endif
