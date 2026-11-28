//
// ChatViewModel+PrivateChat.swift
// bitchat
//
// Private chat and media transfer logic for ChatViewModel
//

import BitFoundation
import BitLogger
import Foundation
import SwiftUI

extension ChatViewModel {

    @MainActor
    func sendPrivateMessage(_ content: String, to peerID: PeerID) {
        // Group chats reuse the private-chat surface but broadcast a sealed
        // envelope instead of routing to a single peer.
        if peerID.isGroup {
            groupCoordinator.sendGroupMessage(content, to: peerID)
            return
        }
        privateConversationCoordinator.sendPrivateMessage(content, to: peerID)
    }

    @MainActor
    func sendGeohashDM(_ content: String, to peerID: PeerID) {
        privateConversationCoordinator.sendGeohashDM(content, to: peerID)
    }

    @MainActor
    func handlePrivateMessage(
        _ payload: NoisePayload,
        senderPubkey: String,
        convKey: PeerID,
        id: NostrIdentity,
        messageTimestamp: Date
    ) {
        privateConversationCoordinator.handlePrivateMessage(
            payload,
            senderPubkey: senderPubkey,
            convKey: convKey,
            id: id,
            messageTimestamp: messageTimestamp
        )
    }

    @MainActor
    func handleDelivered(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        privateConversationCoordinator.handleDelivered(payload, senderPubkey: senderPubkey, convKey: convKey)
    }

    @MainActor
    func handleReadReceipt(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        privateConversationCoordinator.handleReadReceipt(payload, senderPubkey: senderPubkey, convKey: convKey)
    }

    @MainActor
    func sendVoiceNote(at url: URL, target: VoiceNoteTarget? = nil) {
        mediaTransferCoordinator.sendVoiceNote(at: url, target: target)
    }

    /// Describes whether pressing and holding talk right now will stream live
    /// over Bluetooth mesh or fall back to a classic voice note.
    enum LiveVoiceAvailability: Equatable {
        case liveReadyPublic
        case liveReadyDM
        case liveReadyGroup(reachableMemberCount: Int)
        case disabledByUser
        case dmHandshaking
        case dmOutOfRadioRange
        case groupNoReachableMembers
        case unsupported
    }

    /// Resolves mesh-reachable group members (up to `BitchatGroup.maxMembers`)
    /// with established Noise sessions for encrypted group walkie-talkie fan-out.
    @MainActor
    func reachableGroupVoiceMembers(for groupPeerID: PeerID) -> (groupID: Data, peers: [PeerID])? {
        guard let group = groupStore.group(for: groupPeerID) else { return nil }
        let myFingerprint = myNoiseFingerprint()
        var targets: [PeerID] = []
        for member in group.members where member.fingerprint != myFingerprint {
            let shortID = PeerID(str: String(member.fingerprint.prefix(16)))
            guard meshService.isPeerReachable(shortID),
                  case .established = meshService.getNoiseSessionState(for: shortID) else {
                continue
            }
            targets.append(shortID)
            if targets.count >= BitchatGroup.maxMembers {
                break
            }
        }
        return (group.groupID, targets)
    }

    @MainActor
    func currentLiveVoiceAvailability() -> LiveVoiceAvailability {
        if let selectedPeer = selectedPrivateChatPeer {
            if selectedPeer.isGroup {
                guard liveVoiceCoordinator.liveVoiceEnabled() else { return .disabledByUser }
                guard let (_, peers) = reachableGroupVoiceMembers(for: selectedPeer), !peers.isEmpty else {
                    return .groupNoReachableMembers
                }
                return .liveReadyGroup(reachableMemberCount: peers.count)
            }
            guard !selectedPeer.isGeoDM, !selectedPeer.isGeoChat else {
                return .unsupported
            }
            guard liveVoiceCoordinator.liveVoiceEnabled() else { return .disabledByUser }
            let peerID = selectedPeer.toShort()
            guard meshService.isPeerReachable(peerID) else { return .dmOutOfRadioRange }
            guard case .established = meshService.getNoiseSessionState(for: peerID) else {
                return .dmHandshaking
            }
            return .liveReadyDM
        }

        guard activeChannel == .mesh else { return .unsupported }
        return liveVoiceCoordinator.liveVoiceEnabled() ? .liveReadyPublic : .disabledByUser
    }

    /// Where a live burst would stream right now, or nil when the hold would
    /// fall back to a classic voice note.
    private enum LiveVoiceTarget {
        case peer(PeerID)
        case group(groupID: Data, peers: [PeerID])
        case publicMesh
    }

    @MainActor
    private func liveVoiceTarget() -> LiveVoiceTarget? {
        guard liveVoiceCoordinator.liveVoiceEnabled() else { return nil }

        if let selectedPeer = selectedPrivateChatPeer {
            if selectedPeer.isGroup {
                guard let (groupID, peers) = reachableGroupVoiceMembers(for: selectedPeer), !peers.isEmpty else {
                    return nil
                }
                return .group(groupID: groupID, peers: peers)
            }
            guard !selectedPeer.isGeoDM, !selectedPeer.isGeoChat else { return nil }
            // A conversation can be selected under the stable 64-hex Noise key
            // (e.g. after migration on disconnect), but Noise sessions are keyed
            // by the 16-hex routing ID — normalize once and send to that same
            // short ID, like the private-message/file paths do.
            let peerID = selectedPeer.toShort()
            guard meshService.isPeerReachable(peerID),
                  case .established = meshService.getNoiseSessionState(for: peerID)
            else { return nil }
            return .peer(peerID)
        }

        // Public mesh timeline: signed live broadcast. Geohash channels never
        // reach here (the composer hides media affordances there).
        return activeChannel == .mesh ? .publicMesh : nil
    }

    /// Picks the capture backend for the composer's hold-to-record gesture:
    /// live push-to-talk when the audience can hear it now — a DM peer that
    /// is mesh-reachable with an established Noise session, mesh-reachable
    /// members of a small group, or the public mesh channel — otherwise the
    /// classic record-then-send voice note.
    @MainActor
    func makeVoiceCaptureSession() -> VoiceCaptureSession {
        // Live voice rides the mesh only; frames are useful now or never,
        // so a transport without the capability just drops them.
        let voiceTransport = meshService as? MeshVoiceStreaming
        switch liveVoiceTarget() {
        case .peer(let peerID):
            return PTTLiveVoiceSession(sendPacket: { packet in
                voiceTransport?.sendVoiceFrame(packet, to: peerID)
            })
        case .group(let groupID, let peers):
            return PTTLiveVoiceSession(
                sendPacket: { packet in
                    for peerID in peers {
                        voiceTransport?.sendVoiceFrame(packet, to: peerID)
                    }
                },
                groupID: groupID
            )
        case .publicMesh:
            return PTTLiveVoiceSession(sendPacket: { packet in
                voiceTransport?.sendVoiceFrameBroadcast(packet)
            })
        case nil:
            SecureLogger.info("PTT: hold uses classic voice note (liveVoiceEnabled=\(liveVoiceCoordinator.liveVoiceEnabled()), dmSelected=\(selectedPrivateChatPeer != nil))", category: .session)
            return VoiceNoteCaptureSession()
        }
    }

    /// Inbound handler for `NoisePayloadType.voiceFrame`.
    @MainActor
    func handleVoiceFramePayload(from peerID: PeerID, payload: Data, timestamp: Date) {
        liveVoiceCoordinator.handleVoiceFramePayload(from: peerID, payload: payload, timestamp: timestamp)
    }

    #if os(iOS)
    func processThenSendImage(_ image: UIImage?) {
        mediaTransferCoordinator.processThenSendImage(image)
    }
    #elseif os(macOS)
    func processThenSendImage(from url: URL?) {
        mediaTransferCoordinator.processThenSendImage(from: url)
    }
    #endif

    @MainActor
    func sendImage(from sourceURL: URL, cleanup: (() -> Void)? = nil) {
        mediaTransferCoordinator.sendImage(from: sourceURL, cleanup: cleanup)
    }

    @MainActor
    func enqueueMediaMessage(content: String, targetPeer: PeerID?) -> BitchatMessage {
        mediaTransferCoordinator.enqueueMediaMessage(content: content, targetPeer: targetPeer)
    }

    @MainActor
    func registerTransfer(transferId: String, messageID: String) {
        mediaTransferCoordinator.registerTransfer(transferId: transferId, messageID: messageID)
    }

    func makeTransferID(messageID: String) -> String {
        mediaTransferCoordinator.makeTransferID(messageID: messageID)
    }

    @MainActor
    func clearTransferMapping(for messageID: String) {
        mediaTransferCoordinator.clearTransferMapping(for: messageID)
    }

    @MainActor
    func handleTransferEvent(_ event: TransferProgressManager.Event) {
        mediaTransferCoordinator.handleTransferEvent(event)
    }

    func cleanupLocalFile(forMessage message: BitchatMessage) {
        mediaTransferCoordinator.cleanupLocalFile(forMessage: message)
    }

    @MainActor
    func cancelMediaSend(messageID: String) {
        mediaTransferCoordinator.cancelMediaSend(messageID: messageID)
    }

    @MainActor
    func deleteMediaMessage(messageID: String) {
        mediaTransferCoordinator.deleteMediaMessage(messageID: messageID)
    }

    @MainActor
    func handlePrivateMessage(_ message: BitchatMessage) {
        // A finalized voice note whose burst already streamed in live swaps
        // into the existing bubble instead of appearing (and notifying) twice.
        if liveVoiceCoordinator.absorbFinalizedVoiceNote(message) { return }
        privateConversationCoordinator.handlePrivateMessage(message)
    }

    @MainActor
    func processActionMessage(_ message: BitchatMessage) -> BitchatMessage {
        privateConversationCoordinator.processActionMessage(message)
    }

    @MainActor
    func migratePrivateChatsIfNeeded(for peerID: PeerID) {
        privateConversationCoordinator.migratePrivateChatsIfNeeded(for: peerID)
    }

    @MainActor
    func isMessageBlocked(_ message: BitchatMessage) -> Bool {
        privateConversationCoordinator.isMessageBlocked(message)
    }
}
