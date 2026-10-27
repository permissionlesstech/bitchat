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
    func sendVoiceNote(at url: URL) {
        mediaTransferCoordinator.sendVoiceNote(at: url)
    }

    /// Where a live burst would stream right now, or nil when the hold would
    /// fall back to a classic voice note.
    private enum LiveVoiceTarget {
        case peer(PeerID)
        case publicMesh
    }

    @MainActor
    private func liveVoiceTarget() -> LiveVoiceTarget? {
        guard PTTSettings.liveVoiceEnabled else { return nil }

        if let selectedPeer = selectedPrivateChatPeer {
            guard !selectedPeer.isGeoDM, !selectedPeer.isGeoChat, !selectedPeer.isGroup else { return nil }
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
    /// is mesh-reachable with an established Noise session, or the public
    /// mesh channel — otherwise the classic record-then-send voice note.
    /// Either way the release delivers a normal voice note through
    /// `sendVoiceNote(at:)`, which live receivers absorb into the live bubble.
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
        case .publicMesh:
            return PTTLiveVoiceSession(sendPacket: { packet in
                voiceTransport?.sendVoiceFrameBroadcast(packet)
            })
        case nil:
            SecureLogger.info("PTT: hold uses classic voice note (liveVoiceEnabled=\(PTTSettings.liveVoiceEnabled), dmSelected=\(selectedPrivateChatPeer != nil))", category: .session)
            return VoiceNoteCaptureSession()
        }
    }

    // MARK: Live video

    /// Whether the current conversation can watch a live stream now: the
    /// public mesh channel, or a DM peer that is mesh-reachable with an
    /// established Noise session. Clips only need a mesh conversation.
    @MainActor
    var canGoLiveWithVideo: Bool {
        liveVideoTarget() != nil
    }

    /// Where a live video stream goes right now, or nil when no live
    /// audience is reachable (the composer then offers clips only).
    @MainActor
    func makeLiveVideoTarget() -> LiveVideoTarget? {
        guard let videoTransport = meshService as? MeshVideoStreaming else { return nil }
        switch liveVideoTarget() {
        case .peer(let peerID):
            return LiveVideoTarget(
                send: { [weak videoTransport] packet in videoTransport?.sendVideoFrame(packet, to: peerID) },
                backlog: { [weak videoTransport] in videoTransport?.liveSendBacklog() ?? 0 },
                packetBudgetPerSecond: videoTransport.liveSendPacketBudget(to: peerID),
                linkBoost: { [weak videoTransport] active in videoTransport?.setLiveMediaLinkBoost(active) }
            )
        case .publicMesh:
            return LiveVideoTarget(
                send: { [weak videoTransport] packet in videoTransport?.sendVideoFrameBroadcast(packet) },
                backlog: { [weak videoTransport] in videoTransport?.liveSendBacklog() ?? 0 },
                packetBudgetPerSecond: videoTransport.liveSendPacketBudget(to: nil),
                linkBoost: { [weak videoTransport] active in videoTransport?.setLiveMediaLinkBoost(active) }
            )
        case nil:
            return nil
        }
    }

    @MainActor
    private func liveVideoTarget() -> LiveVoiceTarget? {
        if let selectedPeer = selectedPrivateChatPeer {
            guard !selectedPeer.isGeoDM, !selectedPeer.isGeoChat, !selectedPeer.isGroup else { return nil }
            let peerID = selectedPeer.toShort()
            guard meshService.isPeerReachable(peerID),
                  case .established = meshService.getNoiseSessionState(for: peerID)
            else { return nil }
            return .peer(peerID)
        }
        return activeChannel == .mesh ? .publicMesh : nil
    }

    /// Directory for videos this device sends (live recordings and clips).
    func outgoingVideoDirectory() throws -> URL {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("files/\(MimeType.Category.video.mediaDir)/outgoing", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: BLEIncomingFileStore.mediaProtectionAttributes
        )
        return directory
    }

    /// Delivers a finished recording: as an ordinary `video/mp4` transfer
    /// when it fits one mesh file transfer (live viewers swap it into their
    /// bubble), otherwise only as the sender's own local copy (viewers keep
    /// their reconstruction).
    @MainActor
    func finishOutgoingVideo(at url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? Int.max
        if size <= LiveVideoLimits.maxVideoFileBytes {
            sendVideo(at: url)
        } else {
            addLocalVideoMessage(at: url)
        }
    }

    /// Inbound handler for `NoisePayloadType.voiceFrame`.
    @MainActor
    func handleVoiceFramePayload(from peerID: PeerID, payload: Data, timestamp: Date) {
        liveVoiceCoordinator.handleVoiceFramePayload(from: peerID, payload: payload, timestamp: timestamp)
    }

    /// Inbound handler for `NoisePayloadType.videoFrame`.
    @MainActor
    func handleVideoFramePayload(from peerID: PeerID, payload: Data, timestamp: Date) {
        liveVideoCoordinator.handleVideoFramePayload(from: peerID, payload: payload, timestamp: timestamp)
    }

    @MainActor
    func sendVideo(at url: URL) {
        mediaTransferCoordinator.sendVideo(at: url)
    }

    @MainActor
    func addLocalVideoMessage(at url: URL) {
        mediaTransferCoordinator.addLocalVideoMessage(at: url)
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
        if liveVideoCoordinator.absorbFinalizedVideo(message) { return }
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
