import BitFoundation
import BitLogger
import Foundation

/// The narrow surface `ChatGroupCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`. Group chats are keyed like direct chats
/// (virtual "group_" peer IDs), so the conversation intents below reuse the
/// private-chat store operations.
@MainActor
protocol ChatGroupContext: AnyObject {
    // MARK: Identity & state
    var nickname: String { get }
    var myPeerID: PeerID { get }
    var selectedPrivateChatPeer: PeerID? { get }
    var groupStore: GroupStore { get }

    /// Fingerprint of our own Noise static identity key.
    func myNoiseFingerprint() -> String
    /// Our Ed25519 signing public key.
    func mySigningPublicKey() -> Data
    /// Signs `data` with our Noise signing key.
    func signWithNoiseKey(_ data: Data) -> Data?

    // MARK: Peers
    func getPeerIDForNickname(_ nickname: String) -> PeerID?
    func isPeerConnected(_ peerID: PeerID) -> Bool
    func peerNickname(for peerID: PeerID) -> String?
    /// The peer's Noise fingerprint from the live session/registry.
    func meshFingerprint(for peerID: PeerID) -> String?
    /// The peer's persisted crypto identity (fingerprint + signing key), if
    /// the identity store has a signature-verified announce for them.
    func cryptoIdentity(for peerID: PeerID) -> (fingerprint: String, signingKey: Data)?
    /// The connected short peer ID whose fingerprint matches, if any.
    func connectedPeerID(forFingerprint fingerprint: String) -> PeerID?
    /// Whether the user has blocked the identity with this Noise fingerprint.
    func isFingerprintBlocked(_ fingerprint: String) -> Bool

    // MARK: Transport
    func sendGroupInvitePayload(_ payload: Data, to peerID: PeerID)
    func sendGroupKeyUpdatePayload(_ payload: Data, to peerID: PeerID)
    func broadcastGroupMessagePayload(_ payload: Data)

    // MARK: Conversation intents (group chats are direct-keyed)
    @discardableResult
    func appendPrivateMessage(_ message: BitchatMessage, to peerID: PeerID) -> Bool
    func markPrivateChatUnread(_ peerID: PeerID)
    func removePrivateChat(_ peerID: PeerID)
    func startPrivateChat(with peerID: PeerID)
    func endPrivateChat()
    func addSystemMessage(_ content: String)
    func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID)
    func notifyUIChanged()
    func notifyPrivateMessage(from senderName: String, message: String, peerID: PeerID)
}

extension ChatViewModel: ChatGroupContext {
    // `nickname`, `myPeerID`, `selectedPrivateChatPeer`, `groupStore`,
    // `getPeerIDForNickname(_:)`, `isPeerConnected(_:)`, `peerNickname(for:)`,
    // `appendPrivateMessage(_:to:)`, `markPrivateChatUnread(_:)`,
    // `removePrivateChat(_:)`, `startPrivateChat(with:)`,
    // `addSystemMessage(_:)`, `addLocalPrivateSystemMessage(_:to:)`,
    // `notifyUIChanged()`, and `notifyPrivateMessage(from:message:peerID:)`
    // are shared requirements with the other contexts or satisfied by
    // existing `ChatViewModel` members. The members below flatten nested
    // service accesses into intent-named calls.

    func myNoiseFingerprint() -> String {
        meshService.noiseIdentityFingerprint()
    }

    func mySigningPublicKey() -> Data {
        meshService.noiseSigningPublicKeyData()
    }

    func signWithNoiseKey(_ data: Data) -> Data? {
        meshService.noiseSignData(data)
    }

    func meshFingerprint(for peerID: PeerID) -> String? {
        meshService.getFingerprint(for: peerID)
    }

    /// The persisted, signature-verified identity behind a short mesh peer
    /// ID. Cross-checked against the live session fingerprint so a roster
    /// entry can never be pinned to a signing key from a different identity.
    func cryptoIdentity(for peerID: PeerID) -> (fingerprint: String, signingKey: Data)? {
        guard let fingerprint = meshService.getFingerprint(for: peerID) else { return nil }
        let candidates = identityManager.getCryptoIdentitiesByPeerIDPrefix(peerID)
        guard let identity = candidates.first(where: { $0.fingerprint == fingerprint }),
              let signingKey = identity.signingPublicKey else { return nil }
        return (fingerprint, signingKey)
    }

    /// Short mesh peer IDs are the fingerprint's first 16 hex chars, so the
    /// connected peer for a roster fingerprint is a direct derivation.
    func connectedPeerID(forFingerprint fingerprint: String) -> PeerID? {
        let shortID = PeerID(str: String(fingerprint.prefix(16)))
        return meshService.isPeerConnected(shortID) ? shortID : nil
    }

    func isFingerprintBlocked(_ fingerprint: String) -> Bool {
        identityManager.isBlocked(fingerprint: fingerprint)
    }

    func sendGroupInvitePayload(_ payload: Data, to peerID: PeerID) {
        meshService.sendGroupInvite(payload, to: peerID)
    }

    func sendGroupKeyUpdatePayload(_ payload: Data, to peerID: PeerID) {
        meshService.sendGroupKeyUpdate(payload, to: peerID)
    }

    func broadcastGroupMessagePayload(_ payload: Data) {
        meshService.broadcastGroupMessage(payload)
    }

    // MARK: CommandContextProvider group commands (parsed by CommandProcessor)

    func groupCreate(named name: String) -> CommandResult {
        groupCoordinator.createGroup(named: name)
    }

    func groupInvite(nickname: String) -> CommandResult {
        groupCoordinator.inviteMember(nickname: nickname)
    }

    func groupRemove(nickname: String) -> CommandResult {
        groupCoordinator.removeMember(nickname: nickname)
    }

    func groupLeave() -> CommandResult {
        groupCoordinator.leaveGroup()
    }

    func groupList() -> CommandResult {
        groupCoordinator.listGroups()
    }
}

/// Owns the private-groups feature: creating groups, creator-managed invites
/// and key rotation over Noise, and sealing/opening group message broadcasts.
/// Delivery is fire-and-flood like public chat — no per-member acks in v1 —
/// with gossip-sync backfill as the only offline catch-up.
@MainActor
final class ChatGroupCoordinator {
    private unowned let context: any ChatGroupContext

    private static let maxGroupNameLength = 40

    init(context: any ChatGroupContext) {
        self.context = context
    }

    // MARK: - Commands

    func createGroup(named rawName: String) -> CommandResult {
        let name = rawName.trimmed
        guard !name.isEmpty else {
            return .error(message: String(localized: "system.group.usage_create", comment: "Usage hint for /group create"))
        }
        guard name.count <= Self.maxGroupNameLength else {
            return .error(message: String(localized: "system.group.name_too_long", comment: "Error when a group name exceeds the length cap"))
        }

        let myFingerprint = context.myNoiseFingerprint()
        let mySigningKey = context.mySigningPublicKey()
        guard !myFingerprint.isEmpty, mySigningKey.count == 32 else {
            return .error(message: String(localized: "system.group.identity_unavailable", comment: "Error when the local identity is not ready for group operations"))
        }

        let creator = GroupMember(fingerprint: myFingerprint, signingKey: mySigningKey, nickname: context.nickname)
        guard let group = context.groupStore.createGroup(named: name, creator: creator) else {
            return .error(message: String(localized: "system.group.create_failed", comment: "Error when group creation fails"))
        }

        context.startPrivateChat(with: group.peerID)
        return .success(message: String(
            format: String(localized: "system.group.created", comment: "System message after creating a group; placeholder is the group name"),
            locale: .current,
            name
        ))
    }

    func inviteMember(nickname rawNickname: String) -> CommandResult {
        let nickname = normalizedNickname(rawNickname)
        guard !nickname.isEmpty else {
            return .error(message: String(localized: "system.group.usage_invite", comment: "Usage hint for /group invite"))
        }
        guard let group = selectedGroup() else {
            return .error(message: String(localized: "system.group.not_in_group", comment: "Error when a group command requires an open group chat"))
        }
        guard group.creatorFingerprint == context.myNoiseFingerprint() else {
            return .error(message: String(localized: "system.group.creator_only", comment: "Error when a non-creator attempts a creator-only group action"))
        }
        guard let peerID = context.getPeerIDForNickname(nickname) else {
            return .error(message: String(
                format: String(localized: "system.group.peer_not_found", comment: "Error when the invitee nickname is unknown; placeholder is the nickname"),
                locale: .current,
                nickname
            ))
        }
        guard context.isPeerConnected(peerID) else {
            return .error(message: String(
                format: String(localized: "system.group.peer_not_connected", comment: "Error when the invitee is not connected over mesh; placeholder is the nickname"),
                locale: .current,
                nickname
            ))
        }
        guard let identity = context.cryptoIdentity(for: peerID) else {
            return .error(message: String(
                format: String(localized: "system.group.peer_identity_unknown", comment: "Error when the invitee's verified identity is unavailable; placeholder is the nickname"),
                locale: .current,
                nickname
            ))
        }
        guard !group.isMember(fingerprint: identity.fingerprint) else {
            return .error(message: String(
                format: String(localized: "system.group.already_member", comment: "Error when the invitee is already a member; placeholder is the nickname"),
                locale: .current,
                nickname
            ))
        }
        guard group.members.count < BitchatGroup.maxMembers else {
            return .error(message: String(
                format: String(localized: "system.group.full", comment: "Error when the group is at the member cap; placeholder is the cap"),
                locale: .current,
                "\(BitchatGroup.maxMembers)"
            ))
        }

        let newMember = GroupMember(
            fingerprint: identity.fingerprint,
            signingKey: identity.signingKey,
            nickname: context.peerNickname(for: peerID) ?? nickname
        )
        // Rotate the key (epoch + 1) on every roster change, not just removals.
        // A monotonically increasing epoch per roster gives the receiver a
        // strict ordering: two out-of-order invite states can no longer share
        // an epoch and last-writer-wins a just-added member back out.
        let members = group.members + [newMember]
        guard let (updated, key) = context.groupStore.rotateKey(groupID: group.groupID, members: members),
              let payload = signedStatePayload(for: updated, key: key) else {
            return .error(message: String(localized: "system.group.invite_failed", comment: "Error when building or signing a group invite fails"))
        }

        context.sendGroupInvitePayload(payload, to: peerID)
        distributeState(payload, group: updated, excluding: [identity.fingerprint], type: .keyUpdate)

        return .success(message: String(
            format: String(localized: "system.group.invited", comment: "System message after inviting someone; placeholders are the nickname and the group name"),
            locale: .current,
            nickname,
            updated.name
        ))
    }

    /// Creator-side removal: rotates the group key (epoch + 1) and sends the
    /// new state to every remaining member so the removed member's key stops
    /// decrypting future traffic.
    func removeMember(nickname rawNickname: String) -> CommandResult {
        let nickname = normalizedNickname(rawNickname)
        guard !nickname.isEmpty else {
            return .error(message: String(localized: "system.group.usage_remove", comment: "Usage hint for /group remove"))
        }
        guard let group = selectedGroup() else {
            return .error(message: String(localized: "system.group.not_in_group", comment: "Error when a group command requires an open group chat"))
        }
        guard group.creatorFingerprint == context.myNoiseFingerprint() else {
            return .error(message: String(localized: "system.group.creator_only", comment: "Error when a non-creator attempts a creator-only group action"))
        }
        guard let member = group.members.first(where: { $0.nickname.caseInsensitiveCompare(nickname) == .orderedSame }) else {
            return .error(message: String(
                format: String(localized: "system.group.member_not_found", comment: "Error when the member to remove is not in the roster; placeholder is the nickname"),
                locale: .current,
                nickname
            ))
        }
        guard member.fingerprint != group.creatorFingerprint else {
            return .error(message: String(localized: "system.group.cannot_remove_creator", comment: "Error when the creator tries to remove themselves"))
        }

        let remaining = group.members.filter { $0.fingerprint != member.fingerprint }
        guard let (rotated, newKey) = context.groupStore.rotateKey(groupID: group.groupID, members: remaining),
              let payload = signedStatePayload(for: rotated, key: newKey) else {
            return .error(message: String(localized: "system.group.rotate_failed", comment: "Error when rotating the group key fails"))
        }

        distributeState(payload, group: rotated, excluding: [], type: .keyUpdate)
        notifyRemovedMember(member, rotated: rotated)

        return .success(message: String(
            format: String(localized: "system.group.removed_member", comment: "System message after removing a member and rotating the key; placeholder is the nickname"),
            locale: .current,
            member.nickname
        ))
    }

    func leaveGroup() -> CommandResult {
        guard let group = selectedGroup() else {
            return .error(message: String(localized: "system.group.not_in_group", comment: "Error when a group command requires an open group chat"))
        }
        // Close the chat window first so the confirmation message doesn't
        // resurrect the conversation we're about to remove.
        context.endPrivateChat()
        context.removePrivateChat(group.peerID)
        context.groupStore.removeGroup(withID: group.groupID)
        context.notifyUIChanged()
        return .success(message: String(
            format: String(localized: "system.group.left", comment: "System message after leaving a group; placeholder is the group name"),
            locale: .current,
            group.name
        ))
    }

    func listGroups() -> CommandResult {
        let groups = context.groupStore.groups
        guard !groups.isEmpty else {
            return .success(message: String(localized: "system.group.none", comment: "System message when the user is in no groups"))
        }
        let myFingerprint = context.myNoiseFingerprint()
        let lines = groups.map { group -> String in
            let role = group.creatorFingerprint == myFingerprint ? " (creator)" : ""
            return "#\(group.name)\(role) — \(group.members.count)/\(BitchatGroup.maxMembers)"
        }
        return .success(message: String(localized: "system.group.list_header", comment: "Header line for the /group list output") + "\n" + lines.joined(separator: "\n"))
    }

    // MARK: - Sending

    /// Fire-and-flood send: local echo goes straight to `.sent` because group
    /// messages have no per-member acknowledgments in v1.
    func sendGroupMessage(_ content: String, to groupPeerID: PeerID) {
        guard !content.isEmpty, content.count <= InputValidator.Limits.maxMessageLength else { return }
        guard let group = context.groupStore.group(for: groupPeerID),
              let key = context.groupStore.key(forGroupID: group.groupID) else {
            // The person is inside the group thread; the error belongs there,
            // not on the active public timeline.
            context.addLocalPrivateSystemMessage(
                String(localized: "system.group.unknown", comment: "System message when sending into an unknown group"),
                to: groupPeerID
            )
            return
        }

        let messageID = UUID().uuidString
        let timestamp = Date()
        let payload: Data
        do {
            payload = try GroupCrypto.sealMessage(
                content: content,
                messageID: messageID,
                senderNickname: context.nickname,
                senderSigningKey: context.mySigningPublicKey(),
                timestampMs: UInt64(timestamp.timeIntervalSince1970 * 1000),
                groupID: group.groupID,
                epoch: group.epoch,
                key: key,
                sign: { [weak context] data in context?.signWithNoiseKey(data) }
            )
        } catch {
            SecureLogger.error("Failed to seal group message: \(error)", category: .encryption)
            context.addLocalPrivateSystemMessage(
                String(localized: "system.group.send_failed", comment: "System message when sealing a group message fails"),
                to: groupPeerID
            )
            return
        }

        let message = BitchatMessage(
            id: messageID,
            sender: context.nickname,
            content: content,
            timestamp: timestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: group.name,
            senderPeerID: context.myPeerID,
            mentions: nil,
            deliveryStatus: .sent
        )
        context.appendPrivateMessage(message, to: groupPeerID)
        context.broadcastGroupMessagePayload(payload)
        context.notifyUIChanged()
    }

    // MARK: - Receiving

    /// Decrypt-verify path for an incoming 0x25 broadcast. Drops silently for
    /// unknown groups (non-members relay but never read), wrong epochs, bad
    /// sender signatures, and senders missing from the pinned roster.
    func handleGroupMessagePayload(_ payload: Data, timestamp _: Date) {
        guard let envelope = GroupMessageEnvelope.decode(payload) else { return }
        guard let group = context.groupStore.group(withID: envelope.groupID) else { return }
        guard envelope.epoch == group.epoch else {
            SecureLogger.debug("Dropping group message with epoch \(envelope.epoch) (current \(group.epoch))", category: .encryption)
            return
        }
        guard let key = context.groupStore.key(forGroupID: group.groupID) else { return }

        let plaintext: GroupMessagePlaintext
        do {
            plaintext = try GroupCrypto.openMessage(envelope, key: key)
        } catch {
            SecureLogger.debug("Failed to open group message: \(error)", category: .encryption)
            return
        }

        // Sender must be pinned in the creator-signed roster; key possession
        // alone is not authorship.
        guard let member = group.member(withSigningKey: plaintext.senderSigningKey) else {
            SecureLogger.warning("Dropping group message from non-roster sender", category: .security)
            return
        }
        // Our own broadcast echoed back via relay or sync replay.
        guard plaintext.senderSigningKey != context.mySigningPublicKey() else { return }
        // Honor /block inside groups too: drop display + notification for a
        // blocked member, consistent with every other inbound path.
        guard !context.isFingerprintBlocked(member.fingerprint) else {
            SecureLogger.debug("Dropping group message from blocked member", category: .security)
            return
        }

        let groupPeerID = group.peerID
        // Trust the authenticated inner timestamp (clamped so a future-dated
        // message cannot pin itself to the bottom of the timeline).
        let messageDate = min(Date(timeIntervalSince1970: TimeInterval(plaintext.timestampMs) / 1000), Date())
        let senderName = member.nickname.isEmpty ? plaintext.senderNickname : member.nickname
        let senderPeerID = PeerID(str: String(member.fingerprint.prefix(16)))
        let message = BitchatMessage(
            id: plaintext.messageID,
            sender: senderName,
            content: plaintext.content,
            timestamp: messageDate,
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: group.name,
            senderPeerID: senderPeerID,
            mentions: nil
        )

        guard context.appendPrivateMessage(message, to: groupPeerID) else { return }

        let isViewing = context.selectedPrivateChatPeer == groupPeerID
        if !isViewing {
            context.markPrivateChatUnread(groupPeerID)
            let isRecent = Date().timeIntervalSince(messageDate) < 30
            if isRecent {
                context.notifyPrivateMessage(
                    from: "\(senderName) @ \(group.name)",
                    message: plaintext.content,
                    peerID: groupPeerID
                )
            }
        }
        context.notifyUIChanged()
    }

    /// Accepts creator-signed group state arriving as an invite. The Noise
    /// session peer must BE the creator, the signature must verify against
    /// the creator key pinned in the roster, and we must be in the roster.
    func handleGroupInvitePayload(from peerID: PeerID, payload: Data) {
        applyGroupState(from: peerID, payload: payload, isInvite: true)
    }

    /// Accepts creator-signed state updates (rotation/roster). A state whose
    /// roster no longer includes us means we were removed: drop the group.
    func handleGroupKeyUpdatePayload(from peerID: PeerID, payload: Data) {
        applyGroupState(from: peerID, payload: payload, isInvite: false)
    }
}

private extension ChatGroupCoordinator {
    enum StateSendType {
        case invite
        case keyUpdate
    }

    func normalizedNickname(_ raw: String) -> String {
        let trimmed = raw.trimmed
        return trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    }

    func selectedGroup() -> BitchatGroup? {
        guard let selected = context.selectedPrivateChatPeer, selected.isGroup else { return nil }
        return context.groupStore.group(for: selected)
    }

    func signedStatePayload(for group: BitchatGroup, key: Data) -> Data? {
        GroupStatePayload.makeSigned(group: group, key: key) { [weak context] data in
            context?.signWithNoiseKey(data)
        }?.encode()
    }

    /// Sends the state payload to every connected roster member except us and
    /// the excluded fingerprints. Offline members catch up the next time the
    /// creator sends them state (v1 limitation, documented in the PR).
    func distributeState(_ payload: Data, group: BitchatGroup, excluding excludedFingerprints: Set<String>, type: StateSendType) {
        let myFingerprint = context.myNoiseFingerprint()
        for member in group.members {
            guard member.fingerprint != myFingerprint,
                  !excludedFingerprints.contains(member.fingerprint),
                  let peerID = context.connectedPeerID(forFingerprint: member.fingerprint) else { continue }
            switch type {
            case .invite:
                context.sendGroupInvitePayload(payload, to: peerID)
            case .keyUpdate:
                context.sendGroupKeyUpdatePayload(payload, to: peerID)
            }
        }
    }

    /// Tells a just-removed member they're out so their client can deactivate
    /// the group instead of silently going dark (dropping every message under
    /// the epoch it no longer has the key for). The notice is a creator-signed
    /// state whose roster excludes the removee — their `applyGroupState`
    /// removal branch fires on the missing-self roster and surfaces the
    /// "removed from group" system message.
    ///
    /// It carries a throwaway all-zero key, never the rotated key, so the
    /// removee cannot decrypt post-removal traffic. State is sent 1:1 over
    /// authenticated Noise, so no remaining member ever receives this blob
    /// (and even if one did, its own missing-self check would not match).
    /// If the removee is offline the notice can't be delivered — same v1
    /// limitation as any other missed key update, documented in the PR.
    func notifyRemovedMember(_ removed: GroupMember, rotated: BitchatGroup) {
        guard let peerID = context.connectedPeerID(forFingerprint: removed.fingerprint) else { return }
        let throwawayKey = Data(count: BitchatGroup.keyLength)
        guard let payload = signedStatePayload(for: rotated, key: throwawayKey) else { return }
        context.sendGroupKeyUpdatePayload(payload, to: peerID)
    }

    func applyGroupState(from peerID: PeerID, payload: Data, isInvite: Bool) {
        guard let state = GroupStatePayload.decode(payload) else {
            SecureLogger.warning("Malformed group state payload from \(peerID.id.prefix(8))…", category: .security)
            return
        }
        // The Noise session already authenticated `peerID`; require that the
        // authenticated peer IS the creator whose key signed the state, so a
        // member can't re-invite or rotate on the creator's behalf.
        guard let senderFingerprint = context.meshFingerprint(for: peerID),
              senderFingerprint == state.creatorFingerprint else {
            SecureLogger.warning("Dropping group state from non-creator \(peerID.id.prefix(8))…", category: .security)
            return
        }
        guard state.verifyCreatorSignature() else {
            SecureLogger.warning("Dropping group state with invalid creator signature", category: .security)
            return
        }

        let myFingerprint = context.myNoiseFingerprint()
        let existing = context.groupStore.group(withID: state.groupID)

        // A creator-signed roster that no longer includes us is a removal.
        guard state.members.contains(where: { $0.fingerprint == myFingerprint }) else {
            if let existing {
                if context.selectedPrivateChatPeer == existing.peerID {
                    context.endPrivateChat()
                }
                context.removePrivateChat(existing.peerID)
                context.groupStore.removeGroup(withID: existing.groupID)
                context.addSystemMessage(String(
                    format: String(localized: "system.group.removed_from", comment: "System message when removed from a group; placeholder is the group name"),
                    locale: .current,
                    existing.name
                ))
                context.notifyUIChanged()
            }
            return
        }

        // Never regress the epoch: state travels over live Noise sessions,
        // so an older epoch here is a stale (or misbehaving) creator device.
        if let existing, state.epoch < existing.epoch {
            SecureLogger.warning("Dropping stale group state (epoch \(state.epoch) < \(existing.epoch))", category: .security)
            return
        }

        let isNewMembership = existing == nil
        guard context.groupStore.upsert(state.asGroup, key: state.key) else {
            SecureLogger.error("Failed to store group state for \(state.name)", category: .session)
            return
        }

        if isNewMembership {
            let inviter = state.members.first { $0.fingerprint == state.creatorFingerprint }?.nickname
                ?? context.peerNickname(for: peerID)
                ?? "?"
            let notice = String(
                format: String(localized: "system.group.joined", comment: "System message when added to a group; placeholders are the group name and the inviter"),
                locale: .current,
                state.name,
                inviter
            )
            context.addSystemMessage(notice)
            context.markPrivateChatUnread(state.asGroup.peerID)
            context.notifyPrivateMessage(from: inviter, message: notice, peerID: state.asGroup.peerID)
        } else if isInvite == false, let existing, state.epoch > existing.epoch {
            SecureLogger.info("Group '\(state.name)' rotated to epoch \(state.epoch)", category: .session)
        }
        context.notifyUIChanged()
    }
}
