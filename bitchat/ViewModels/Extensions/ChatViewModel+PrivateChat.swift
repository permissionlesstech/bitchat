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

    /// `scope` is the channel the DM lives in. A geohash DM is signed with
    /// that geohash's identity, the one its recipient knows, whatever is
    /// selected by the time it sends.
    @MainActor
    func sendPrivateMessage(_ content: String, to peerID: PeerID, scope: ChannelID) {
        // Group chats reuse the private-chat surface but broadcast a sealed
        // envelope instead of routing to a single peer.
        if peerID.isGroup {
            groupCoordinator.sendGroupMessage(content, to: peerID)
            return
        }
        privateConversationCoordinator.sendPrivateMessage(content, to: peerID, scope: scope)
    }

    @MainActor
    func sendGeohashDM(_ content: String, to peerID: PeerID) {
        privateConversationCoordinator.sendGeohashDM(content, to: peerID, scope: activeChannel)
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

    /// The release's completion for `target`'s composer: the note goes to
    /// that conversation even if the selection moves before the file is
    /// finalized.
    @MainActor
    func makeVoiceNoteSender(for target: ConversationTarget) -> (URL) -> Void {
        mediaTransferCoordinator.makeVoiceNoteSender(for: target)
    }

    /// Where a live burst would stream right now, or nil when the hold would
    /// fall back to a classic voice note.
    enum LiveVoiceTarget: Equatable {
        case peer(PeerID)
        case publicMesh
    }

    /// Where a hold in `target`'s composer streams live. A DM target streams
    /// only to its own peer, and only while that peer can hear it now (mesh
    /// reachable, Noise session established); it never yields the public
    /// broadcast. Only the #mesh timeline broadcasts.
    @MainActor
    func liveVoiceTarget(for target: ConversationTarget) -> LiveVoiceTarget? {
        guard PTTSettings.liveVoiceEnabled else { return nil }

        if let peer = target.privatePeer {
            guard !peer.isGeoDM, !peer.isGeoChat, !peer.isGroup else { return nil }
            // A conversation can be selected under the stable 64-hex Noise key
            // (e.g. after migration on disconnect), but Noise sessions are keyed
            // by the 16-hex routing ID — normalize once and send to that same
            // short ID, like the private-message/file paths do.
            let peerID = peer.toShort()
            guard meshService.isPeerReachable(peerID),
                  case .established = meshService.getNoiseSessionState(for: peerID)
            else { return nil }
            return .peer(peerID)
        }

        // Public mesh timeline: signed live broadcast. Geohash channels never
        // reach here (the composer hides media affordances there).
        return target.channel == .mesh ? .publicMesh : nil
    }

    /// Picks the capture backend for a hold in `target`'s composer: live
    /// push-to-talk when that conversation's audience can hear it now — a DM
    /// peer that is mesh-reachable with an established Noise session, or the
    /// public mesh channel — otherwise the classic record-then-send voice
    /// note. Either way the release delivers a normal voice note through
    /// `makeVoiceNoteSender(for:)`, which live receivers absorb into the
    /// live bubble.
    @MainActor
    func makeVoiceCaptureSession(for target: ConversationTarget) -> VoiceCaptureSession {
        // Live voice rides the mesh only; frames are useful now or never,
        // so a transport without the capability just drops them.
        let voiceTransport = meshService as? MeshVoiceStreaming
        switch liveVoiceTarget(for: target) {
        case .peer(let peerID):
            return PTTLiveVoiceSession(sendPacket: { packet in
                voiceTransport?.sendVoiceFrame(packet, to: peerID)
            })
        case .publicMesh:
            return PTTLiveVoiceSession(sendPacket: { packet in
                voiceTransport?.sendVoiceFrameBroadcast(packet)
            })
        case nil:
            SecureLogger.info("PTT: hold uses classic voice note (liveVoiceEnabled=\(PTTSettings.liveVoiceEnabled), dm=\(target.isPrivate))", category: .session)
            return VoiceNoteCaptureSession()
        }
    }

    /// Inbound handler for `NoisePayloadType.voiceFrame`.
    @MainActor
    func handleVoiceFramePayload(from peerID: PeerID, payload: Data, timestamp: Date) {
        liveVoiceCoordinator.handleVoiceFramePayload(from: peerID, payload: payload, timestamp: timestamp)
    }

    #if os(iOS)
    /// Sends a photo picked in `target`'s composer to that conversation.
    @MainActor
    func processThenSendImage(_ image: UIImage?, to target: ConversationTarget) {
        mediaTransferCoordinator.processThenSendImage(image, to: target)
    }
    #elseif os(macOS)
    /// Sends a photo picked in `target`'s composer to that conversation.
    @MainActor
    func processThenSendImage(from url: URL?, to target: ConversationTarget) {
        mediaTransferCoordinator.processThenSendImage(from: url, to: target)
    }
    #endif

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
    func migratePrivateChatsIfNeeded(for peerID: PeerID, senderNickname: String) {
        privateConversationCoordinator.migratePrivateChatsIfNeeded(for: peerID, senderNickname: senderNickname)
    }

    @MainActor
    func isMessageBlocked(_ message: BitchatMessage) -> Bool {
        privateConversationCoordinator.isMessageBlocked(message)
    }
}
