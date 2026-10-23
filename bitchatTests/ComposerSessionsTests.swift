//
// ComposerSessionsTests.swift
// bitchatTests
//
// Each composer holds its own text, suggestions and target, and the
// sessions move texts between conversations in one step: parked when no
// composer shows their conversation, loaded when one does again, and handed
// straight from one composer to the other when a layout change moves a
// conversation between them. No two composers ever hold one conversation's
// text, a send goes where its composer pointed when it was taken, and a
// panic leaves nothing behind.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

@MainActor
struct ComposerSessionsTests {
    private static let geohash = GeohashChannel(level: .city, geohash: "u4pruy")
    private static let otherGeohash = GeohashChannel(level: .city, geohash: "9q8yyk")
    private static let meshPeer = PeerID(str: "0011223344556677")
    private static let otherMeshPeer = PeerID(str: "8899aabbccddeeff")
    private static let geoDMPeer = PeerID(nostr_: String(repeating: "ab", count: 32))
    private static let groupPeer = PeerID(groupID: Data(repeating: 0x42, count: 16))

    private static let geohashKey = ComposerDraftStore.Key.location(geohash: "u4pruy")
    private static let meshPeerKey = ComposerDraftStore.Key.privateChat(stableID: meshPeer.id)

    private static let compactMesh = ComposerTargets.single(activeChannel: .mesh, privatePeer: nil)
    private static let compactGeohash = ComposerTargets.single(activeChannel: .location(geohash), privatePeer: nil)

    /// No fingerprints known: DMs key by peer ID.
    private static func noFingerprint(_: PeerID) -> String? { nil }

    /// The split layout's targets with no DM open: `.split` on iOS, and the
    /// same value built directly elsewhere, so the hand-overs between the
    /// layouts are pinned on every platform the suite runs on.
    private static func splitTargets(trailing: GeohashChannel?) -> ComposerTargets {
        #if os(iOS)
        .split(trailingChannel: trailing, privatePeer: nil)
        #else
        ComposerTargets(primary: .mesh, secondary: trailing.map { .publicChannel(.location($0)) })
        #endif
    }

    private func makeSessions(_ drafts: InMemoryComposerDraftStore) -> ComposerSessions {
        ComposerSessions(drafts: drafts)
    }

    // MARK: - Targets

    @Test func singleTargetsAreTheSelectionVerbatim() {
        let mesh = ComposerTargets.single(activeChannel: .mesh, privatePeer: nil)
        #expect(mesh.primary == .mesh)
        #expect(mesh.secondary == nil)

        // A DM opened over a geohash is scoped to it, as the single composer
        // always scoped it; the primary keeps the channel.
        let dm = ComposerTargets.single(activeChannel: .location(Self.geohash), privatePeer: Self.meshPeer)
        #expect(dm.primary == .publicChannel(.location(Self.geohash)))
        #expect(dm.secondary == ConversationTarget(channel: .location(Self.geohash), privatePeer: Self.meshPeer))
        #expect(dm[.primary] == dm.primary)
        #expect(dm[.secondary] == dm.secondary)
    }

    #if os(iOS)
    @Test func splitTargetsPutMeshFirstAndTheTrailingConversationSecond() {
        let picker = ComposerTargets.split(trailingChannel: nil, privatePeer: nil)
        #expect(picker.primary == .mesh)
        #expect(picker.secondary == nil)

        let geohash = ComposerTargets.split(trailingChannel: Self.geohash, privatePeer: nil)
        #expect(geohash.primary == .mesh)
        #expect(geohash.secondary == .publicChannel(.location(Self.geohash)))

        // Mesh DMs and groups live on #mesh whatever the trailing geohash.
        for peer in [Self.meshPeer, Self.groupPeer] {
            let dm = ComposerTargets.split(trailingChannel: Self.geohash, privatePeer: peer)
            #expect(dm.primary == .mesh)
            #expect(dm.secondary == ConversationTarget(channel: .mesh, privatePeer: peer))
        }

        // A geohash DM signs with the trailing geohash; without one it has
        // no geohash to sign with, and its sends fail into the thread.
        let geoDM = ComposerTargets.split(trailingChannel: Self.geohash, privatePeer: Self.geoDMPeer)
        #expect(geoDM.secondary == ConversationTarget(channel: .location(Self.geohash), privatePeer: Self.geoDMPeer))
        let strandedGeoDM = ComposerTargets.split(trailingChannel: nil, privatePeer: Self.geoDMPeer)
        #expect(strandedGeoDM.secondary == ConversationTarget(channel: .mesh, privatePeer: Self.geoDMPeer))
    }
    #endif

    @Test func focusFindsTheSlotShowingAConversation() {
        let dm = ComposerTargets.single(activeChannel: .location(Self.geohash), privatePeer: Self.meshPeer)
        #expect(dm.slot(showing: .geohash("u4pruy")) == .primary)
        #expect(dm.slot(showing: .directPeer(Self.meshPeer)) == .secondary)
        #expect(dm.slot(showing: .mesh) == nil)
        #if os(iOS)
        // Across an unfold the geohash moves to the secondary, #mesh takes
        // the primary, and the DM keeps the secondary under another scope.
        let unfolded = ComposerTargets.split(trailingChannel: Self.geohash, privatePeer: nil)
        #expect(unfolded.slot(showing: .geohash("u4pruy")) == .secondary)
        #expect(unfolded.slot(showing: .mesh) == .primary)
        let unfoldedDM = ComposerTargets.split(trailingChannel: Self.geohash, privatePeer: Self.meshPeer)
        #expect(unfoldedDM.slot(showing: .directPeer(Self.meshPeer)) == .secondary)
        #endif
    }

    /// E11, compact: shared content fills the open DM's composer, else the
    /// public timeline's, and the review names that composer's conversation.
    @Test func sharedContentFillsTheDMWhileOneIsOpenElseThePublicComposer() {
        let noDM = Self.compactGeohash
        #expect(noDM.shareImportSlot(preferring: .secondary) == .primary)
        #expect(Self.destination(of: noDM, slot: .primary) == .geohash("u4pruy"))

        let dm = ComposerTargets.single(activeChannel: .location(Self.geohash), privatePeer: Self.meshPeer)
        #expect(dm.shareImportSlot(preferring: .secondary) == .secondary)
        #expect(Self.destination(of: dm, slot: .secondary) == .privateConversation(peerID: Self.meshPeer, displayName: "alice"))

        // A preference for the primary is always met: it always has a target.
        #expect(dm.shareImportSlot(preferring: .primary) == .primary)
        #expect(Self.destination(of: Self.compactMesh, slot: .primary) == .mesh)
    }

    private static func destination(of targets: ComposerTargets, slot: ComposerSlot) -> SharedContentDestination? {
        targets[slot].map { target in
            SharedContentDestination.resolve(
                selectedPrivatePeerID: target.privatePeer,
                privateDisplayName: "alice",
                activeChannel: target.channel
            )
        }
    }

    // MARK: - Compact draft swaps

    /// Opening a DM leaves the public composer's text where it is (its
    /// conversation is still the primary's); the DM composer loads the DM's
    /// parked draft and parks it again when the DM closes.
    @Test func openingAndClosingADMLeavesThePublicTextAndParksTheDMs() {
        let drafts = InMemoryComposerDraftStore([Self.meshPeerKey: "dm draft"])
        let sessions = makeSessions(drafts)
        sessions.retarget(Self.compactMesh, fingerprint: Self.noFingerprint)
        sessions.primary.text = "mesh text"

        let opened = sessions.retarget(
            .single(activeChannel: .mesh, privatePeer: Self.meshPeer),
            fingerprint: Self.noFingerprint
        )
        #expect(opened == [.secondary])
        #expect(sessions.primary.text == "mesh text")
        #expect(sessions.secondary.text == "dm draft")
        #expect(sessions.secondary.target == ConversationTarget(channel: .mesh, privatePeer: Self.meshPeer))
        #expect(drafts.saves.isEmpty, "nothing left the screen")

        sessions.secondary.text = "dm draft, longer"
        let closed = sessions.retarget(Self.compactMesh, fingerprint: Self.noFingerprint)
        #expect(closed == [.secondary])
        #expect(sessions.primary.text == "mesh text")
        #expect(sessions.secondary.text.isEmpty)
        #expect(sessions.secondary.target == nil)
        #expect(drafts.drafts[Self.meshPeerKey] == "dm draft, longer")
        #expect(drafts.drafts[.mesh] == nil, "the public text never left its composer")
    }

    @Test func aChannelSwitchParksTheOldTextAndLoadsTheNew() {
        let drafts = InMemoryComposerDraftStore([Self.geohashKey: "geo draft"])
        let sessions = makeSessions(drafts)
        sessions.retarget(Self.compactMesh, fingerprint: Self.noFingerprint)
        sessions.primary.text = "mesh text"

        let changed = sessions.retarget(Self.compactGeohash, fingerprint: Self.noFingerprint)

        #expect(changed == [.primary])
        #expect(sessions.primary.text == "geo draft")
        #expect(sessions.primary.target == .publicChannel(.location(Self.geohash)))
        #expect(drafts.drafts[.mesh] == "mesh text")

        sessions.retarget(Self.compactMesh, fingerprint: Self.noFingerprint)
        #expect(sessions.primary.text == "mesh text")
        #expect(drafts.drafts[Self.geohashKey] == "geo draft")
    }

    /// A DM keeps the key it was opened under while it stays open: its scope
    /// following the channel, or its fingerprint arriving mid-conversation,
    /// must neither swap its text away nor end a hold on its mic.
    @Test func anOpenDMKeepsItsDraftKeyWhileItStaysOpen() {
        let drafts = InMemoryComposerDraftStore()
        let sessions = makeSessions(drafts)
        sessions.retarget(
            .single(activeChannel: .mesh, privatePeer: Self.meshPeer),
            fingerprint: Self.noFingerprint
        )
        sessions.secondary.text = "half a thought"

        let rescoped = sessions.retarget(
            .single(activeChannel: .location(Self.geohash), privatePeer: Self.meshPeer),
            fingerprint: { _ in "deadbeef" }
        )

        #expect(rescoped == [.primary], "only the public composer changed conversation")
        #expect(sessions.secondary.text == "half a thought")
        #expect(sessions.secondary.draftKey == Self.meshPeerKey)
        #expect(sessions.secondary.target == ConversationTarget(channel: .location(Self.geohash), privatePeer: Self.meshPeer))
        #expect(drafts.drafts[Self.meshPeerKey] == nil)
    }

    /// A peer-ID handoff to the 64-hex Noise key is the same person: with
    /// the fingerprint known both IDs give one key, so nothing moves.
    @Test func aPeerIDHandoffKeepsTheDraftAndTheHold() {
        let noiseKey = Data((0..<32).map { UInt8($0) })
        let fingerprint = noiseKey.sha256Fingerprint()
        let shortID = PeerID(publicKey: noiseKey)
        let stableID = PeerID(hexData: noiseKey)
        let drafts = InMemoryComposerDraftStore()
        let sessions = makeSessions(drafts)
        sessions.retarget(
            .single(activeChannel: .mesh, privatePeer: shortID),
            fingerprint: { $0 == shortID ? fingerprint : nil }
        )
        sessions.secondary.text = "still typing"

        let handedOff = sessions.retarget(
            .single(activeChannel: .mesh, privatePeer: stableID),
            fingerprint: { _ in nil }
        )

        #expect(handedOff.isEmpty)
        #expect(sessions.secondary.text == "still typing")
        #expect(sessions.secondary.target?.privatePeer == stableID)
        #expect(drafts.saves.isEmpty)
    }

    // MARK: - Hand-overs between layouts

    /// Unfolding on a geohash: its text moves from the compact primary to
    /// the trailing secondary in one step, never through the store, and the
    /// primary loads #mesh's parked draft. Folding back hands it over again.
    @Test func aGeohashTextMovesBetweenTheCompactPrimaryAndTheSplitSecondary() {
        let drafts = InMemoryComposerDraftStore([.mesh: "parked mesh draft"])
        let sessions = makeSessions(drafts)
        sessions.retarget(Self.compactGeohash, fingerprint: Self.noFingerprint)
        let longText = String(repeating: "g", count: ComposerDraftStore.maxDraftLength + 10)
        sessions.primary.text = longText
        drafts.clearLog()

        let unfolded = sessions.retarget(Self.splitTargets(trailing: Self.geohash), fingerprint: Self.noFingerprint)

        #expect(unfolded == [.primary, .secondary])
        #expect(sessions.secondary.text == longText, "handed over whole, past the store's cap")
        #expect(sessions.secondary.target == .publicChannel(.location(Self.geohash)))
        #expect(sessions.primary.text == "parked mesh draft")
        #expect(sessions.primary.target == .mesh)
        #expect(drafts.loads == [.mesh])
        #expect(drafts.saves.isEmpty)

        drafts.clearLog()
        sessions.primary.text = "mesh text"
        let folded = sessions.retarget(Self.compactGeohash, fingerprint: Self.noFingerprint)

        #expect(folded == [.primary, .secondary])
        #expect(sessions.primary.text == longText)
        #expect(sessions.secondary.text.isEmpty)
        #expect(sessions.secondary.target == nil)
        #expect(drafts.loads.isEmpty, "the geohash text came from the other composer")
        #expect(drafts.saves.map(\.key) == [.mesh])
        #expect(drafts.drafts[.mesh] == "mesh text")
    }

    /// #mesh is the primary's in either layout, so its text never moves.
    @Test func meshTextStaysInThePrimaryAcrossLayoutChanges() {
        let drafts = InMemoryComposerDraftStore([Self.geohashKey: "geo draft"])
        let sessions = makeSessions(drafts)
        sessions.retarget(Self.compactMesh, fingerprint: Self.noFingerprint)
        sessions.primary.text = "mesh text"

        let unfolded = sessions.retarget(Self.splitTargets(trailing: Self.geohash), fingerprint: Self.noFingerprint)
        #expect(unfolded == [.secondary])
        #expect(sessions.primary.text == "mesh text")
        #expect(sessions.secondary.text == "geo draft")

        // Folding with the leading pane focused: the geohash is parked.
        sessions.secondary.text = "geo draft, edited"
        let folded = sessions.retarget(Self.compactMesh, fingerprint: Self.noFingerprint)
        #expect(folded == [.secondary])
        #expect(sessions.primary.text == "mesh text")
        #expect(drafts.drafts[Self.geohashKey] == "geo draft, edited")
    }

    // MARK: - The invariant

    /// No two composers hold one conversation's text, through any sequence
    /// of selections and layouts.
    @Test func noTwoSlotsEverHoldTheSameDraftKey() {
        var states: [ComposerTargets] = []
        for channel in [ChannelID.mesh, .location(Self.geohash), .location(Self.otherGeohash)] {
            for peer in [nil, Self.meshPeer, Self.otherMeshPeer, Self.geoDMPeer, Self.groupPeer] {
                states.append(.single(activeChannel: channel, privatePeer: peer))
            }
        }
        for trailing in [nil, Self.geohash, Self.otherGeohash] {
            states.append(Self.splitTargets(trailing: trailing))
            #if os(iOS)
            for peer in [Self.meshPeer, Self.geoDMPeer, Self.groupPeer] {
                states.append(.split(trailingChannel: trailing, privatePeer: peer))
            }
            #endif
        }

        let sessions = makeSessions(InMemoryComposerDraftStore())
        // Every state after every other one, each composer holding text.
        for from in states {
            for to in states {
                sessions.retarget(from, fingerprint: Self.noFingerprint)
                sessions.primary.text = "primary"
                sessions.secondary.text = "secondary"
                sessions.retarget(to, fingerprint: Self.noFingerprint)
                if let primaryKey = sessions.primary.draftKey {
                    #expect(primaryKey != sessions.secondary.draftKey, "\(from) -> \(to)")
                }
                #expect(sessions.primary.target == to.primary)
                #expect(sessions.secondary.target == to.secondary)
            }
        }
    }

    /// Were both slots ever pointed at one conversation, the primary keeps
    /// its text and the secondary holds none, so neither overwrites the
    /// other's draft.
    @Test func aSharedConversationStaysThePrimarysAlone() {
        let drafts = InMemoryComposerDraftStore()
        let sessions = makeSessions(drafts)
        sessions.retarget(Self.compactMesh, fingerprint: Self.noFingerprint)
        sessions.primary.text = "mesh text"

        sessions.retarget(
            ComposerTargets(primary: .mesh, secondary: .mesh),
            fingerprint: Self.noFingerprint
        )

        #expect(sessions.primary.draftKey == .mesh)
        #expect(sessions.primary.text == "mesh text")
        #expect(sessions.secondary.draftKey == nil)
        #expect(sessions.secondary.text.isEmpty)

        sessions.secondary.text = "typed beside it"
        sessions.saveAll()
        #expect(drafts.drafts[.mesh] == "mesh text")
    }

    // MARK: - Sending, saving, panic

    /// The send takes the target the composer has when the text is taken;
    /// a retarget right after can't redirect it.
    @Test func takeOutgoingCapturesTheTargetAtThatMoment() throws {
        let drafts = InMemoryComposerDraftStore([Self.geohashKey: "  hello there  "])
        let sessions = makeSessions(drafts)
        sessions.retarget(Self.compactGeohash, fingerprint: Self.noFingerprint)
        sessions.primary.autocomplete = ComposerAutocompleteState(suggestions: ["@bob"], range: NSRange(location: 0, length: 1))

        let outgoing = try #require(sessions.takeOutgoing(from: .primary))
        sessions.retarget(Self.compactMesh, fingerprint: Self.noFingerprint)

        #expect(outgoing.text == "hello there")
        #expect(outgoing.target == .publicChannel(.location(Self.geohash)))
        #expect(drafts.drafts[Self.geohashKey] == nil, "a sent draft is gone")
        #expect(!sessions.primary.autocomplete.isShowing)
    }

    @Test func takeOutgoingLeavesBlankTextAndTargetlessComposersAlone() {
        let sessions = makeSessions(InMemoryComposerDraftStore())
        sessions.secondary.text = "no conversation yet"
        #expect(sessions.takeOutgoing(from: .secondary) == nil)
        #expect(sessions.secondary.text == "no conversation yet")

        sessions.retarget(Self.compactMesh, fingerprint: Self.noFingerprint)
        sessions.primary.text = "   "
        #expect(sessions.takeOutgoing(from: .primary) == nil)
        #expect(sessions.primary.text == "   ")
    }

    @Test func saveAllParksEverySlotEmptyIncluded() {
        let drafts = InMemoryComposerDraftStore([Self.meshPeerKey: "old dm draft"])
        let sessions = makeSessions(drafts)
        sessions.retarget(
            .single(activeChannel: .location(Self.geohash), privatePeer: Self.meshPeer),
            fingerprint: Self.noFingerprint
        )
        sessions.primary.text = "geo text"
        sessions.secondary.text = ""

        sessions.saveAll()

        #expect(drafts.drafts[Self.geohashKey] == "geo text")
        #expect(drafts.drafts[Self.meshPeerKey] == nil, "a cleared composer drops its draft")
    }

    /// Panic: every slot forgets its text, suggestions, key and target and
    /// parks nothing; the retarget after the wipe loads only what the wiped
    /// store holds.
    @Test func resetForgetsEverySlotAndParksNothing() {
        let drafts = InMemoryComposerDraftStore()
        let sessions = makeSessions(drafts)
        sessions.retarget(
            .single(activeChannel: .location(Self.geohash), privatePeer: Self.meshPeer),
            fingerprint: Self.noFingerprint
        )
        sessions.primary.text = "geo text"
        sessions.secondary.text = "dm text"
        sessions.secondary.autocomplete = ComposerAutocompleteState(suggestions: ["@bob"], range: nil)
        drafts.clearLog()

        sessions.reset()

        for session in [sessions.primary, sessions.secondary] {
            #expect(session.text.isEmpty)
            #expect(!session.autocomplete.isShowing)
            #expect(session.draftKey == nil)
            #expect(session.target == nil)
        }
        sessions.saveAll()
        #expect(drafts.saves.isEmpty, "nothing pre-wipe is written back")

        // After the wipe (selection back on #mesh, no DM).
        let changed = sessions.retarget(Self.compactMesh, fingerprint: Self.noFingerprint)
        #expect(changed == [.primary])
        #expect(sessions.primary.target == .mesh)
        #expect(sessions.primary.text.isEmpty)
        #expect(drafts.saves.isEmpty)
    }

    // MARK: - What the root's composer glue calls

    /// Lets everything already queued on the main queue run first: the main
    /// queue runs its blocks in the order they were queued.
    private static func mainQueueHop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// I1: a send takes the composer's text and its conversation at once,
    /// and the text goes there after the hop whatever the composer, or the
    /// selection, points at by then.
    @Test func aSendGoesWhereItsComposerPointedWhenItWasTaken() async {
        let sessions = makeSessions(InMemoryComposerDraftStore())
        let sender = RecordingComposerSender()
        sessions.retarget(Self.compactGeohash, fingerprint: Self.noFingerprint)
        sessions.primary.text = "  gm geohash  "

        sessions.send(from: .primary, through: sender)
        #expect(sessions.primary.text.isEmpty, "taken at once")
        // The timeline moves to #mesh before the send goes out.
        sessions.retarget(Self.compactMesh, fingerprint: Self.noFingerprint)
        await Self.mainQueueHop()

        #expect(sender.sent.map(\.text) == ["gm geohash"])
        #expect(sender.sent.map(\.target) == [.publicChannel(.location(Self.geohash))])

        // Nothing to send, or nowhere to send it: nothing goes out.
        sessions.primary.text = "   "
        sessions.send(from: .primary, through: sender)
        sessions.secondary.text = "no conversation"
        sessions.send(from: .secondary, through: sender)
        await Self.mainQueueHop()
        #expect(sender.sent.count == 1)
        #expect(sessions.secondary.text == "no conversation")
    }

    private static func isRecording(_ recorder: VoiceRecordingViewModel) -> Bool {
        if case .recording = recorder.state { return true }
        return false
    }

    private static func startHold(on recorder: VoiceRecordingViewModel, owner: ComposerSlot) async -> Bool {
        let capture = MockVoiceCaptureSession()
        recorder.start(shouldShow: true, owner: owner, session: { capture })
        return await TestHelpers.waitUntil(
            { Self.isRecording(recorder) && recorder.isHolding(owner) },
            timeout: TestConstants.settleTimeout
        )
    }

    /// E12: a retarget ends the hold of a composer whose conversation
    /// changed, and only that one; the other composer's hold runs on.
    @Test func aRetargetEndsOnlyTheHoldOfAComposerThatChangedConversation() async {
        let sessions = makeSessions(InMemoryComposerDraftStore())
        let recorder = VoiceRecordingViewModel()
        defer { recorder.cancelAnyHold() }
        let dmOverMesh = ComposerTargets.single(activeChannel: .mesh, privatePeer: Self.meshPeer)
        let dmOverGeohash = ComposerTargets.single(activeChannel: .location(Self.geohash), privatePeer: Self.meshPeer)
        sessions.retarget(dmOverMesh, fingerprint: Self.noFingerprint, cancellingHoldsOn: recorder)

        // The DM composer holds the mic while the public timeline under the
        // DM switches channel: the DM keeps its conversation.
        #expect(await Self.startHold(on: recorder, owner: .secondary))
        sessions.retarget(dmOverGeohash, fingerprint: Self.noFingerprint, cancellingHoldsOn: recorder)
        #expect(recorder.isHolding(.secondary))
        #expect(Self.isRecording(recorder))

        // The DM closes: its composer has no conversation any more.
        sessions.retarget(Self.compactGeohash, fingerprint: Self.noFingerprint, cancellingHoldsOn: recorder)
        #expect(recorder.holdOwner == nil)
        #expect(recorder.state == .idle)

        // The public composer holds it while a DM opens over it: only the
        // other composer changed.
        #expect(await Self.startHold(on: recorder, owner: .primary))
        sessions.retarget(dmOverGeohash, fingerprint: Self.noFingerprint, cancellingHoldsOn: recorder)
        #expect(recorder.isHolding(.primary))
        #expect(Self.isRecording(recorder))

        // Its own timeline switches to #mesh under the DM.
        sessions.retarget(dmOverMesh, fingerprint: Self.noFingerprint, cancellingHoldsOn: recorder)
        #expect(recorder.holdOwner == nil)
        #expect(recorder.state == .idle)
    }

    private static func pick(from slot: ComposerSlot, in sessions: ComposerSessions) -> MediaPickRequest? {
        #if os(iOS)
        sessions.mediaPickRequest(from: slot, source: .photoLibrary)
        #else
        sessions.mediaPickRequest(from: slot)
        #endif
    }

    /// I1: a photo goes to the conversation of the composer whose button was
    /// pressed, as it was at the press, and only where photos can go.
    @Test func aMediaPickCarriesItsComposersConversationFromThePress() {
        let sessions = makeSessions(InMemoryComposerDraftStore())
        #expect(Self.pick(from: .primary, in: sessions) == nil, "no conversation yet")

        let dm = ConversationTarget(channel: .mesh, privatePeer: Self.meshPeer)
        sessions.retarget(.single(activeChannel: .mesh, privatePeer: Self.meshPeer), fingerprint: Self.noFingerprint)
        let publicPick = Self.pick(from: .primary, in: sessions)
        let dmPick = Self.pick(from: .secondary, in: sessions)
        #expect(publicPick?.target == .mesh)
        #expect(dmPick?.target == dm)
        #if os(iOS)
        #expect(dmPick?.source == .photoLibrary)
        #endif

        // The screen moves on while the picker is up: a geohash and a
        // geohash DM take no photos, and the pick in flight keeps the
        // conversation of its press.
        sessions.retarget(
            .single(activeChannel: .location(Self.geohash), privatePeer: Self.geoDMPeer),
            fingerprint: Self.noFingerprint
        )
        #expect(Self.pick(from: .primary, in: sessions) == nil)
        #expect(Self.pick(from: .secondary, in: sessions) == nil)
        #expect(dmPick?.target == dm)
    }

    /// I4: a panic forgets every composer at once, and points them at the
    /// screen again only once the wipe has landed, so nothing typed or
    /// parked before it comes back.
    @Test func aPanicPointsTheComposersAgainOnlyOnceTheWipeHasLanded() async {
        let drafts = InMemoryComposerDraftStore([.mesh: "parked before the wipe"])
        let sessions = makeSessions(drafts)
        var onScreen = ComposerTargets.single(activeChannel: .location(Self.geohash), privatePeer: Self.meshPeer)
        sessions.retarget(onScreen, fingerprint: Self.noFingerprint)
        sessions.primary.text = "geo text"
        sessions.secondary.text = "dm text"
        drafts.clearLog()

        sessions.resetForPanic(thenRetargetTo: { onScreen }, fingerprint: Self.noFingerprint)

        for session in [sessions.primary, sessions.secondary] {
            #expect(session.text.isEmpty)
            #expect(session.target == nil)
            #expect(session.draftKey == nil)
        }
        #expect(drafts.saves.isEmpty, "nothing typed before the wipe is parked")
        #expect(drafts.loads.isEmpty, "nothing is loaded before the wipe")

        // The wipe lands later in the same call: the drafts emptied, the
        // selection back on #mesh, the DM closed.
        drafts.wipe()
        onScreen = Self.compactMesh
        await Self.mainQueueHop()

        #expect(sessions.primary.target == .mesh)
        #expect(sessions.primary.text.isEmpty, "the draft parked before the wipe is gone")
        #expect(sessions.secondary.target == nil)
        #expect(drafts.saves.isEmpty)
    }

    // MARK: - One composer's own state

    @Test func insertMentionAppendsWithASpaceEitherSide() {
        let session = ComposerSession(slot: .primary)
        session.insertMention("alice")
        #expect(session.text == "@alice ")
        session.insertMention("bob")
        #expect(session.text == "@alice @bob ")
        session.text = "hi"
        session.insertMention("carol")
        #expect(session.text == "hi @carol ")
    }

    @Test func suggestionHighlightWrapsWithinTheShownRowsAndDismisses() {
        let session = ComposerSession(slot: .secondary)
        session.moveSuggestionSelection(by: 1)
        #expect(session.highlightedSuggestion == nil)

        session.autocomplete = ComposerAutocompleteState(
            suggestions: ["@a", "@b", "@c", "@d", "@e"],
            range: NSRange(location: 0, length: 2)
        )
        #expect(session.highlightedSuggestion == "@a")
        session.moveSuggestionSelection(by: -1)
        #expect(session.highlightedSuggestion == "@d", "wraps within the four rows shown")
        session.moveSuggestionSelection(by: 1)
        #expect(session.highlightedSuggestion == "@a")

        session.dismissSuggestions()
        #expect(!session.autocomplete.isShowing)
        #expect(session.highlightedSuggestion == nil)
    }

    /// Suggestions are computed for the composer's text and target as they
    /// are when typing pauses, and a retarget drops the old ones at once.
    @Test func suggestionsFollowTheComposersOwnTextAndTarget() async {
        let sessions = makeSessions(InMemoryComposerDraftStore())
        sessions.retarget(Self.compactMesh, fingerprint: Self.noFingerprint)
        var asked: [(String, ConversationTarget)] = []
        sessions.primary.text = "hi @al"
        sessions.primary.scheduleAutocomplete { text, target in
            asked.append((text, target))
            return ComposerAutocompleteState(suggestions: ["@alice"], range: NSRange(location: 3, length: 3))
        }

        let computed = await TestHelpers.waitUntil(
            { sessions.primary.autocomplete.isShowing },
            timeout: TestConstants.settleTimeout
        )
        #expect(computed)
        #expect(asked.count == 1)
        #expect(asked.first?.0 == "hi @al")
        #expect(asked.first?.1 == .mesh)
        #expect(!sessions.secondary.autocomplete.isShowing, "the other composer's stay its own")

        sessions.retarget(Self.compactGeohash, fingerprint: Self.noFingerprint)
        #expect(!sessions.primary.autocomplete.isShowing)
    }
}
