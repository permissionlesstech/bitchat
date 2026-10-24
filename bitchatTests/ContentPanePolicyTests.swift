#if os(iOS)
import BitFoundation
import CoreGraphics
import Testing
@testable import bitchat

/// The split layout's pure pane policies: what the trailing pane shows, and
/// how folding and unfolding hand the panes to the single column and back
/// (E2-E5). `SplitPaneStateTests` runs them as ContentView does.
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
                    selection: channel,
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
            selection: .location(geohash),
            isBrowsing: false
        ) == .channel(geohash))
        #expect(TrailingPaneContent.resolve(
            conversation: nil,
            channel: .location(geohash),
            selection: .location(geohash),
            isBrowsing: true
        ) == .picker(returnTo: geohash))
    }

    @Test
    func noLocationChannelIsTheIdlePickerEvenWhileBrowsing() {
        for isBrowsing in [false, true] {
            #expect(TrailingPaneContent.resolve(
                conversation: nil,
                channel: .mesh,
                selection: .mesh,
                isBrowsing: isBrowsing
            ) == .picker(returnTo: nil))
        }
    }

    /// A geohash selected but not yet in the timeline (an unfold's
    /// re-selection, a launch with a persisted geohash, a choice on its
    /// way) holds the pane instead of the idle picker, which would ask for
    /// a location fix for a pane about to change. A DM still covers it; a
    /// geohash on screen, browsed or not, shows as before.
    @Test
    func aGeohashOnItsWayHoldsThePaneInsteadOfThePicker() {
        for isBrowsing in [false, true] {
            #expect(TrailingPaneContent.resolve(
                conversation: nil,
                channel: .mesh,
                selection: .location(geohash),
                isBrowsing: isBrowsing
            ) == .landing(geohash))
            #expect(TrailingPaneContent.resolve(
                conversation: geoDM,
                channel: .mesh,
                selection: .location(geohash),
                isBrowsing: isBrowsing
            ) == .conversation(geoDM))
        }
        // Switching geohashes: the one on screen stays until the next lands.
        #expect(TrailingPaneContent.resolve(
            conversation: nil,
            channel: .location(geohash),
            selection: .location(otherGeohash),
            isBrowsing: false
        ) == .channel(geohash))
        #expect(TrailingPaneContent.resolve(
            conversation: nil,
            channel: .location(geohash),
            selection: .location(otherGeohash),
            isBrowsing: true
        ) == .picker(returnTo: geohash))

        // It shows a place and has no composer. (It folds as the geohash it
        // is about to show: `SplitPaneStateTests`.)
        #expect(TrailingPaneContent.landing(geohash).showsLocation)
        #expect(TrailingPaneContent.landing(geohash).composerGeohash(conversationGeohash: nil) == nil)
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

    /// The trailing composer works in the geohash on screen or, under a
    /// DM, the geohash that DM was opened over, which scopes a geohash DM;
    /// the picker has no composer.
    @Test
    func trailingComposerWorksInTheGeohashOnScreenOrTheOneTheDMOpenedOver() {
        #expect(TrailingPaneContent.channel(geohash).composerGeohash(conversationGeohash: nil) == geohash)
        #expect(TrailingPaneContent.conversation(geoDM).composerGeohash(conversationGeohash: otherGeohash) == otherGeohash)
        #expect(TrailingPaneContent.conversation(geoDM).composerGeohash(conversationGeohash: nil) == nil)
        #expect(TrailingPaneContent.picker(returnTo: geohash).composerGeohash(conversationGeohash: nil) == nil)
        #expect(TrailingPaneContent.picker(returnTo: nil).composerGeohash(conversationGeohash: nil) == nil)

        // As the split layout's composer targets: the picker leaves the
        // trailing composer without a conversation; a geohash DM signs
        // with the geohash it was opened over, else fails closed on #mesh;
        // a mesh DM lives on #mesh.
        func targets(_ content: TrailingPaneContent, opened: GeohashChannel?, _ peer: PeerID?) -> ComposerTargets {
            .split(trailingChannel: content.composerGeohash(conversationGeohash: opened), privatePeer: peer)
        }
        #expect(targets(.picker(returnTo: geohash), opened: nil, nil).secondary == nil)
        #expect(targets(.channel(geohash), opened: nil, nil).secondary == .publicChannel(.location(geohash)))
        #expect(targets(.conversation(geoDM), opened: geohash, geoDM).secondary
            == ConversationTarget(channel: .location(geohash), privatePeer: geoDM))
        #expect(targets(.conversation(geoDM), opened: nil, geoDM).secondary
            == ConversationTarget(channel: .mesh, privatePeer: geoDM))
        #expect(targets(.conversation(meshPeer), opened: nil, meshPeer).secondary
            == ConversationTarget(channel: .mesh, privatePeer: meshPeer))
        for content in [TrailingPaneContent.picker(returnTo: nil), .channel(geohash), .conversation(meshPeer)] {
            #expect(targets(content, opened: nil, nil).primary == .mesh)
        }
    }

    // MARK: - Fold (E2, E3)

    /// E2: the selected channel, with an open DM as the sheet; nothing parked.
    @Test
    func foldFromTheTrailingPaneKeepsWhatItShowed() {
        let cases: [(ChannelID, PeerID?, ChannelID)] = [
            (.location(geohash), nil, .location(geohash)),
            // The idle picker folds to #mesh, with no sheet.
            (.mesh, nil, .mesh),
            (.location(geohash), meshPeer, .location(geohash)),
            (.mesh, group, .mesh),
            (.location(geohash), geoDM, .location(geohash))
        ]
        for (selected, openPeer, compact) in cases {
            #expect(PaneFoldPolicy.fold(
                focus: .trailing,
                selectedChannel: selected,
                openPeer: openPeer
            ) == PaneFoldPolicy.Fold(channel: compact, endsConversation: false, parked: .none))
        }
    }

    /// E3: #mesh; the geohash and a mesh DM or group wait for the unfold.
    @Test
    func foldFromMeshParksTheTrailingPane() {
        let cases: [(ChannelID, PeerID?, PaneFoldPolicy.Fold)] = [
            (.location(geohash), nil,
             .init(channel: .mesh, endsConversation: false, parked: .init(channel: geohash))),
            (.mesh, nil,
             .init(channel: .mesh, endsConversation: false, parked: .none)),
            (.location(geohash), meshPeer,
             .init(channel: .mesh, endsConversation: true, parked: .init(channel: geohash, conversation: meshPeer))),
            (.mesh, group,
             .init(channel: .mesh, endsConversation: true, parked: .init(conversation: group))),
            // A bridged sender is no geohash DM.
            (.location(geohash), bridgedPeer,
             .init(channel: .mesh, endsConversation: true, parked: .init(channel: geohash, conversation: bridgedPeer)))
        ]
        for (selected, openPeer, expected) in cases {
            #expect(PaneFoldPolicy.fold(
                focus: .leading,
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
                    selectedChannel: .location(geohash),
                    openPeer: peer
                ) == PaneFoldPolicy.Fold(channel: .location(geohash), endsConversation: false, parked: .none))
            }
        }
        // Over the idle picker there is no geohash to keep: #mesh, DM sheet.
        #expect(PaneFoldPolicy.fold(
            focus: .leading,
            selectedChannel: .mesh,
            openPeer: geoDM
        ) == PaneFoldPolicy.Fold(channel: .mesh, endsConversation: false, parked: .none))
    }

    /// E2 and E3 over every input: each focus, selection and kind of open
    /// DM.
    @Test
    func everyFoldKeepsTheTrailingPaneOrParksIt() {
        let peers: [PeerID?] = [nil, meshPeer, group, bridgedPeer, geoDM, geoChatPeer]
        for focus in [ContentPane.leading, .trailing] {
            for selected in [ChannelID.mesh, .location(geohash)] {
                for openPeer in peers {
                    let fold = PaneFoldPolicy.fold(focus: focus, selectedChannel: selected, openPeer: openPeer)
                    let label = "focus \(focus), selected \(selected), DM \(String(describing: openPeer))"
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
    /// restored; from #mesh, the parked geohash returns (unless a geohash
    /// DM was opened while folded) and the parked DM reopens unless one is
    /// open already.
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
                        let keepsMesh = openPeer.map(PaneFoldPolicy.isGeohashConversation) == true
                        #expect(unfold.reselect == (keepsMesh ? nil : parked.channel), "\(label)")
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

    /// E4 with E3's exception mirrored: a geohash DM opened while folded on
    /// #mesh moves into the trailing pane over the idle picker, scoped to
    /// #mesh as the single column had it, and the parked geohash isn't
    /// selected under it: that would sign it with the geohash's identity.
    @Test
    func unfoldUnderAGeohashDMOpenedWhileFoldedSelectsNothing() {
        for peer in [geoDM, geoChatPeer] {
            for parked in [PaneFoldPolicy.Parked.none, .init(channel: geohash)] {
                #expect(PaneFoldPolicy.unfold(
                    compactChannel: .mesh,
                    openPeer: peer,
                    parked: parked
                ) == PaneFoldPolicy.Unfold(reselect: nil, reopenConversation: nil, focus: .trailing))
            }
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

    private static func locationGeohash(of channel: ChannelID) -> GeohashChannel? {
        guard case .location(let geohash) = channel else { return nil }
        return geohash
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
