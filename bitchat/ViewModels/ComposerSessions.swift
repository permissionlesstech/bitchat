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
    /// - Returns: The slots whose key changed. A hold on their mic belonged
    ///   to the conversation they no longer show, so the caller cancels it.
    @discardableResult
    func retarget(_ targets: ComposerTargets, fingerprint: (PeerID) -> String?) -> Set<ComposerSlot> {
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
}
