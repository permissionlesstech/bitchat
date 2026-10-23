//
// ChatGroupCoordinatorScopeTests.swift
// bitchatTests
//
// /group invite, remove and leave manage the group of the conversation they
// were typed into, never whichever chat happens to be open.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
import BitFoundation
@testable import bitchat

@MainActor
struct ChatGroupCoordinatorScopeTests {
    private let otherDM = PeerID(str: "b0b0b0b0b0b0b0b0")

    private func isError(_ result: CommandResult) -> Bool {
        if case .error = result { return true }
        return false
    }

    /// Creates a group we own and returns its chat's peer ID; creating it
    /// opens its chat, as `/group create` does.
    private func makeGroup(_ context: MockScopedGroupContext, _ coordinator: ChatGroupCoordinator) throws -> PeerID {
        _ = coordinator.createGroup(named: "trail")
        return try #require(context.groupStore.groups.first?.peerID)
    }

    @Test func aPublicScopeManagesNoGroupWhileOneIsOpen() throws {
        let context = MockScopedGroupContext()
        let coordinator = ChatGroupCoordinator(context: context)
        let group = try makeGroup(context, coordinator)
        #expect(context.selectedPrivateChatPeer == group)

        #expect(isError(coordinator.inviteMember(nickname: "bob", in: .mesh)))
        #expect(isError(coordinator.removeMember(nickname: "bob", in: .mesh)))
        #expect(isError(coordinator.leaveGroup(in: .mesh)))

        // None of them reached the open group.
        #expect(context.lookups.isEmpty)
        #expect(context.removedPrivateChats.isEmpty)
        #expect(context.endPrivateChatCount == 0)
        #expect(context.groupStore.groups.count == 1)
    }

    @Test func inviteLooksTheInviteeUpInTheGroupsOwnScope() throws {
        let context = MockScopedGroupContext()
        let coordinator = ChatGroupCoordinator(context: context)
        let group = try makeGroup(context, coordinator)
        // The selection has moved to another chat since.
        context.selectedPrivateChatPeer = otherDM

        _ = coordinator.inviteMember(nickname: "bob", in: ConversationTarget(channel: .mesh, privatePeer: group))

        #expect(context.lookups.map(\.name) == ["bob"])
        #expect(context.lookups.map(\.scope) == [.mesh])
    }

    @Test func leavingClosesTheGroupsChatOnlyWhenItIsTheOpenOne() throws {
        let context = MockScopedGroupContext()
        let coordinator = ChatGroupCoordinator(context: context)
        let group = try makeGroup(context, coordinator)
        context.selectedPrivateChatPeer = otherDM

        let result = coordinator.leaveGroup(in: ConversationTarget(channel: .mesh, privatePeer: group))

        #expect(!isError(result))
        #expect(context.removedPrivateChats == [group])
        #expect(context.groupStore.groups.isEmpty)
        // The DM open elsewhere stays open.
        #expect(context.endPrivateChatCount == 0)
        #expect(context.selectedPrivateChatPeer == otherDM)

        // Leaving the open group closes its chat first.
        let second = try makeGroup(context, coordinator)
        _ = coordinator.leaveGroup(in: ConversationTarget(channel: .mesh, privatePeer: second))
        #expect(context.endPrivateChatCount == 1)
        #expect(context.removedPrivateChats == [group, second])
    }
}
