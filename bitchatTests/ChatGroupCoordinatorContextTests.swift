//
// ChatGroupCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatGroupCoordinator`'s group-state authorization against a
// mock `ChatGroupContext` and a real in-memory `GroupStore`, with real
// Ed25519 creator signatures. The Noise session binding is modelled by
// `MockChatGroupContext.fingerprintsByPeerID` (what `meshFingerprint(for:)`
// reports for the authenticated session peer). Store-level pinning is
// covered by `GroupStoreTests`; wire/crypto by `GroupProtocolTests`.
// The shared-list tests pass real sealed updates between two members'
// coordinators to check that edits made apart converge.
//

import CryptoKit
import Foundation
import Testing
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

@MainActor
private final class MockChatGroupContext: ChatGroupContext {
    // Identity & state
    let nickname = "me"
    let myPeerID: PeerID
    var selectedPrivateChatPeer: PeerID?
    let groupStore = GroupStore(keychain: MockKeychain(), persistsToDisk: false)

    private let identity: TestIdentity

    init(identity: TestIdentity) {
        self.identity = identity
        self.myPeerID = identity.peerID
    }

    func myNoiseFingerprint() -> String { identity.fingerprint }
    func mySigningPublicKey() -> Data { identity.member.signingKey }
    func signWithNoiseKey(_ data: Data) -> Data? { identity.sign(data) }

    // Peers: the fingerprint each Noise session authenticated.
    var fingerprintsByPeerID: [PeerID: String] = [:]

    func getPeerIDForNickname(_ nickname: String) -> PeerID? { nil }
    func isPeerConnected(_ peerID: PeerID) -> Bool { false }
    func peerNickname(for peerID: PeerID) -> String? { nil }
    func meshFingerprint(for peerID: PeerID) -> String? { fingerprintsByPeerID[peerID] }
    func cryptoIdentity(for peerID: PeerID) -> (fingerprint: String, signingKey: Data)? { nil }
    func connectedPeerID(forFingerprint fingerprint: String) -> PeerID? { nil }
    func isFingerprintBlocked(_ fingerprint: String) -> Bool { false }

    // Transport (outbound state is not exercised by these tests)
    private(set) var broadcastPayloads: [Data] = []

    func sendGroupInvitePayload(_ payload: Data, to peerID: PeerID) {}
    func sendGroupKeyUpdatePayload(_ payload: Data, to peerID: PeerID) {}
    func broadcastGroupMessagePayload(_ payload: Data) { broadcastPayloads.append(payload) }

    // Conversation intents
    private(set) var removedPrivateChats: [PeerID] = []
    private(set) var endPrivateChatCount = 0
    private(set) var systemMessages: [String] = []
    private(set) var localPrivateSystemMessages: [(content: String, peerID: PeerID)] = []

    @discardableResult
    func appendPrivateMessage(_ message: BitchatMessage, to peerID: PeerID) -> Bool { true }
    func markPrivateChatUnread(_ peerID: PeerID) {}
    func removePrivateChat(_ peerID: PeerID) { removedPrivateChats.append(peerID) }
    func startPrivateChat(with peerID: PeerID) {}
    func endPrivateChat() { endPrivateChatCount += 1 }
    func addSystemMessage(_ content: String) { systemMessages.append(content) }
    func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID) {
        localPrivateSystemMessages.append((content, peerID))
    }
    func notifyUIChanged() {}
    func notifyPrivateMessage(from senderName: String, message: String, peerID: PeerID) {}
    func addPeerAuthenticatedObserver(_ handler: @escaping (PeerID, String) -> Void) {}

    func clearRecordedEffects() {
        removedPrivateChats.removeAll()
        endPrivateChatCount = 0
        systemMessages.removeAll()
        localPrivateSystemMessages.removeAll()
        broadcastPayloads.removeAll()
    }
}

// MARK: - Fixtures

/// A Noise identity (fingerprint → short peer ID) plus a real Ed25519
/// signing key, so creator signatures verify for real.
private struct TestIdentity {
    let fingerprint: String
    let nickname: String
    private let signingKey = Curve25519.Signing.PrivateKey()

    init(seed: UInt8, nickname: String) {
        fingerprint = Data(repeating: seed, count: 32).hexEncodedString()
        self.nickname = nickname
    }

    var peerID: PeerID { PeerID(str: String(fingerprint.prefix(16))) }

    var member: GroupMember {
        GroupMember(fingerprint: fingerprint, signingKey: signingKey.publicKey.rawRepresentation, nickname: nickname)
    }

    /// A roster entry claiming this identity's fingerprint and nickname but
    /// pinning `forger`'s signing key — how a forged roster impersonates
    /// real members.
    func impersonated(by forger: TestIdentity) -> GroupMember {
        GroupMember(fingerprint: fingerprint, signingKey: forger.member.signingKey, nickname: nickname)
    }

    func sign(_ data: Data) -> Data? { try? signingKey.signature(for: data) }
}

// MARK: - Tests

@MainActor
struct ChatGroupCoordinatorContextTests {
    private let me = TestIdentity(seed: 0x0E, nickname: "me")
    private let creator = TestIdentity(seed: 0xC1, nickname: "creator")
    private let member = TestIdentity(seed: 0xA2, nickname: "member")
    private let attacker = TestIdentity(seed: 0xEE, nickname: "creator")

    private let groupID = Data((0..<16).map { UInt8($0) })
    private let groupKey = Data(repeating: 0x42, count: 32)
    private let joinedEpoch: UInt32 = 3

    /// A creator-signed state payload, encoded for the wire.
    private func statePayload(
        epoch: UInt32,
        members: [GroupMember],
        creatorFingerprint: String,
        key: Data,
        signedBy signer: TestIdentity
    ) throws -> Data {
        let group = BitchatGroup(
            groupID: groupID,
            name: "trail crew",
            epoch: epoch,
            members: members,
            creatorFingerprint: creatorFingerprint
        )
        let payload = try #require(GroupStatePayload.makeSigned(group: group, key: key, sign: signer.sign))
        return try #require(payload.encode())
    }

    /// State from the real creator over their authenticated session.
    private func creatorState(epoch: UInt32, members: [GroupMember], key: Data) throws -> Data {
        try statePayload(epoch: epoch, members: members, creatorFingerprint: creator.fingerprint, key: key, signedBy: creator)
    }

    /// Joins the group through the coordinator (the creator's invite), opens
    /// its chat, and clears the join side effects. Both the creator and the
    /// attacker hold Noise sessions with us.
    private func makeJoinedGroup(as identity: TestIdentity? = nil) throws -> (MockChatGroupContext, ChatGroupCoordinator, BitchatGroup) {
        let context = MockChatGroupContext(identity: identity ?? me)
        let coordinator = ChatGroupCoordinator(context: context)
        context.fingerprintsByPeerID[creator.peerID] = creator.fingerprint
        context.fingerprintsByPeerID[attacker.peerID] = attacker.fingerprint

        let invite = try creatorState(epoch: joinedEpoch, members: [creator.member, member.member, me.member], key: groupKey)
        coordinator.handleGroupInvitePayload(from: creator.peerID, payload: invite)

        let joined = try #require(context.groupStore.group(withID: groupID))
        #expect(joined.creatorFingerprint == creator.fingerprint)
        #expect(context.systemMessages.count == 1) // the join notice
        context.selectedPrivateChatPeer = joined.peerID
        context.clearRecordedEffects()
        return (context, coordinator, joined)
    }

    private func expectUnchanged(_ context: MockChatGroupContext, joined: BitchatGroup) {
        #expect(context.groupStore.group(withID: groupID) == joined)
        #expect(context.groupStore.key(forGroupID: groupID) == groupKey)
        #expect(context.removedPrivateChats.isEmpty)
        #expect(context.endPrivateChatCount == 0)
        #expect(context.systemMessages.isEmpty)
    }

    // MARK: Takeover

    @Test
    func nonCreatorNamingItselfCreatorAtHigherEpochIsRejected() throws {
        let (context, coordinator, joined) = try makeJoinedGroup()

        // Self-named creator, self-signed, at the highest epoch, with every
        // real member re-pinned to the attacker's key. Passes the sender and
        // signature checks; only the stored-creator pin stops it.
        let hijack = try statePayload(
            epoch: .max,
            members: [attacker.member, me.member, creator.impersonated(by: attacker), member.impersonated(by: attacker)],
            creatorFingerprint: attacker.fingerprint,
            key: Data(repeating: 0xAB, count: 32),
            signedBy: attacker
        )
        coordinator.handleGroupKeyUpdatePayload(from: attacker.peerID, payload: hijack)
        expectUnchanged(context, joined: joined)
        coordinator.handleGroupInvitePayload(from: attacker.peerID, payload: hijack)
        expectUnchanged(context, joined: joined)

        // The attacker's epoch did not lock the real creator out.
        let rotatedKey = Data(repeating: 0x5A, count: 32)
        let rotation = try creatorState(epoch: joinedEpoch + 1, members: [creator.member, member.member, me.member], key: rotatedKey)
        coordinator.handleGroupKeyUpdatePayload(from: creator.peerID, payload: rotation)
        #expect(context.groupStore.group(withID: groupID)?.epoch == joinedEpoch + 1)
        #expect(context.groupStore.key(forGroupID: groupID) == rotatedKey)
    }

    @Test
    func stateNamingTheStoredCreatorWithAnotherSigningKeyIsRejected() throws {
        let (context, coordinator, joined) = try makeJoinedGroup()
        // Even a session that resolves to the stored creator's fingerprint
        // cannot re-pin the creator's signing key.
        let impostorPeerID = PeerID(str: "00112233aabbccdd")
        context.fingerprintsByPeerID[impostorPeerID] = creator.fingerprint

        let repin = try statePayload(
            epoch: joinedEpoch + 1,
            members: [creator.impersonated(by: attacker), member.member, me.member],
            creatorFingerprint: creator.fingerprint,
            key: Data(repeating: 0xAB, count: 32),
            signedBy: attacker
        )
        coordinator.handleGroupKeyUpdatePayload(from: impostorPeerID, payload: repin)

        expectUnchanged(context, joined: joined)
    }

    // MARK: Deletion

    @Test
    func nonCreatorRosterOmittingUsDoesNotDeleteTheGroup() throws {
        let (context, coordinator, joined) = try makeJoinedGroup()

        let eviction = try statePayload(
            epoch: joinedEpoch + 1,
            members: [attacker.member, creator.impersonated(by: attacker)],
            creatorFingerprint: attacker.fingerprint,
            key: Data(repeating: 0xAB, count: 32),
            signedBy: attacker
        )
        coordinator.handleGroupKeyUpdatePayload(from: attacker.peerID, payload: eviction)

        expectUnchanged(context, joined: joined)
    }

    // MARK: Legitimate creator

    @Test
    func creatorRotationIsAccepted() throws {
        let (context, coordinator, joined) = try makeJoinedGroup()

        let rotatedKey = Data(repeating: 0x5A, count: 32)
        let rotation = try creatorState(epoch: joinedEpoch + 1, members: [creator.member, me.member], key: rotatedKey)
        coordinator.handleGroupKeyUpdatePayload(from: creator.peerID, payload: rotation)

        let stored = try #require(context.groupStore.group(withID: groupID))
        #expect(stored.epoch == joinedEpoch + 1)
        #expect(stored.members == [creator.member, me.member])
        #expect(stored.creator == joined.creator)
        #expect(context.groupStore.key(forGroupID: groupID) == rotatedKey)
        #expect(context.removedPrivateChats.isEmpty)
        #expect(context.systemMessages.isEmpty) // not a new membership
    }

    @Test
    func creatorRemovalStillRemovesTheGroup() throws {
        let (context, coordinator, joined) = try makeJoinedGroup()

        // What `notifyRemovedMember` sends: the rotated roster without us,
        // under a throwaway all-zero key.
        let removal = try creatorState(
            epoch: joinedEpoch + 1,
            members: [creator.member, member.member],
            key: Data(count: BitchatGroup.keyLength)
        )
        coordinator.handleGroupKeyUpdatePayload(from: creator.peerID, payload: removal)

        #expect(context.groupStore.group(withID: groupID) == nil)
        #expect(context.groupStore.key(forGroupID: groupID) == nil)
        #expect(context.removedPrivateChats == [joined.peerID])
        #expect(context.endPrivateChatCount == 1)
        #expect(context.systemMessages.count == 1) // "removed from group"
    }

    @Test
    func staleCreatorStateIsRejectedIncludingStaleRemoval() throws {
        let (context, coordinator, joined) = try makeJoinedGroup()

        let staleRotation = try creatorState(
            epoch: joinedEpoch - 1,
            members: [creator.member, me.member],
            key: Data(repeating: 0x5A, count: 32)
        )
        coordinator.handleGroupKeyUpdatePayload(from: creator.peerID, payload: staleRotation)
        expectUnchanged(context, joined: joined)

        // An older removal (e.g. delivered after a re-invite) must not undo
        // the newer membership.
        let staleRemoval = try creatorState(
            epoch: joinedEpoch - 1,
            members: [creator.member, member.member],
            key: Data(count: BitchatGroup.keyLength)
        )
        coordinator.handleGroupKeyUpdatePayload(from: creator.peerID, payload: staleRemoval)
        expectUnchanged(context, joined: joined)
    }

    // MARK: Shared list

    private var nowMs: UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    private func listItemID(_ seed: UInt8) -> Data {
        Data(repeating: seed, count: GroupList.itemIDLength)
    }

    private func addition(_ text: String, seed: UInt8, by author: TestIdentity, atMs timestampMs: UInt64) -> GroupListDelta {
        [listItemID(seed): GroupListItemState(added: .init(stamp: GroupListStamp(timestampMs: timestampMs, author: author.member.signingKey), text: text))]
    }

    /// A list update sealed by `sender` under the joined group's key.
    private func listUpdatePayload(_ delta: GroupListDelta, from sender: TestIdentity, epoch: UInt32? = nil, isSnapshot: Bool = false) throws -> Data {
        try GroupCrypto.sealListUpdate(
            try #require(GroupListCoding.encode(delta, isSnapshot: isSnapshot)),
            messageID: UUID().uuidString,
            senderNickname: sender.nickname,
            senderSigningKey: sender.member.signingKey,
            timestampMs: nowMs,
            groupID: groupID,
            epoch: epoch ?? joinedEpoch,
            key: groupKey,
            sign: sender.sign
        )
    }

    @Test
    func memberListEditMergesAndPostsOneLine() throws {
        let (context, coordinator, joined) = try makeJoinedGroup()
        let payload = try listUpdatePayload(addition("water", seed: 1, by: member, atMs: nowMs), from: member)

        coordinator.handleGroupMessagePayload(payload, timestamp: Date())
        #expect(context.groupStore.lists.list(forGroupID: groupID).items.map(\.text) == ["water"])
        #expect(context.localPrivateSystemMessages.count == 1)
        #expect(context.localPrivateSystemMessages.first?.peerID == joined.peerID)

        // A gossip replay of the same edit changes nothing and stays quiet.
        coordinator.handleGroupMessagePayload(payload, timestamp: Date())
        #expect(context.localPrivateSystemMessages.count == 1)
    }

    @Test
    func listEditFromOutsideTheRosterIsDropped() throws {
        let (context, coordinator, _) = try makeJoinedGroup()
        // The attacker holds the group key but is not pinned in the roster.
        let payload = try listUpdatePayload(addition("bogus", seed: 1, by: attacker, atMs: nowMs), from: attacker)

        coordinator.handleGroupMessagePayload(payload, timestamp: Date())
        #expect(context.groupStore.lists.list(forGroupID: groupID).records.isEmpty)
        #expect(context.localPrivateSystemMessages.isEmpty)
    }

    @Test
    func listEditFromAnOldEpochIsDropped() throws {
        let (context, coordinator, _) = try makeJoinedGroup()
        let payload = try listUpdatePayload(addition("stale", seed: 1, by: member, atMs: nowMs), from: member, epoch: joinedEpoch - 1)

        coordinator.handleGroupMessagePayload(payload, timestamp: Date())
        #expect(context.groupStore.lists.list(forGroupID: groupID).records.isEmpty)
    }

    @Test
    func snapshotsMergeWithoutChatLines() throws {
        let (context, coordinator, _) = try makeJoinedGroup()
        var snapshot = addition("water", seed: 1, by: creator, atMs: nowMs)
        snapshot.merge(addition("maps", seed: 2, by: member, atMs: nowMs + 1)) { lhs, _ in lhs }

        coordinator.handleGroupMessagePayload(try listUpdatePayload(snapshot, from: creator), timestamp: Date())
        #expect(context.groupStore.lists.list(forGroupID: groupID).items.map(\.text) == ["water", "maps"])
        #expect(context.localPrivateSystemMessages.isEmpty)
    }

    @Test
    func aOneRowSnapshotStaysQuiet() throws {
        let (context, coordinator, _) = try makeJoinedGroup()
        let snapshot = addition("water", seed: 1, by: creator, atMs: nowMs)

        coordinator.handleGroupMessagePayload(try listUpdatePayload(snapshot, from: creator, isSnapshot: true), timestamp: Date())
        #expect(context.groupStore.lists.list(forGroupID: groupID).items.map(\.text) == ["water"])
        #expect(context.localPrivateSystemMessages.isEmpty)
    }

    @Test
    func farFutureListEditsDoNotLand() throws {
        let (context, coordinator, _) = try makeJoinedGroup()
        let dayAhead = nowMs + 24 * 60 * 60 * 1000
        let payload = try listUpdatePayload(addition("later", seed: 1, by: member, atMs: dayAhead), from: member)

        coordinator.handleGroupMessagePayload(payload, timestamp: Date())
        #expect(context.groupStore.lists.list(forGroupID: groupID).items.isEmpty)
    }

    @Test
    func broadcastListEditOpensForOtherMembers() throws {
        let (context, coordinator, _) = try makeJoinedGroup()
        let delta = addition("water", seed: 1, by: me, atMs: nowMs)

        #expect(coordinator.broadcastListDelta(delta, groupID: groupID))
        let sent = try #require(context.broadcastPayloads.last)
        let envelope = try #require(GroupMessageEnvelope.decode(sent))
        let plaintext = try GroupCrypto.openMessage(envelope, key: groupKey)
        #expect(plaintext.senderSigningKey == me.member.signingKey)
        let update = try #require(plaintext.listUpdate)
        #expect(GroupListCoding.decode(update, notAfterMs: .max) == GroupListUpdate(delta: delta, isSnapshot: false))
    }

    private func successMessage(_ result: CommandResult) -> String? {
        if case .success(let message) = result { return message }
        return nil
    }

    @Test
    func listCommandsEditTheOpenGroupAndBroadcast() throws {
        let (context, coordinator, _) = try makeJoinedGroup()

        let added = successMessage(coordinator.addChecklistItem("bear spray"))
        #expect(added?.hasSuffix("1. [ ] bear spray") == true)
        #expect(context.broadcastPayloads.count == 1)

        let checked = successMessage(coordinator.setChecklistItem(checked: true, itemNumber: 1))
        #expect(checked?.hasSuffix("1. [x] bear spray") == true)
        #expect(context.broadcastPayloads.count == 2)

        // Already checked: nothing to send, the list is just shown again.
        _ = coordinator.setChecklistItem(checked: true, itemNumber: 1)
        #expect(context.broadcastPayloads.count == 2)

        _ = coordinator.removeChecklistItem(itemNumber: 1)
        #expect(context.broadcastPayloads.count == 3)
        #expect(context.groupStore.lists.list(forGroupID: groupID).items.isEmpty)
        // Our own edits never post activity lines.
        #expect(context.localPrivateSystemMessages.isEmpty)
    }

    @Test
    func listCommandsNeedAnOpenGroupAndARealRow() throws {
        let (context, coordinator, _) = try makeJoinedGroup()

        guard case .error = coordinator.removeChecklistItem(itemNumber: 3) else {
            Issue.record("Expected an error for a missing row")
            return
        }
        context.selectedPrivateChatPeer = nil
        guard case .error = coordinator.addChecklistItem("water") else {
            Issue.record("Expected an error outside a group chat")
            return
        }
        guard case .error = coordinator.showChecklist() else {
            Issue.record("Expected an error outside a group chat")
            return
        }
        #expect(context.broadcastPayloads.isEmpty)
    }

    @Test
    func membersWhoEditApartConvergeOnceTheirEditsMeet() throws {
        let (alice, aliceCoordinator, _) = try makeJoinedGroup()
        let (bob, bobCoordinator, _) = try makeJoinedGroup(as: member)

        // Together: alice starts the list and bob receives it.
        _ = aliceCoordinator.addChecklistItem("water")
        _ = aliceCoordinator.addChecklistItem("maps")
        alice.broadcastPayloads.forEach { bobCoordinator.handleGroupMessagePayload($0, timestamp: Date()) }
        alice.clearRecordedEffects()
        bob.clearRecordedEffects()
        #expect(bob.groupStore.lists.list(forGroupID: groupID) == alice.groupStore.lists.list(forGroupID: groupID))

        // Apart: both edit the same rows with no link between them.
        _ = aliceCoordinator.setChecklistItem(checked: true, itemNumber: 1)
        _ = aliceCoordinator.removeChecklistItem(itemNumber: 2)
        _ = aliceCoordinator.addChecklistItem("stove")
        _ = bobCoordinator.setChecklistItem(checked: true, itemNumber: 2)
        _ = bobCoordinator.removeChecklistItem(itemNumber: 1)
        _ = bobCoordinator.addChecklistItem("bear spray")
        #expect(alice.groupStore.lists.list(forGroupID: groupID) != bob.groupStore.lists.list(forGroupID: groupID))

        // Back in range: gossip delivers each side's edits, in reverse order.
        alice.broadcastPayloads.reversed().forEach { bobCoordinator.handleGroupMessagePayload($0, timestamp: Date()) }
        bob.broadcastPayloads.reversed().forEach { aliceCoordinator.handleGroupMessagePayload($0, timestamp: Date()) }

        let aliceList = alice.groupStore.lists.list(forGroupID: groupID)
        let bobList = bob.groupStore.lists.list(forGroupID: groupID)
        #expect(aliceList == bobList)
        // Each removal sticks, even against the other side's check.
        #expect(Set(aliceList.items.map(\.text)) == ["stove", "bear spray"])
    }

    @Test
    func aSnapshotCatchesUpAMemberWhoMissedEveryEdit() throws {
        let (alice, aliceCoordinator, _) = try makeJoinedGroup()
        let (bob, bobCoordinator, _) = try makeJoinedGroup(as: member)

        _ = aliceCoordinator.addChecklistItem("water")
        _ = aliceCoordinator.addChecklistItem("maps")
        _ = aliceCoordinator.setChecklistItem(checked: true, itemNumber: 1)
        _ = aliceCoordinator.removeChecklistItem(itemNumber: 2)
        alice.clearRecordedEffects()

        aliceCoordinator.broadcastListSnapshot(forGroupID: groupID)
        let snapshot = try #require(alice.broadcastPayloads.first)
        bobCoordinator.handleGroupMessagePayload(snapshot, timestamp: Date())

        #expect(bob.groupStore.lists.list(forGroupID: groupID).items == alice.groupStore.lists.list(forGroupID: groupID).items)
        #expect(bob.localPrivateSystemMessages.isEmpty)
    }

    @Test
    func emptyListsSendNoSnapshot() throws {
        let (context, coordinator, _) = try makeJoinedGroup()
        coordinator.broadcastListSnapshot(forGroupID: groupID)
        #expect(context.broadcastPayloads.isEmpty)

        context.groupStore.lists.merge(addition("water", seed: 1, by: member, atMs: nowMs), intoGroupID: groupID)
        coordinator.broadcastListSnapshot(forGroupID: groupID)
        #expect(context.broadcastPayloads.count == 1)
    }

    @Test
    func aMemberComingBackGetsTheListResentAtMostEveryTenMinutes() throws {
        let (context, coordinator, _) = try makeJoinedGroup()
        let start = Date()

        coordinator.memberSessionEstablished(fingerprint: member.fingerprint, now: start)
        #expect(context.broadcastPayloads.isEmpty) // nothing on the list yet

        context.groupStore.lists.merge(addition("water", seed: 1, by: member, atMs: nowMs), intoGroupID: groupID)
        coordinator.memberSessionEstablished(fingerprint: attacker.fingerprint, now: start)
        coordinator.memberSessionEstablished(fingerprint: me.fingerprint, now: start)
        #expect(context.broadcastPayloads.isEmpty) // not a fellow member

        coordinator.memberSessionEstablished(fingerprint: member.fingerprint, now: start)
        #expect(context.broadcastPayloads.count == 1)
        coordinator.memberSessionEstablished(fingerprint: creator.fingerprint, now: start.addingTimeInterval(60))
        #expect(context.broadcastPayloads.count == 1)
        coordinator.memberSessionEstablished(
            fingerprint: creator.fingerprint,
            now: start.addingTimeInterval(ChatGroupCoordinator.listResendInterval + 1)
        )
        #expect(context.broadcastPayloads.count == 2)

        let sent = try #require(context.broadcastPayloads.last)
        let envelope = try #require(GroupMessageEnvelope.decode(sent))
        let update = try #require(try GroupCrypto.openMessage(envelope, key: groupKey).listUpdate)
        #expect(GroupListCoding.decode(update, notAfterMs: .max)?.isSnapshot == true)
    }

    @Test
    func rowNumbersMeanTheListAsLastShown() throws {
        let (context, coordinator, _) = try makeJoinedGroup()
        let start = nowMs
        let list = context.groupStore.lists
        list.merge(addition("water", seed: 1, by: member, atMs: start), intoGroupID: groupID)
        list.merge(addition("maps", seed: 2, by: member, atMs: start + 1), intoGroupID: groupID)
        list.merge(addition("stove", seed: 3, by: member, atMs: start + 2), intoGroupID: groupID)
        _ = coordinator.showChecklist()

        // Someone else drops "water" before we act on what we saw.
        let removal: GroupListDelta = [listItemID(1): GroupListItemState(removed: GroupListStamp(timestampMs: start + 10, author: member.member.signingKey))]
        coordinator.handleGroupMessagePayload(try listUpdatePayload(removal, from: member), timestamp: Date())

        _ = coordinator.setChecklistItem(checked: true, itemNumber: 2)
        #expect(list.list(forGroupID: groupID).items.first { $0.text == "maps" }?.isChecked == true)
        #expect(list.list(forGroupID: groupID).items.first { $0.text == "stove" }?.isChecked == false)

        // The reply re-showed the list, so numbers follow it from here on.
        _ = coordinator.removeChecklistItem(itemNumber: 2)
        #expect(list.list(forGroupID: groupID).items.map(\.text) == ["maps"])
    }

    @Test
    func aRowRemovedSinceItWasShownIsNotSwappedForAnother() throws {
        let (context, coordinator, _) = try makeJoinedGroup()
        let start = nowMs
        let list = context.groupStore.lists
        list.merge(addition("water", seed: 1, by: member, atMs: start), intoGroupID: groupID)
        list.merge(addition("maps", seed: 2, by: member, atMs: start + 1), intoGroupID: groupID)
        _ = coordinator.showChecklist()

        let removal: GroupListDelta = [listItemID(1): GroupListItemState(removed: GroupListStamp(timestampMs: start + 10, author: member.member.signingKey))]
        coordinator.handleGroupMessagePayload(try listUpdatePayload(removal, from: member), timestamp: Date())
        context.clearRecordedEffects()

        guard case .error = coordinator.setChecklistItem(checked: true, itemNumber: 1) else {
            Issue.record("Expected an error for a row removed since it was shown")
            return
        }
        #expect(list.list(forGroupID: groupID).items.allSatisfy { !$0.isChecked })
        #expect(context.broadcastPayloads.isEmpty)
    }
}
