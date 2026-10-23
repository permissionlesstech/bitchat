//
// ChatOutgoingCoordinatorTargetTests.swift
// bitchatTests
//
// `ChatOutgoingCoordinator.sendMessage(_:to:)` sends where the target says,
// whatever is selected: #mesh text never reaches a selected geohash or DM,
// a DM goes to its own peer, and a geohash that isn't live gets nothing.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

@MainActor
private func drainMainActorTasks() async {
    for _ in 0..<10 { await Task.yield() }
}

struct ChatOutgoingCoordinatorTargetTests {
    private static let geohash = GeohashChannel(level: .city, geohash: "u4pruy")
    private static let otherGeohash = GeohashChannel(level: .city, geohash: "9q8yyk")
    private static let alice = PeerID(str: "a11ce000a11ce000")
    private static let bob = PeerID(str: "b0b0b0b0b0b0b0b0")

    @Test @MainActor
    func meshTargetTakesTheMeshPathWhateverIsSelected() async {
        // A geohash, a DM, and a DM opened in a geohash.
        let selections: [(channel: ChannelID, peer: PeerID?)] = [
            (.location(Self.geohash), nil),
            (.mesh, Self.alice),
            (.location(Self.geohash), Self.alice)
        ]
        for selection in selections {
            let context = MockTargetedOutgoingContext()
            let coordinator = ChatOutgoingCoordinator(context: context)
            context.activeChannel = selection.channel
            context.selectedPrivateChatPeer = selection.peer

            coordinator.sendMessage("hello mesh", to: .mesh)
            await coordinator.geohashMiningTask?.value
            await drainMainActorTasks()

            #expect(context.sentMeshMessages == ["hello mesh"])
            #expect(context.bridgedMessages == ["hello mesh"])
            #expect(context.appendedPublicMessages.map(\.conversationID) == [.mesh])
            #expect(context.appendedPublicMessages.first?.message.senderPeerID == context.myPeerID)
            #expect(context.recordedActivityKeys == ["mesh"])
            // Nothing reached the geohash or the open DM.
            #expect(context.sentGeohashContexts.isEmpty)
            #expect(context.derivedIdentityGeohashes.isEmpty)
            #expect(context.sentPrivateMessages.isEmpty)
            #expect(context.updatePrivateChatPeerIfNeededCount == 0)
        }
    }

    @Test @MainActor
    func dmTargetGoesToItsOwnPeerWhileAnotherDMIsSelected() {
        let context = MockTargetedOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)
        context.selectedPrivateChatPeer = Self.alice
        context.selectedPeerAfterUpdate = PeerID(str: "a11ce000a11ce0ff")

        coordinator.sendMessage("for bob", to: ConversationTarget(channel: .mesh, privatePeer: Self.bob))

        #expect(context.sentPrivateMessages.count == 1)
        #expect(context.sentPrivateMessages.first?.peerID == Self.bob)
        #expect(context.sentPrivateMessages.first?.scope == .mesh)
        // Only the open DM is re-resolved; bob's chat isn't it.
        #expect(context.updatePrivateChatPeerIfNeededCount == 0)
        #expect(context.sentMeshMessages.isEmpty)
        #expect(context.appendedPublicMessages.isEmpty)
    }

    @Test @MainActor
    func theOpenDMIsReResolvedBeforeSending() {
        let context = MockTargetedOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)
        let stableAlice = PeerID(str: String(repeating: "a1", count: 32))
        context.selectedPrivateChatPeer = Self.alice
        context.selectedPeerAfterUpdate = stableAlice

        coordinator.sendMessage("hi", to: ConversationTarget(channel: .mesh, privatePeer: Self.alice))
        #expect(context.updatePrivateChatPeerIfNeededCount == 1)
        #expect(context.sentPrivateMessages.map(\.peerID) == [stableAlice])

        // A target bound before a handoff is still the open DM: it re-resolves
        // to the conversation's current routing ID instead of the stale one.
        context.sameConversationPairs = [[stableAlice, Self.alice]]
        coordinator.sendMessage("again", to: ConversationTarget(channel: .mesh, privatePeer: Self.alice))
        #expect(context.updatePrivateChatPeerIfNeededCount == 2)
        #expect(context.sentPrivateMessages.map(\.peerID) == [stableAlice, stableAlice])
    }

    @Test @MainActor
    func aGeohashTargetThatIsNotLiveSendsNothing() async {
        let context = MockTargetedOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)
        let stale = ConversationTarget.publicChannel(.location(Self.geohash))

        for selected in [ChannelID.mesh, .location(Self.otherGeohash)] {
            context.activeChannel = selected
            coordinator.sendMessage("too late", to: stale)
            await coordinator.geohashMiningTask?.value
            await drainMainActorTasks()
        }

        #expect(context.sentGeohashContexts.isEmpty)
        #expect(context.derivedIdentityGeohashes.isEmpty)
        #expect(context.appendedPublicMessages.isEmpty)
        #expect(context.sentMeshMessages.isEmpty)
        // It says so in the conversation it was aimed at.
        #expect(context.systemMessages.map(\.target) == [stale, stale])
    }

    @Test @MainActor
    func aLiveGeohashTargetSignsSendsAndReportsInItsOwnChannel() async {
        let context = MockTargetedOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)
        let target = ConversationTarget.publicChannel(.location(Self.geohash))
        context.activeChannel = .location(Self.geohash)
        context.selectedPrivateChatPeer = Self.alice
        context.teleportedGeohashes = ["u4pruy"]

        coordinator.sendMessage("hello geo", to: target)
        await coordinator.geohashMiningTask?.value
        await drainMainActorTasks()

        #expect(context.derivedIdentityGeohashes == ["u4pruy"])
        #expect(context.teleportQueries == ["u4pruy"])
        #expect(context.sentGeohashContexts.count == 1)
        #expect(context.sentGeohashContexts.first?.channel == Self.geohash)
        #expect(context.sentGeohashContexts.first?.teleported == true)
        #expect(context.appendedPublicMessages.map(\.conversationID) == [.geohash("u4pruy")])
        #expect(context.recordedActivityKeys == ["geo:u4pruy"])
        #expect(context.sentPrivateMessages.isEmpty)
        #expect(context.sentMeshMessages.isEmpty)

        // A failure lands in the geohash it was aimed at.
        context.deriveNostrIdentityError = MockTargetedOutgoingContext.IdentityUnavailable()
        coordinator.sendMessage("doomed", to: target)
        #expect(context.systemMessages.map(\.target) == [target])
    }

    @Test @MainActor
    func aGeohashSendThatFailsAfterTheSelectionMovedReportsInItsOwnChannel() async {
        let context = MockTargetedOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)
        let target = ConversationTarget.publicChannel(.location(Self.geohash))
        context.activeChannel = .location(Self.geohash)
        context.identityCannotSign = true

        coordinator.sendMessage("doomed", to: target)
        // The selection moves on (another geohash, a DM over it) before the
        // mining task gets to sign, and fails.
        context.activeChannel = .location(Self.otherGeohash)
        context.selectedPrivateChatPeer = Self.alice
        await coordinator.geohashMiningTask?.value
        await drainMainActorTasks()

        #expect(context.systemMessages.map(\.target) == [target])
        #expect(context.systemMessages.map(\.content) == [String(localized: "system.location.send_failed")])
        #expect(context.sentGeohashContexts.isEmpty)
        #expect(context.appendedPublicMessages.isEmpty)
    }

    @Test @MainActor
    func aCommandRunsInTheTargetItWasSentFrom() async {
        let context = MockTargetedOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)
        context.selectedPrivateChatPeer = Self.alice

        coordinator.sendMessage("/who", to: .mesh)
        // The selection moves before the command's hop runs.
        context.selectedPrivateChatPeer = Self.bob
        context.activeChannel = .location(Self.geohash)
        let handled = await TestHelpers.waitUntil({ !context.handledCommands.isEmpty }, timeout: TestConstants.settleTimeout)

        #expect(handled)
        #expect(context.handledCommands.map(\.command) == ["/who"])
        #expect(context.handledCommands.map(\.origin) == [.mesh])
        #expect(context.sentMeshMessages.isEmpty)
        #expect(context.sentPrivateMessages.isEmpty)
    }

    @Test @MainActor
    func aGeohashDMKeepsTheScopeItWasSentIn() {
        let context = MockTargetedOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)
        let geoDM = PeerID(nostr_: String(repeating: "cd", count: 32))
        // The selection has already moved to #mesh.
        context.activeChannel = .mesh

        coordinator.sendMessage(
            "psst",
            to: ConversationTarget(channel: .location(Self.geohash), privatePeer: geoDM)
        )

        #expect(context.sentPrivateMessages.count == 1)
        #expect(context.sentPrivateMessages.first?.peerID == geoDM)
        #expect(context.sentPrivateMessages.first?.scope == .location(Self.geohash))
    }
}
