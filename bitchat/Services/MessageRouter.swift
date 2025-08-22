import Foundation

/// Routes messages between BLE and Nostr transports
@MainActor
final class MessageRouter {
    private let mesh: Transport
    private let nostr: NostrTransport
    private var outbox: [String: [(content: String, nickname: String, messageID: String)]] = [:] // peerID -> queued messages

    init(mesh: Transport, nostr: NostrTransport) {
        self.mesh = mesh
        self.nostr = nostr
        self.nostr.senderPeerID = mesh.myPeerID

        // Register for Noise session establishment events
        mesh.getNoiseService().addOnPeerAuthenticatedHandler { [weak self] peerID, fingerprint in
            Task { @MainActor in
                self?.didEstablishNoiseSession(with: peerID)
            }
        }

        // Observe favorites changes to learn Nostr mapping and flush queued messages
        NotificationCenter.default.addObserver(
            forName: .favoriteStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            if let data = note.userInfo?["peerPublicKey"] as? Data {
                let peerID = PeerIDUtils.derivePeerID(fromPublicKey: data)
                Task { @MainActor in
                    self.flushOutbox(for: peerID)
                }
            }
            // Handle key updates
            if let newKey = note.userInfo?["peerPublicKey"] as? Data,
               let _ = note.userInfo?["isKeyUpdate"] as? Bool {
                let peerID = PeerIDUtils.derivePeerID(fromPublicKey: newKey)
                Task { @MainActor in
                    self.flushOutbox(for: peerID)
                }
            }
        }
    }

    func sendPrivate(_ content: String, to peerID: String, recipientNickname: String, messageID: String) {
        let hasMesh = mesh.isPeerConnected(peerID)
        let hasEstablished = mesh.getNoiseService().hasEstablishedSession(with: peerID)
        if hasMesh && hasEstablished {
            SecureLogger.log("Routing PM via mesh to \(peerID.prefix(8))… id=\(messageID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
            mesh.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
        } else if canSendViaNostr(peerID: peerID) {
            SecureLogger.log("Routing PM via Nostr to \(peerID.prefix(8))… id=\(messageID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
            nostr.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
        } else {
            // Queue for later (when mesh connects or Nostr mapping appears)
            if outbox[peerID] == nil { outbox[peerID] = [] }
            outbox[peerID]?.append((content, recipientNickname, messageID))
            SecureLogger.log("Queued PM for \(peerID.prefix(8))… (no mesh, no Nostr mapping) id=\(messageID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
        }
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: String) {
        // Prefer mesh only if a Noise session is established; else use Nostr to avoid handshakeRequired spam
        if mesh.isPeerConnected(peerID) && mesh.getNoiseService().hasEstablishedSession(with: peerID) {
            SecureLogger.log("Routing READ ack via mesh to \(peerID.prefix(8))… id=\(receipt.originalMessageID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
            mesh.sendReadReceipt(receipt, to: peerID)
        } else {
            SecureLogger.log("Routing READ ack via Nostr to \(peerID.prefix(8))… id=\(receipt.originalMessageID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
            nostr.sendReadReceipt(receipt, to: peerID)
        }
    }

    func sendDeliveryAck(_ messageID: String, to peerID: String) {
        if mesh.isPeerConnected(peerID) && mesh.getNoiseService().hasEstablishedSession(with: peerID) {
            mesh.sendDeliveryAck(for: messageID, to: peerID)
        } else {
            nostr.sendDeliveryAck(for: messageID, to: peerID)
        }
    }

    func sendFavoriteNotification(to peerID: String, isFavorite: Bool) {
        if mesh.isPeerConnected(peerID) {
            mesh.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
        } else {
            nostr.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
        }
    }

    // MARK: - Group Chat Methods
    
    func sendGroupMessage(_ content: String, to groupID: String, mentions: [String] = []) {
        // For group messages, we need to send to all group members
        // This is a simplified implementation - normally we'd get the group member list
        SecureLogger.log("Routing group message to group \(groupID.prefix(8))…",
                        category: SecureLogger.session, level: .debug)
        mesh.sendGroupMessage(content, to: groupID, mentions: mentions)
    }
    
    func sendGroupInvitation(_ invitation: GroupInvitation, to peerID: String) {
        print("🔍 MessageRouter.sendGroupInvitation called")
        print("🔍   To peerID: \(peerID)")
        print("🔍   Group: \(invitation.groupName)")
        print("🔍   Inviter: \(invitation.inviterNickname)")
        
        let isConnected = mesh.isPeerConnected(peerID)
        let hasSession = mesh.getNoiseService().hasEstablishedSession(with: peerID)
        
        print("🔍   Peer connected: \(isConnected)")
        print("🔍   Noise session: \(hasSession)")
        
        if isConnected {
            if hasSession {
                print("🌐 Using fallback: sending invitation as regular private message")
                // Send as embedded private message via mesh instead of Nostr
                sendInvitationAsPrivateMessage(invitation, to: peerID)
            } else {
                print("🔧 Establishing Noise session for group invitation...")
                // Trigger handshake and queue the invitation
                mesh.triggerHandshake(with: peerID)
                
                // Queue the invitation to be sent once session is established
                queueInvitationForSession(invitation, to: peerID)
            }
        } else {
            print("❌ Peer not connected, cannot send group invitation")
            SecureLogger.log("Cannot send group invitation - peer \(peerID.prefix(8)) not connected",
                            category: SecureLogger.session, level: .warning)
        }
    }
    
    func sendGroupInviteResponse(invitationID: String, accepted: Bool, to peerID: String) {
        if mesh.isPeerConnected(peerID) && mesh.getNoiseService().hasEstablishedSession(with: peerID) {
            SecureLogger.log("Routing group invite response via mesh to \(peerID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
            mesh.sendGroupInviteResponse(invitationID: invitationID, accepted: accepted, to: peerID)
        } else {
            SecureLogger.log("Routing group invite response via Nostr to \(peerID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
            nostr.sendGroupInviteResponse(invitationID: invitationID, accepted: accepted, to: peerID)
        }
    }
    
    func sendGroupMemberUpdate(_ update: GroupMemberUpdate, to groupID: String) {
        SecureLogger.log("Routing group member update to group \(groupID.prefix(8))…",
                        category: SecureLogger.session, level: .debug)
        mesh.sendGroupMemberUpdate(update, to: groupID)
    }
    
    func sendGroupInfoUpdate(_ update: GroupInfoUpdate, to groupID: String) {
        SecureLogger.log("Routing group info update to group \(groupID.prefix(8))…",
                        category: SecureLogger.session, level: .debug)
        mesh.sendGroupInfoUpdate(update, to: groupID)
    }

    // MARK: - Private Helper Methods
    
    private var pendingInvitations: [String: GroupInvitation] = [:]
    
    private func queueInvitationForSession(_ invitation: GroupInvitation, to peerID: String) {
        print("⏳ Queueing invitation for peer \(peerID.prefix(8)) - waiting for Noise session")
        pendingInvitations[peerID] = invitation
        
        // Set up a timer to check if session is established
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.checkAndSendQueuedInvitation(for: peerID)
        }
    }
    
    private func checkAndSendQueuedInvitation(for peerID: String) {
        guard let invitation = pendingInvitations[peerID] else { return }
        
        if mesh.isPeerConnected(peerID) && mesh.getNoiseService().hasEstablishedSession(with: peerID) {
            print("✅ Noise session established, sending queued invitation to \(peerID.prefix(8))")
            pendingInvitations.removeValue(forKey: peerID)
            sendInvitationAsPrivateMessage(invitation, to: peerID)
        } else {
            print("⏳ Still waiting for Noise session with \(peerID.prefix(8))")
            // Try again in 1 second
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.checkAndSendQueuedInvitation(for: peerID)
            }
        }
    }
    
    private func sendInvitationAsPrivateMessage(_ invitation: GroupInvitation, to peerID: String) {
        print("📨 Sending group invitation as embedded private message")
        
        do {
            let invitationData = try JSONEncoder().encode(invitation)
            let base64Invitation = invitationData.base64EncodedString()
            let embeddedMessage = "[GROUP_INVITATION]\(base64Invitation)"
            
            print("📨   Encoded \(invitationData.count) bytes → \(base64Invitation.count) chars")
            print("📨   Sending via private message to \(peerID.prefix(8))")
            
            // Send as regular private message via mesh
            mesh.sendPrivateMessage(embeddedMessage, to: peerID, recipientNickname: "Group Invite", messageID: invitation.id)
            
            SecureLogger.log("📨 Sent group invitation as private message to \(peerID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
        } catch {
            print("❌ Failed to encode invitation for private message: \(error)")
            SecureLogger.log("❌ Failed to encode invitation for private message: \(error)",
                            category: SecureLogger.session, level: .error)
        }
    }

    // MARK: - Outbox Management
    private func canSendViaNostr(peerID: String) -> Bool {
        guard let noiseKey = Data(hexString: peerID) else { return false }
        if let fav = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
           fav.peerNostrPublicKey != nil {
            return true
        }
        return false
    }

    func flushOutbox(for peerID: String) {
        guard let queued = outbox[peerID], !queued.isEmpty else { return }
        SecureLogger.log("Flushing outbox for \(peerID.prefix(8))… count=\(queued.count)",
                        category: SecureLogger.session, level: .debug)
        // Prefer mesh if connected; else try Nostr if mapping exists
        for (content, nickname, messageID) in queued {
            if mesh.isPeerConnected(peerID) {
                SecureLogger.log("Outbox -> mesh for \(peerID.prefix(8))… id=\(messageID.prefix(8))…",
                                category: SecureLogger.session, level: .debug)
                mesh.sendPrivateMessage(content, to: peerID, recipientNickname: nickname, messageID: messageID)
            } else if canSendViaNostr(peerID: peerID) {
                SecureLogger.log("Outbox -> Nostr for \(peerID.prefix(8))… id=\(messageID.prefix(8))…",
                                category: SecureLogger.session, level: .debug)
                nostr.sendPrivateMessage(content, to: peerID, recipientNickname: nickname, messageID: messageID)
            } else {
                continue
            }
        }
        // Remove all flushed items (remaining ones, if any, will be re-queued on next call)
        outbox[peerID]?.removeAll()
    }

    func flushAllOutbox() {
        for key in outbox.keys { flushOutbox(for: key) }
    }
    
    // MARK: - Transport Delegate Methods
    
    func didEstablishNoiseSession(with peerID: String) {
        print("🔐 MessageRouter: Noise session established with \(peerID.prefix(8))")
        // Check if we have any pending invitations for this peer
        checkAndSendQueuedInvitation(for: peerID)
    }
}
