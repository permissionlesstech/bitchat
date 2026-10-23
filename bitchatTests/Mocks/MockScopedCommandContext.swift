//
// MockScopedCommandContext.swift
// bitchatTests
//
// A `CommandContextProvider` that records which channel, peer or scope
// every operation was handed, so scope tests can prove a command acts in
// the conversation it was typed into rather than the selection.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import BitFoundation
@testable import bitchat

@MainActor
final class MockScopedCommandContext: CommandContextProvider {
    var nickname = "me"
    /// The selection. A scoped command must never read it.
    var activeChannel: ChannelID = .mesh
    var selectedPrivateChatPeer: PeerID?
    var blockedUsers: Set<String> = []
    let idBridge = NostrIdentityBridge(keychain: MockKeychain())

    /// Names that resolve, per channel the lookup is scoped to.
    var peersByChannel: [ChannelID: [String: PeerID]] = [:]
    /// Participants reported per channel asked about.
    var geoParticipantsByChannel: [ChannelID: [CommandGeoParticipant]] = [:]
    /// Channels `sendPublicRaw`/`sendPublicMessage` refuse (a stale geohash).
    var refusedPublicChannels: Set<ChannelID> = []

    private(set) var lookups: [(name: String, scope: ChannelID)] = []
    private(set) var participantQueries: [ChannelID] = []
    private(set) var startedPrivateChats: [PeerID] = []
    private(set) var sentPrivateMessages: [(content: String, peerID: PeerID, scope: ChannelID)] = []
    private(set) var clearedPublicTimelines: [ChannelID] = []
    private(set) var clearedPrivateChats: [PeerID] = []
    private(set) var sentPublicRaw: [(content: String, channel: ChannelID)] = []
    private(set) var sentPublicMessages: [(content: String, channel: ChannelID)] = []
    private(set) var localPrivateSystemMessages: [(content: String, peerID: PeerID)] = []
    private(set) var publicSystemMessages: [(content: String, channel: ChannelID)] = []
    private(set) var commandOutputs: [(content: String, target: ConversationTarget)] = []
    private(set) var toggledFavorites: [PeerID] = []
    private(set) var groupCalls: [(subcommand: String, scope: ConversationTarget?)] = []

    func getPeerIDForNickname(_ nickname: String, in scope: ChannelID) -> PeerID? {
        lookups.append((nickname, scope))
        return peersByChannel[scope]?[nickname]
    }

    func getVisibleGeoParticipants(in scope: ChannelID) -> [CommandGeoParticipant] {
        participantQueries.append(scope)
        return geoParticipantsByChannel[scope] ?? []
    }

    func nostrPubkeyForDisplayName(_ displayName: String) -> String? { nil }

    private(set) var geohashBlockListChangeCount = 0
    func geohashBlockListDidChange() {
        geohashBlockListChangeCount += 1
    }

    func startPrivateChat(with peerID: PeerID) {
        startedPrivateChats.append(peerID)
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
        commandOutputs.append((content, target))
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
