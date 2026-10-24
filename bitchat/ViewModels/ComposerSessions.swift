//
// ComposerSessions.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Combine
import Foundation
#if os(iOS)
import UIKit
#endif

/// Where each composer on screen sends: the conversation of the timeline it
/// sits under. Built only through `single` and `split`, whose two slots can
/// never name the same conversation.
struct ComposerTargets: Equatable {
    /// The composer under the main timeline. Compact: the public channel the
    /// timeline shows. Split: the leading #mesh pane. It always has one.
    let primary: ConversationTarget
    /// The other conversation's composer. Compact: the DM sheet's, nil while
    /// no DM is open. Split: the trailing pane's geohash or the DM covering
    /// it, nil while the trailing pane shows the picker (no composer).
    let secondary: ConversationTarget?

    /// Compact and macOS: the selection, verbatim. The primary sends to the
    /// public channel the timeline shows; an open DM is scoped to that
    /// channel, as the single composer always scoped it.
    static func single(activeChannel: ChannelID, privatePeer: PeerID?) -> ComposerTargets {
        ComposerTargets(
            primary: .publicChannel(activeChannel),
            secondary: privatePeer.map { ConversationTarget(channel: activeChannel, privatePeer: $0) }
        )
    }

    #if os(iOS)
    /// The split layout: #mesh in the leading pane, and in the trailing pane
    /// the DM covering it, else its geohash, else nothing (the picker).
    /// A DM's scope is its own network: a geohash DM signs with the trailing
    /// geohash's identity (#mesh, where its sends fail into the thread, if
    /// none is selected); mesh DMs and groups live on #mesh.
    static func split(trailingChannel: GeohashChannel?, privatePeer: PeerID?) -> ComposerTargets {
        let trailing: ConversationTarget?
        if let peer = privatePeer {
            let isGeohashConversation = peer.isGeoDM || peer.isGeoChat
            let scope = isGeohashConversation ? trailingChannel.map(ChannelID.location) ?? .mesh : .mesh
            trailing = ConversationTarget(channel: scope, privatePeer: peer)
        } else {
            trailing = trailingChannel.map { .publicChannel(.location($0)) }
        }
        return ComposerTargets(primary: .mesh, secondary: trailing)
    }
    #endif

    subscript(slot: ComposerSlot) -> ConversationTarget? {
        switch slot {
        case .primary: primary
        case .secondary: secondary
        }
    }

    /// The slot whose composer sends into `conversation`, if one does. Focus
    /// follows a conversation across a layout change this way: a DM or a
    /// geohash can change slots, and a DM its scope.
    func slot(showing conversation: ConversationID) -> ComposerSlot? {
        if primary.conversationID == conversation { return .primary }
        if secondary?.conversationID == conversation { return .secondary }
        return nil
    }

    /// The composer shared content goes into (E11): `preferred` while it has
    /// a conversation, else the primary, which always has one. Compact
    /// prefers the DM slot, so an open DM gets it; the split layout prefers
    /// the last-touched pane's.
    func shareImportSlot(preferring preferred: ComposerSlot) -> ComposerSlot {
        self[preferred] == nil ? .primary : preferred
    }
}

/// A camera or library press in a composer, with the conversation the pick
/// goes to: the composer's own, taken at the press, so a pick can never land
/// in another conversation however the screen changes while the picker is
/// up.
struct MediaPickRequest: Identifiable {
    let id = UUID()
    let target: ConversationTarget
    #if os(iOS)
    let source: UIImagePickerController.SourceType
    #endif
}

/// Sends a composer's text to the conversation it was taken for. There is
/// no form without a target: a composer never sends to the selection.
/// `ConversationUIModel` is the app's.
@MainActor
protocol ComposerMessageSending: AnyObject {
    func sendMessage(_ message: String, to target: ConversationTarget)
}

extension ConversationUIModel: ComposerMessageSending {}

/// Where `ComposerSessions` parks the text of a conversation no composer
/// shows any more, and loads it back. The app parks in `ComposerDraftStore`
/// (in memory, capped, reset by a panic wipe); tests park in their own map.
protocol ComposerDraftStoring {
    func load(_ key: ComposerDraftStore.Key) -> String
    func save(_ text: String, for key: ComposerDraftStore.Key)
}

/// The app's process-wide `ComposerDraftStore`.
struct SharedComposerDraftStore: ComposerDraftStoring {
    func load(_ key: ComposerDraftStore.Key) -> String {
        ComposerDraftStore.load(key)
    }

    func save(_ text: String, for key: ComposerDraftStore.Key) {
        ComposerDraftStore.save(text, for: key)
    }
}

/// One composer: the text being typed, its own mention suggestions, the
/// conversation it sends to and the draft key that text is parked under.
/// Its composer view observes it; nothing else does, so typing re-renders
/// that composer alone. `ComposerSessions` points it at its conversation.
@MainActor
final class ComposerSession: ObservableObject {
    /// How long typing has to pause before suggestions are recomputed.
    static let autocompleteDelay: TimeInterval = 0.15
    /// Rows the mention panel shows; the highlight cycles through these.
    static let visibleSuggestionCount = 4

    let slot: ComposerSlot
    /// The live, unsent text.
    @Published var text = ""
    #if os(iOS)
    /// Fires for each edit the person makes in this composer's field
    /// (typing, dictation, a paste), never for text set from outside it: a
    /// draft swap, a mention, a send, a panic reset. The split layout
    /// counts it as a touch in the composer's pane (E1): keystrokes land in
    /// the keyboard's window, out of the touch observer's sight.
    let edits = PassthroughSubject<Void, Never>()
    #endif
    /// This composer's own mention suggestions, for its own text and target.
    @Published var autocomplete = ComposerAutocompleteState()
    /// Where this composer sends; nil while it has no conversation. Set only
    /// by `ComposerSessions.retarget`.
    fileprivate(set) var target: ConversationTarget?
    /// The key `text` belongs to. Set only by `ComposerSessions.retarget`.
    fileprivate(set) var draftKey: ComposerDraftStore.Key?
    private var autocompleteTimer: Timer?

    init(slot: ComposerSlot) {
        self.slot = slot
    }

    /// The composer's field writes the person's edits through here. A
    /// write that changes nothing (the field taking or giving up the
    /// keyboard) is no edit.
    func edit(_ newText: String) {
        guard newText != text else { return }
        text = newText
        #if os(iOS)
        edits.send()
        #endif
    }

    /// Appends an @mention to the text (never overwrites what is already
    /// typed), with a space on either side.
    func insertMention(_ sender: String) {
        let mention = "@\(sender) "
        if text.isEmpty {
            text = mention
        } else if text.hasSuffix(" ") {
            text += mention
        } else {
            text += " " + mention
        }
    }

    /// Recomputes the suggestions once typing pauses. `compute` gets the text
    /// and target as they are by then, so it always answers for this
    /// composer's current conversation; without one the suggestions clear.
    func scheduleAutocomplete(
        _ compute: @escaping @MainActor (String, ConversationTarget) -> ComposerAutocompleteState
    ) {
        autocompleteTimer?.invalidate()
        autocompleteTimer = Timer.scheduledTimer(withTimeInterval: Self.autocompleteDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAutocomplete(compute)
            }
        }
    }

    /// The highlighted suggestion, if the panel shows one.
    var highlightedSuggestion: String? {
        guard autocomplete.suggestions.indices.contains(autocomplete.selectedIndex) else { return nil }
        return autocomplete.suggestions[autocomplete.selectedIndex]
    }

    /// Moves the highlight by `delta`, wrapping within the rows shown.
    func moveSuggestionSelection(by delta: Int) {
        guard autocomplete.isShowing else { return }
        let count = min(Self.visibleSuggestionCount, autocomplete.suggestions.count)
        autocomplete.selectedIndex = (autocomplete.selectedIndex + delta + count) % count
    }

    /// Hides the suggestions without inserting one (Escape, or a pick).
    func dismissSuggestions() {
        guard autocomplete != ComposerAutocompleteState() else { return }
        autocomplete = ComposerAutocompleteState()
    }

    /// Drops the suggestions and any recomputation still waiting.
    fileprivate func cancelAutocomplete() {
        autocompleteTimer?.invalidate()
        autocompleteTimer = nil
        dismissSuggestions()
    }

    private func refreshAutocomplete(
        _ compute: @MainActor (String, ConversationTarget) -> ComposerAutocompleteState
    ) {
        autocompleteTimer = nil
        let state = target.map { compute(text, $0) } ?? ComposerAutocompleteState()
        // Each write re-renders the composer: write only a change.
        if autocomplete != state {
            autocomplete = state
        }
    }
}

/// Every composer's session, one per slot, and the one place their texts
/// move between conversations. Owned by `ContentView` and handed to the views
/// by parameter. It publishes nothing itself: each composer observes its own
/// session.
///
/// Invariant: no two slots hold the same draft key, so one conversation's
/// text is never live in two composers.
@MainActor
final class ComposerSessions: ObservableObject {
    let primary = ComposerSession(slot: .primary)
    let secondary = ComposerSession(slot: .secondary)
    private let drafts: any ComposerDraftStoring
    /// From a panic's reset until its own retarget, one main-queue hop
    /// later. The wipe in between publishes as it goes (the timelines
    /// emptying, the DM closing), and a retarget one of those set off would
    /// load a draft the wipe hasn't emptied yet: every retarget waits for
    /// the panic's.
    private var awaitsPanicRetarget = false

    init(drafts: any ComposerDraftStoring = SharedComposerDraftStore()) {
        self.drafts = drafts
    }

    subscript(slot: ComposerSlot) -> ComposerSession {
        switch slot {
        case .primary: primary
        case .secondary: secondary
        }
    }

    private var sessions: [ComposerSession] { [primary, secondary] }

    /// Points every slot at its new target in one step, so a conversation
    /// moving between slots (a fold or unfold) takes its text along:
    /// 1. the live texts are snapshotted under the keys the slots hold;
    /// 2. each slot whose key changed takes the live text of whichever slot
    ///    showed that key, else that key's parked draft;
    /// 3. keys no slot shows any more are parked.
    ///
    /// A DM keeps the key it was opened under for as long as it stays open:
    /// its scope can follow the channel, and a fingerprint learnt mid-
    /// conversation must not swap its text away.
    ///
    /// Idempotent: retargeting to the targets the slots already have changes
    /// nothing, so every change of what a composer shows can retarget at
    /// once. Between a panic's reset and its own retarget it does nothing
    /// (`resetForPanic`).
    ///
    /// - Returns: The slots whose key changed. A hold on their mic belonged
    ///   to the conversation they no longer show, so the caller cancels it.
    @discardableResult
    func retarget(_ targets: ComposerTargets, fingerprint: (PeerID) -> String?) -> Set<ComposerSlot> {
        guard !awaitsPanicRetarget else { return [] }
        var liveTexts: [ComposerDraftStore.Key: String] = [:]
        var openDMKeys: [PeerID: ComposerDraftStore.Key] = [:]
        for session in sessions {
            guard let key = session.draftKey else { continue }
            liveTexts[key] = session.text
            if let peer = session.target?.privatePeer {
                openDMKeys[peer] = key
            }
        }

        // The primary is keyed first: were both slots ever to resolve to one
        // conversation, it keeps that text and the secondary holds none.
        var newKeys: [ComposerSlot: ComposerDraftStore.Key] = [:]
        for session in sessions {
            guard let target = targets[session.slot] else { continue }
            let key = target.privatePeer.flatMap { openDMKeys[$0] }
                ?? target.draftKey(fingerprint: target.privatePeer.flatMap(fingerprint))
            if !newKeys.values.contains(key) {
                newKeys[session.slot] = key
            }
        }

        var changed = Set<ComposerSlot>()
        var incomingTexts: [ComposerSlot: String] = [:]
        for session in sessions where newKeys[session.slot] != session.draftKey {
            changed.insert(session.slot)
            incomingTexts[session.slot] = newKeys[session.slot].map { key in
                liveTexts[key] ?? drafts.load(key)
            } ?? ""
        }

        let shownKeys = Set(newKeys.values)
        for (key, text) in liveTexts where !shownKeys.contains(key) {
            drafts.save(text, for: key)
        }

        for session in sessions {
            session.target = targets[session.slot]
            session.draftKey = newKeys[session.slot]
            guard let text = incomingTexts[session.slot] else { continue }
            if session.text != text {
                session.text = text
            }
            // Suggestions belong to the conversation they were made in.
            session.dismissSuggestions()
        }
        return changed
    }

    /// `retarget(_:fingerprint:)`, then cancels the mic hold of each slot
    /// whose conversation changed: that hold was recording for a
    /// conversation its composer no longer shows. A hold in a slot that kept
    /// its conversation (the other composer moved, or a DM's peer-ID
    /// handoff) runs on.
    func retarget(
        _ targets: ComposerTargets,
        fingerprint: (PeerID) -> String?,
        cancellingHoldsOn recorder: VoiceRecordingViewModel
    ) {
        for slot in retarget(targets, fingerprint: fingerprint) {
            recorder.cancel(owner: slot)
        }
    }

    /// Sends `slot`'s text: takes it, with the conversation it goes to, now,
    /// and hands both to `sender` one main-queue hop later, once the text
    /// field has finished its submit. Whatever the selection or the screen
    /// does in between, the text goes where its composer pointed when it was
    /// taken (I1). Nothing to send, or nowhere to send it, sends nothing.
    func send(from slot: ComposerSlot, through sender: some ComposerMessageSending) {
        guard let outgoing = takeOutgoing(from: slot) else { return }
        DispatchQueue.main.async {
            sender.sendMessage(outgoing.text, to: outgoing.target)
        }
    }

    /// Whether `slot` points at `target`, the conversation its composer shows
    /// now. It must whenever the composer sends or picks: a difference is a
    /// retarget missed, and the text or photo would go where the screen no
    /// longer says (I1). A panic's reset counts as current until its own
    /// retarget lands.
    func points(_ slot: ComposerSlot, at target: ConversationTarget?) -> Bool {
        awaitsPanicRetarget || self[slot].target == target
    }

    #if os(iOS)
    /// A camera or library press in `slot`'s composer, with the conversation
    /// the pick goes to: that composer's own as of the press, however the
    /// screen changes while the picker is up. Nil where the composer takes
    /// no photos (a geohash, a group) or has no conversation.
    func mediaPickRequest(
        from slot: ComposerSlot,
        source: UIImagePickerController.SourceType
    ) -> MediaPickRequest? {
        mediaTarget(of: slot).map { MediaPickRequest(target: $0, source: source) }
    }
    #else
    /// A photo-button press in `slot`'s composer, with the conversation the
    /// pick goes to: that composer's own as of the press. Nil where the
    /// composer takes no photos (a geohash, a group) or has no conversation.
    func mediaPickRequest(from slot: ComposerSlot) -> MediaPickRequest? {
        mediaTarget(of: slot).map { MediaPickRequest(target: $0) }
    }
    #endif

    private func mediaTarget(of slot: ComposerSlot) -> ConversationTarget? {
        guard let target = self[slot].target, target.allowsMedia else { return nil }
        return target
    }

    /// Takes the slot's text to send: trimmed, with the target it goes to as
    /// of now. The composer and its parked draft are emptied. Nil, leaving
    /// everything as it was, when there is nothing to send or nowhere to
    /// send it.
    func takeOutgoing(from slot: ComposerSlot) -> (text: String, target: ConversationTarget)? {
        let session = self[slot]
        guard let target = session.target,
              let text = session.text.trimmedOrNilIfEmpty
        else { return nil }
        session.text = ""
        session.cancelAutocomplete()
        if let key = session.draftKey {
            drafts.save("", for: key)
        }
        return (text, target)
    }

    /// Parks every slot's text under its key, empty included: clearing a
    /// composer must also drop the draft, or it would come back on the next
    /// visit to that conversation.
    func saveAll() {
        for session in sessions {
            guard let key = session.draftKey else { continue }
            drafts.save(session.text, for: key)
        }
    }

    /// Panic: every slot forgets its text, suggestions, pending
    /// recomputation, key and target, parking nothing. The next `retarget`
    /// points the slots at what is on screen again.
    func reset() {
        for session in sessions {
            session.text = ""
            session.cancelAutocomplete()
            session.draftKey = nil
            session.target = nil
        }
    }

    /// Panic: `reset()` at once, ahead of the wipe that empties the parked
    /// drafts later in the same call, so nothing typed before it can be
    /// parked again. One main-queue hop later, once that wipe has landed
    /// (the drafts empty, the selection back on #mesh, any DM closed), the
    /// slots point at `targets()` as they are by then. Pointed any sooner, a
    /// slot would load a draft the wipe is about to empty, so any other
    /// retarget meanwhile (one the wipe's own changes set off) does
    /// nothing. No hold is left to cancel: the recorder's own panic wipe
    /// ended it first.
    func resetForPanic(
        thenRetargetTo targets: @escaping () -> ComposerTargets,
        fingerprint: @escaping (PeerID) -> String?
    ) {
        reset()
        awaitsPanicRetarget = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.awaitsPanicRetarget = false
            self.retarget(targets(), fingerprint: fingerprint)
        }
    }
}
