#if os(iOS)
import BitFoundation
import CoreGraphics
import Testing
@testable import bitchat

/// The split layout's pure pane policies: what the trailing pane shows, how
/// folding and unfolding hand the panes to the single column and back
/// (E2-E5), and when the people popovers close (E13).
struct ContentPanePolicyTests {
    private let geohash = GeohashChannel(level: .city, geohash: "u4pru")
    private let otherGeohash = GeohashChannel(level: .neighborhood, geohash: "9q8yyk")
    private let meshPeer = PeerID(str: "0102030405060708")
    private let otherMeshPeer = PeerID(str: "1112131415161718")
    private let group = PeerID(str: "group_" + String(repeating: "ab", count: 16))
    private let bridgedPeer = PeerID(bridge: String(repeating: "cd", count: 32))
    private let geoDM = PeerID(nostr_: String(repeating: "ef", count: 32))
    private let geoChatPeer = PeerID(nostr: String(repeating: "12", count: 32))

    // MARK: - TrailingPaneContent

    @Test
    func openDMCoversTheChannelAndThePicker() {
        for channel in [ChannelID.mesh, .location(geohash)] {
            for isBrowsing in [false, true] {
                #expect(TrailingPaneContent.resolve(
                    conversation: meshPeer,
                    channel: channel,
                    isBrowsing: isBrowsing
                ) == .conversation(meshPeer))
            }
        }
    }

    @Test
    func selectedGeohashIsTheChannelUnlessBrowsing() {
        #expect(TrailingPaneContent.resolve(
            conversation: nil,
            channel: .location(geohash),
            isBrowsing: false
        ) == .channel(geohash))
        #expect(TrailingPaneContent.resolve(
            conversation: nil,
            channel: .location(geohash),
            isBrowsing: true
        ) == .picker(returnTo: geohash))
    }

    @Test
    func noLocationChannelIsTheIdlePickerEvenWhileBrowsing() {
        for isBrowsing in [false, true] {
            #expect(TrailingPaneContent.resolve(
                conversation: nil,
                channel: .mesh,
                isBrowsing: isBrowsing
            ) == .picker(returnTo: nil))
        }
    }

    /// E10: a place on screen warns; a DM, geohash DMs included, doesn't.
    @Test
    func everythingButADMShowsALocation() {
        #expect(TrailingPaneContent.channel(geohash).showsLocation)
        #expect(TrailingPaneContent.picker(returnTo: nil).showsLocation)
        #expect(TrailingPaneContent.picker(returnTo: geohash).showsLocation)
        #expect(!TrailingPaneContent.conversation(meshPeer).showsLocation)
        #expect(!TrailingPaneContent.conversation(geoDM).showsLocation)
    }

    /// E10: split, the trailing pane decides the screenshot flag (#mesh
    /// beside it shows no place); the single column leaves it unset.
    @Test
    func screenshotFlagFollowsTheTrailingPaneOnlyWhenSplit() {
        let contents: [TrailingPaneContent] = [
            .channel(geohash),
            .picker(returnTo: nil),
            .picker(returnTo: geohash),
            .conversation(meshPeer),
            .conversation(geoDM)
        ]
        for trailing in contents {
            #expect(SplitLayoutScreenshotPolicy.panesShowLocation(isSplit: true, trailing: trailing)
                == trailing.showsLocation)
            #expect(SplitLayoutScreenshotPolicy.panesShowLocation(isSplit: false, trailing: trailing) == nil)
        }
    }

    /// #1792's columns until the panes land: the selection says.
    @Test
    func columnsScreenshotFlagFollowsTheSelectionOnlyWhenSplit() {
        #expect(SplitLayoutScreenshotPolicy.columnsShowLocation(isSplit: true, selectedChannel: .location(geohash)) == true)
        #expect(SplitLayoutScreenshotPolicy.columnsShowLocation(isSplit: true, selectedChannel: .mesh) == false)
        #expect(SplitLayoutScreenshotPolicy.columnsShowLocation(isSplit: false, selectedChannel: .location(geohash)) == nil)
        #expect(SplitLayoutScreenshotPolicy.columnsShowLocation(isSplit: false, selectedChannel: .mesh) == nil)
    }

    /// The trailing composer works in the geohash on screen, or the one a
    /// DM covers, which scopes a geohash DM; the picker has no composer.
    @Test
    func trailingComposerWorksInTheGeohashOnScreenOrUnderTheDM() {
        #expect(TrailingPaneContent.channel(geohash).composerGeohash(timelineChannel: .location(geohash)) == geohash)
        #expect(TrailingPaneContent.conversation(geoDM).composerGeohash(timelineChannel: .location(geohash)) == geohash)
        #expect(TrailingPaneContent.conversation(meshPeer).composerGeohash(timelineChannel: .location(geohash)) == geohash)
        #expect(TrailingPaneContent.conversation(geoDM).composerGeohash(timelineChannel: .mesh) == nil)
        #expect(TrailingPaneContent.picker(returnTo: geohash).composerGeohash(timelineChannel: .location(geohash)) == nil)
        #expect(TrailingPaneContent.picker(returnTo: nil).composerGeohash(timelineChannel: .mesh) == nil)

        // As the split layout's composer targets: the picker leaves the
        // trailing composer without a conversation; a geohash DM signs
        // with the geohash it covers, a mesh DM lives on #mesh.
        func targets(_ content: TrailingPaneContent, _ timeline: ChannelID, _ peer: PeerID?) -> ComposerTargets {
            .split(trailingChannel: content.composerGeohash(timelineChannel: timeline), privatePeer: peer)
        }
        #expect(targets(.picker(returnTo: geohash), .location(geohash), nil).secondary == nil)
        #expect(targets(.channel(geohash), .location(geohash), nil).secondary == .publicChannel(.location(geohash)))
        #expect(targets(.conversation(geoDM), .location(geohash), geoDM).secondary
            == ConversationTarget(channel: .location(geohash), privatePeer: geoDM))
        #expect(targets(.conversation(meshPeer), .location(geohash), meshPeer).secondary
            == ConversationTarget(channel: .mesh, privatePeer: meshPeer))
        for content in [TrailingPaneContent.picker(returnTo: nil), .channel(geohash), .conversation(meshPeer)] {
            #expect(targets(content, .location(geohash), nil).primary == .mesh)
        }
    }

    /// E13: only the channel has a bar to anchor the trailing popover.
    @Test
    func onlyTheChannelHostsAChannelBar() {
        #expect(TrailingPaneContent.channel(geohash).hostsChannelHeader)
        #expect(!TrailingPaneContent.picker(returnTo: nil).hostsChannelHeader)
        #expect(!TrailingPaneContent.picker(returnTo: geohash).hostsChannelHeader)
        #expect(!TrailingPaneContent.conversation(meshPeer).hostsChannelHeader)
    }

    // MARK: - Fold (E2, E3)

    /// E2: the selected channel, with an open DM as the sheet; nothing parked.
    @Test
    func foldFromTheTrailingPaneKeepsWhatItShowed() {
        let cases: [(TrailingPaneContent, ChannelID, PeerID?, ChannelID)] = [
            (.channel(geohash), .location(geohash), nil, .location(geohash)),
            // Browsing ends; the geohash stays.
            (.picker(returnTo: geohash), .location(geohash), nil, .location(geohash)),
            // The idle picker folds to #mesh, with no sheet.
            (.picker(returnTo: nil), .mesh, nil, .mesh),
            (.conversation(meshPeer), .location(geohash), meshPeer, .location(geohash)),
            (.conversation(group), .mesh, group, .mesh),
            (.conversation(geoDM), .location(geohash), geoDM, .location(geohash))
        ]
        for (trailing, selected, openPeer, compact) in cases {
            #expect(PaneFoldPolicy.fold(
                focus: .trailing,
                trailing: trailing,
                selectedChannel: selected,
                openPeer: openPeer
            ) == PaneFoldPolicy.Fold(channel: compact, endsConversation: false, parked: .none))
        }
    }

    /// E3: #mesh; the geohash and a mesh DM or group wait for the unfold.
    @Test
    func foldFromMeshParksTheTrailingPane() {
        let cases: [(TrailingPaneContent, ChannelID, PeerID?, PaneFoldPolicy.Fold)] = [
            (.channel(geohash), .location(geohash), nil,
             .init(channel: .mesh, endsConversation: false, parked: .init(channel: geohash))),
            (.picker(returnTo: geohash), .location(geohash), nil,
             .init(channel: .mesh, endsConversation: false, parked: .init(channel: geohash))),
            (.picker(returnTo: nil), .mesh, nil,
             .init(channel: .mesh, endsConversation: false, parked: .none)),
            (.conversation(meshPeer), .location(geohash), meshPeer,
             .init(channel: .mesh, endsConversation: true, parked: .init(channel: geohash, conversation: meshPeer))),
            (.conversation(group), .mesh, group,
             .init(channel: .mesh, endsConversation: true, parked: .init(conversation: group))),
            // A bridged sender is no geohash DM.
            (.conversation(bridgedPeer), .location(geohash), bridgedPeer,
             .init(channel: .mesh, endsConversation: true, parked: .init(channel: geohash, conversation: bridgedPeer)))
        ]
        for (trailing, selected, openPeer, expected) in cases {
            #expect(PaneFoldPolicy.fold(
                focus: .leading,
                trailing: trailing,
                selectedChannel: selected,
                openPeer: openPeer
            ) == expected)
        }
    }

    /// E3's exception: a geohash DM needs its geohash live, so it folds as
    /// from the trailing pane: the geohash with the DM as the sheet.
    @Test
    func geohashDMFoldsWithItsGeohashFromEitherPane() {
        for peer in [geoDM, geoChatPeer] {
            for focus in [ContentPane.leading, .trailing] {
                #expect(PaneFoldPolicy.fold(
                    focus: focus,
                    trailing: .conversation(peer),
                    selectedChannel: .location(geohash),
                    openPeer: peer
                ) == PaneFoldPolicy.Fold(channel: .location(geohash), endsConversation: false, parked: .none))
            }
        }
        // Over the idle picker there is no geohash to keep: #mesh, DM sheet.
        #expect(PaneFoldPolicy.fold(
            focus: .leading,
            trailing: .conversation(geoDM),
            selectedChannel: .mesh,
            openPeer: geoDM
        ) == PaneFoldPolicy.Fold(channel: .mesh, endsConversation: false, parked: .none))
    }

    /// The pane's own content names the geohash; the selection only counts
    /// under a DM, where the channel is hidden.
    @Test
    func foldTakesTheGeohashTheTrailingPaneShows() {
        #expect(PaneFoldPolicy.fold(
            focus: .leading,
            trailing: .channel(otherGeohash),
            selectedChannel: .location(geohash),
            openPeer: nil
        ).parked == .init(channel: otherGeohash))
        #expect(PaneFoldPolicy.fold(
            focus: .trailing,
            trailing: .channel(otherGeohash),
            selectedChannel: .mesh,
            openPeer: nil
        ).channel == .location(otherGeohash))
    }

    /// E2 and E3 over every input: each focus, selection, browsing state
    /// and kind of open DM.
    @Test
    func everyFoldKeepsTheTrailingPaneOrParksIt() {
        let peers: [PeerID?] = [nil, meshPeer, group, bridgedPeer, geoDM, geoChatPeer]
        for focus in [ContentPane.leading, .trailing] {
            for selected in [ChannelID.mesh, .location(geohash)] {
                for isBrowsing in [false, true] {
                    for openPeer in peers {
                        let fold = PaneFoldPolicy.fold(
                            focus: focus,
                            trailing: TrailingPaneContent.resolve(
                                conversation: openPeer,
                                channel: selected,
                                isBrowsing: isBrowsing
                            ),
                            selectedChannel: selected,
                            openPeer: openPeer
                        )
                        let label = "focus \(focus), selected \(selected), browsing \(isBrowsing), DM \(String(describing: openPeer))"
                        let isGeohashDM = openPeer?.isGeoDM == true || openPeer?.isGeoChat == true
                        if focus == .trailing || isGeohashDM {
                            // E2: the selection, any DM along as the sheet.
                            #expect(fold == .init(channel: selected, endsConversation: false, parked: .none), "\(label)")
                        } else {
                            // E3: #mesh; the geohash and the DM wait.
                            let parked = PaneFoldPolicy.Parked(
                                channel: Self.locationGeohash(of: selected),
                                conversation: openPeer
                            )
                            #expect(fold == .init(channel: .mesh, endsConversation: openPeer != nil, parked: parked), "\(label)")
                        }
                    }
                }
            }
        }
    }

    @Test
    func onlyGeohashConversationsNeedTheirGeohash() {
        #expect(PaneFoldPolicy.isGeohashConversation(geoDM))
        #expect(PaneFoldPolicy.isGeohashConversation(geoChatPeer))
        #expect(!PaneFoldPolicy.isGeohashConversation(meshPeer))
        #expect(!PaneFoldPolicy.isGeohashConversation(group))
        #expect(!PaneFoldPolicy.isGeohashConversation(bridgedPeer))
    }

    // MARK: - Unfold (E4)

    @Test
    func unfoldMovesACompactGeohashToTheTrailingPane() {
        for openPeer in [nil, meshPeer] {
            for parked in [PaneFoldPolicy.Parked.none, .init(channel: otherGeohash, conversation: otherMeshPeer)] {
                #expect(PaneFoldPolicy.unfold(
                    compactChannel: .location(geohash),
                    openPeer: openPeer,
                    parked: parked
                ) == PaneFoldPolicy.Unfold(reselect: nil, reopenConversation: nil, focus: .trailing))
            }
        }
    }

    @Test
    func unfoldFromMeshRestoresWhatWasParked() {
        let cases: [(PaneFoldPolicy.Parked, PaneFoldPolicy.Unfold)] = [
            (.init(channel: geohash), .init(reselect: geohash, reopenConversation: nil, focus: .leading)),
            (.init(channel: geohash, conversation: meshPeer),
             .init(reselect: geohash, reopenConversation: meshPeer, focus: .leading)),
            // The parked DM reopens over the idle picker.
            (.init(conversation: group), .init(reselect: nil, reopenConversation: group, focus: .leading)),
            (.none, .init(reselect: nil, reopenConversation: nil, focus: .leading))
        ]
        for (parked, expected) in cases {
            #expect(PaneFoldPolicy.unfold(compactChannel: .mesh, openPeer: nil, parked: parked) == expected)
        }
    }

    /// E4 over every input: a compact geohash moves across with nothing
    /// restored; from #mesh, the parked geohash returns and the parked DM
    /// reopens unless one is open already.
    @Test
    func everyUnfoldConsumesWhatWasParked() {
        let parkedStates: [PaneFoldPolicy.Parked] = [
            .none,
            .init(channel: geohash),
            .init(conversation: meshPeer),
            .init(channel: geohash, conversation: meshPeer)
        ]
        for compact in [ChannelID.mesh, .location(otherGeohash)] {
            for openPeer in [nil, otherMeshPeer, geoDM] {
                for parked in parkedStates {
                    let unfold = PaneFoldPolicy.unfold(compactChannel: compact, openPeer: openPeer, parked: parked)
                    let label = "compact \(compact), DM \(String(describing: openPeer)), parked \(parked)"
                    if compact.isLocation {
                        #expect(unfold == .init(reselect: nil, reopenConversation: nil, focus: .trailing), "\(label)")
                    } else {
                        #expect(unfold.reselect == parked.channel, "\(label)")
                        #expect(unfold.reopenConversation == (openPeer == nil ? parked.conversation : nil), "\(label)")
                        #expect(unfold.focus == (openPeer == nil ? .leading : .trailing), "\(label)")
                    }
                }
            }
        }
    }

    /// A DM opened while folded wins over the parked one, and takes focus.
    @Test
    func unfoldFromMeshMovesAnOpenDMIntoTheTrailingPane() {
        for parked in [
            PaneFoldPolicy.Parked.none,
            .init(channel: geohash),
            .init(channel: geohash, conversation: meshPeer)
        ] {
            #expect(PaneFoldPolicy.unfold(
                compactChannel: .mesh,
                openPeer: otherMeshPeer,
                parked: parked
            ) == PaneFoldPolicy.Unfold(reselect: parked.channel, reopenConversation: nil, focus: .trailing))
        }
    }

    // MARK: - While folded (E5)

    @Test
    func choosingALocationChannelWhileFoldedDropsEverything() {
        let parked = PaneFoldPolicy.Parked(channel: geohash, conversation: meshPeer)
        #expect(PaneFoldPolicy.parked(parked, afterCompactSelection: .location(otherGeohash)) == .none)
        #expect(PaneFoldPolicy.parked(parked, afterCompactSelection: .location(geohash)) == .none)
    }

    /// Covers the echo of the fold's own select(.mesh) and re-selecting
    /// #mesh while on it.
    @Test
    func meshSelectionWhileFoldedKeepsWhatIsParked() {
        for parked in [
            PaneFoldPolicy.Parked(channel: geohash, conversation: meshPeer),
            .init(channel: geohash),
            .init(conversation: group),
            .none
        ] {
            #expect(PaneFoldPolicy.parked(parked, afterCompactSelection: .mesh) == parked)
        }
    }

    @Test
    func openingADMWhileFoldedDropsTheParkedPeer() {
        let parked = PaneFoldPolicy.Parked(channel: geohash, conversation: meshPeer)
        #expect(PaneFoldPolicy.parked(parked, afterCompactConversationChange: otherMeshPeer)
            == .init(channel: geohash))
        #expect(PaneFoldPolicy.parked(parked, afterCompactConversationChange: meshPeer)
            == .init(channel: geohash))
    }

    /// The fold ending the parked DM must keep it; any other close follows an
    /// open that already dropped it.
    @Test
    func aDMClosingWhileFoldedKeepsWhatIsParked() {
        let parked = PaneFoldPolicy.Parked(channel: geohash, conversation: meshPeer)
        #expect(PaneFoldPolicy.parked(parked, afterCompactConversationChange: nil) == parked)
    }

    // MARK: - Round trips

    /// Folding and unfolding, with the fold's own echoes in between, brings
    /// back the selection and the DM, focused on the pane the single column
    /// was showing. Browsing ends on the way (E2).
    @Test
    func foldThenUnfoldRestoresTheSplitLayout() {
        let channels: [ChannelID] = [.mesh, .location(geohash)]
        let peers: [PeerID?] = [nil, meshPeer, group, geoDM]
        for focus in [ContentPane.leading, .trailing] {
            for selected in channels {
                for openPeer in peers {
                    for isBrowsing in [false, true] {
                        Self.expectRoundTrip(
                            focus: focus,
                            selected: selected,
                            openPeer: openPeer,
                            isBrowsing: isBrowsing
                        )
                    }
                }
            }
        }
    }

    private static func expectRoundTrip(
        focus: ContentPane,
        selected: ChannelID,
        openPeer: PeerID?,
        isBrowsing: Bool
    ) {
        let fold = PaneFoldPolicy.fold(
            focus: focus,
            trailing: TrailingPaneContent.resolve(
                conversation: openPeer,
                channel: selected,
                isBrowsing: isBrowsing
            ),
            selectedChannel: selected,
            openPeer: openPeer
        )
        // Single column: what the fold left, plus its own echoes (the
        // select(.mesh) and the ended DM land after the parking).
        let compactChannel = fold.channel
        let compactPeer = fold.endsConversation ? nil : openPeer
        var parked = PaneFoldPolicy.parked(fold.parked, afterCompactSelection: compactChannel)
        if fold.endsConversation {
            parked = PaneFoldPolicy.parked(parked, afterCompactConversationChange: nil)
        }

        let unfold = PaneFoldPolicy.unfold(
            compactChannel: compactChannel,
            openPeer: compactPeer,
            parked: parked
        )
        let restoredChannel = unfold.reselect.map(ChannelID.location) ?? compactChannel
        let restoredPeer = unfold.reopenConversation ?? compactPeer
        // The split layout resolves the trailing pane afresh: not browsing.
        let restored = TrailingPaneContent.resolve(
            conversation: restoredPeer,
            channel: restoredChannel,
            isBrowsing: false
        )

        let label = "focus \(focus), selected \(selected), browsing \(isBrowsing), DM \(String(describing: openPeer))"
        #expect(restoredChannel == selected, "\(label)")
        #expect(restoredPeer == openPeer, "\(label)")
        #expect(restored == TrailingPaneContent.resolve(conversation: openPeer, channel: selected, isBrowsing: false), "\(label)")
        let compactShowedMesh = compactChannel == .mesh && compactPeer == nil
        #expect(unfold.focus == (compactShowedMesh ? .leading : .trailing), "\(label)")
    }

    private static func locationGeohash(of channel: ChannelID) -> GeohashChannel? {
        guard case .location(let geohash) = channel else { return nil }
        return geohash
    }

    // MARK: - People popovers (E13)

    @Test
    func popoversCloseOnFoldPanicAndAnyNewDM() {
        for event in [PeoplePopoverPolicy.Event.layoutChange, .panic, .conversationOpened] {
            for open in [ContentPane?.none, .leading, .trailing] {
                #expect(PeoplePopoverPolicy.pane(open, after: event) == nil)
            }
        }
    }

    @Test
    func trailingPopoverClosesWhenItsBarGoes() {
        let changes: [TrailingPaneContent] = [
            .conversation(meshPeer),
            .picker(returnTo: geohash),
            .picker(returnTo: nil),
            .channel(otherGeohash)
        ]
        for to in changes {
            #expect(PeoplePopoverPolicy.pane(
                .trailing,
                after: .trailingContentChange(from: .channel(geohash), to: to)
            ) == nil)
        }
        #expect(PeoplePopoverPolicy.pane(
            .trailing,
            after: .trailingContentChange(from: .channel(geohash), to: .channel(geohash))
        ) == .trailing)
    }

    /// #mesh's bar stays whatever the trailing pane does.
    @Test
    func leadingPopoverOutlastsTrailingChanges() {
        #expect(PeoplePopoverPolicy.pane(
            .leading,
            after: .trailingContentChange(from: .channel(geohash), to: .picker(returnTo: geohash))
        ) == .leading)
        #expect(PeoplePopoverPolicy.pane(
            nil,
            after: .trailingContentChange(from: .picker(returnTo: nil), to: .channel(geohash))
        ) == nil)
    }

    // MARK: - Touches

    /// The iPhone Duo's inner display: 455.5pt, the 40pt fold, 371.5pt.
    @Test
    func touchesMapToThePaneWhoseFrameHoldsThem() {
        let left = CGRect(x: 0, y: 0, width: 455.5, height: 669)
        let right = CGRect(x: 495.5, y: 0, width: 371.5, height: 669)

        #expect(ContentPane.containing(CGPoint(x: 100, y: 300), leading: left, trailing: right) == .leading)
        #expect(ContentPane.containing(CGPoint(x: 600, y: 300), leading: left, trailing: right) == .trailing)
        #expect(ContentPane.containing(CGPoint(x: 475, y: 300), leading: left, trailing: right) == nil)
        #expect(ContentPane.containing(CGPoint(x: 600, y: 900), leading: left, trailing: right) == nil)

        // Right to left the leading pane is on the right.
        #expect(ContentPane.containing(CGPoint(x: 100, y: 300), leading: right, trailing: left) == .trailing)
        #expect(ContentPane.containing(CGPoint(x: 600, y: 300), leading: right, trailing: left) == .leading)
    }
}
#endif
