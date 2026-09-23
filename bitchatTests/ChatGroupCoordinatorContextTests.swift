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
    func sendGroupInvitePayload(_ payload: Data, to peerID: PeerID) {}
    func sendGroupKeyUpdatePayload(_ payload: Data, to peerID: PeerID) {}
    func broadcastGroupMessagePayload(_ payload: Data) {}

    // Conversation intents
    private(set) var removedPrivateChats: [PeerID] = []
    private(set) var endPrivateChatCount = 0
    private(set) var systemMessages: [String] = []

    @discardableResult
    func appendPrivateMessage(_ message: BitchatMessage, to peerID: PeerID) -> Bool { true }
    func markPrivateChatUnread(_ peerID: PeerID) {}
    func removePrivateChat(_ peerID: PeerID) { removedPrivateChats.append(peerID) }
    func startPrivateChat(with peerID: PeerID) {}
    func endPrivateChat() { endPrivateChatCount += 1 }
    func addSystemMessage(_ content: String) { systemMessages.append(content) }
    func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID) {}
    func notifyUIChanged() {}
    func notifyPrivateMessage(from senderName: String, message: String, peerID: PeerID) {}

    func clearRecordedEffects() {
        removedPrivateChats.removeAll()
        endPrivateChatCount = 0
        systemMessages.removeAll()
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
    private func makeJoinedGroup() throws -> (MockChatGroupContext, ChatGroupCoordinator, BitchatGroup) {
        let context = MockChatGroupContext(identity: me)
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
}
