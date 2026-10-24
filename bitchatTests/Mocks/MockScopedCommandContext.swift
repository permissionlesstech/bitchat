//
// MockScopedCommandContext.swift
// bitchatTests
//
// A `CommandContextProvider` that records which channel, peer or scope
// every operation was handed, so tests can prove a command acts in the
// conversation it was typed into rather than the selection. Every
// `CommandProcessor` suite shares it.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import BitFoundation
@testable import bitchat

@MainActor
final class MockScopedCommandContext: CommandContextProvider {
    var nickname: String
    /// The selection: no `CommandContextProvider` requirement, so a command
    /// can't read it. Tests that type where a single composer would build
    /// the scope from it (`selectionTarget`).
    var activeChannel: ChannelID = .mesh
    var selectedPrivateChatPeer: PeerID?
    var blockedUsers: Set<String> = []
    let idBridge: NostrIdentityBridge
    /// The private chats; `/clear` in a DM empties that one.
    var privateChats: [PeerID: [BitchatMessage]] = [:]

    /// Names that resolve in every scope.
    var nicknameToPeerID: [String: PeerID] = [:]
    /// Names that resolve, per channel the lookup is scoped to, ahead of
    /// `nicknameToPeerID`.
    var peersByChannel: [ChannelID: [String: PeerID]] = [:]
    /// Participants reported whatever channel is asked about.
    var visibleGeoParticipants: [CommandGeoParticipant] = []
    /// Participants reported per channel asked about, ahead of
    /// `visibleGeoParticipants`.
    var geoParticipantsByChannel: [ChannelID: [CommandGeoParticipant]] = [:]
    /// Geohash participants' pubkeys by display name, whatever channel is
    /// asked about.
    var displayNameToNostrPubkey: [String: String] = [:]
    /// Geohash participants' pubkeys by display name, per channel asked
    /// about, ahead of `displayNameToNostrPubkey`.
    var geoPubkeysByChannel: [ChannelID: [String: String]] = [:]
    /// Channels `sendPublicRaw`/`sendPublicMessage` refuse (a stale geohash).
    var refusedPublicChannels: Set<ChannelID> = []

    private(set) var lookups: [(name: String, scope: ChannelID)] = []
    private(set) var participantQueries: [ChannelID] = []
    private(set) var geoPubkeyLookups: [(name: String, scope: ChannelID)] = []
    private(set) var geohashBlockListChangeCount = 0
    private(set) var startedPrivateChats: [PeerID] = []
    /// Where each started chat's refusal would land.
    private(set) var startedPrivateChatOrigins: [ConversationTarget] = []
    private(set) var sentPrivateMessages: [(content: String, peerID: PeerID, scope: ChannelID)] = []
    private(set) var clearedPublicTimelines: [ChannelID] = []
    private(set) var clearedPrivateChats: [PeerID] = []
    private(set) var sentPublicRaw: [(content: String, channel: ChannelID)] = []
    private(set) var sentPublicMessages: [(content: String, channel: ChannelID)] = []
    private(set) var localPrivateSystemMessages: [(content: String, peerID: PeerID)] = []
    private(set) var publicSystemMessages: [(content: String, channel: ChannelID)] = []
    private(set) var commandOutputs: [String] = []
    private(set) var commandOutputDestinations: [ConversationTarget] = []
    private(set) var toggledFavorites: [PeerID] = []
    private(set) var groupCalls: [(subcommand: String, scope: ConversationTarget?)] = []

    init(nickname: String = "me", idBridge: NostrIdentityBridge = NostrIdentityBridge(keychain: MockKeychain())) {
        self.nickname = nickname
        self.idBridge = idBridge
    }

    /// What a command typed into the selection runs in: the open DM, else
    /// the selected channel.
    var selectionTarget: ConversationTarget {
        ConversationTarget(channel: activeChannel, privatePeer: selectedPrivateChatPeer)
    }

    func getPeerIDForNickname(_ nickname: String, in scope: ChannelID) -> PeerID? {
        lookups.append((nickname, scope))
        return peersByChannel[scope]?[nickname] ?? nicknameToPeerID[nickname]
    }

    func getVisibleGeoParticipants(in scope: ChannelID) -> [CommandGeoParticipant] {
        participantQueries.append(scope)
        return geoParticipantsByChannel[scope] ?? visibleGeoParticipants
    }

    func nostrPubkeyForDisplayName(_ displayName: String, in scope: ChannelID) -> String? {
        geoPubkeyLookups.append((displayName, scope))
        return geoPubkeysByChannel[scope]?[displayName] ?? displayNameToNostrPubkey[displayName]
    }

    func geohashBlockListDidChange() {
        geohashBlockListChangeCount += 1
    }

    func startPrivateChat(with peerID: PeerID, from origin: ConversationTarget) {
        startedPrivateChats.append(peerID)
        startedPrivateChatOrigins.append(origin)
        selectedPrivateChatPeer = peerID
    }

    func sendPrivateMessage(_ content: String, to peerID: PeerID, scope: ChannelID) {
        sentPrivateMessages.append((content, peerID, scope))
    }

    func clearPublicTimeline(_ channel: ChannelID) {
        clearedPublicTimelines.append(channel)
    }

    func clearPrivateChat(_ peerID: PeerID) {
        clearedPrivateChats.append(peerID)
        privateChats[peerID] = []
    }

    func sendPublicRaw(_ content: String, to channel: ChannelID) -> Bool {
        guard !refusedPublicChannels.contains(channel) else { return false }
        sentPublicRaw.append((content, channel))
        return true
    }

    func sendPublicMessage(_ content: String, to channel: ChannelID) -> Bool {
        guard !refusedPublicChannels.contains(channel) else { return false }
        sentPublicMessages.append((content, channel))
        return true
    }

    func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID) {
        localPrivateSystemMessages.append((content, peerID))
    }

    func addPublicSystemMessage(_ content: String, to channel: ChannelID) {
        publicSystemMessages.append((content, channel))
    }

    func addCommandOutput(_ content: String, to target: ConversationTarget) {
        commandOutputs.append(content)
        commandOutputDestinations.append(target)
    }

    func toggleFavorite(peerID: PeerID) {
        toggledFavorites.append(peerID)
    }

    func groupCreate(named name: String) -> CommandResult {
        groupCalls.append(("create", nil))
        return .handled
    }

    func groupInvite(nickname: String, in scope: ConversationTarget) -> CommandResult {
        groupCalls.append(("invite", scope))
        return .handled
    }

    func groupRemove(nickname: String, in scope: ConversationTarget) -> CommandResult {
        groupCalls.append(("remove", scope))
        return .handled
    }

    func groupLeave(in scope: ConversationTarget) -> CommandResult {
        groupCalls.append(("leave", scope))
        return .handled
    }

    func groupList() -> CommandResult {
        groupCalls.append(("list", nil))
        return .handled
    }
}
