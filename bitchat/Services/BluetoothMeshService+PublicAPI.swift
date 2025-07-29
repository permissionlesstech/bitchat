import Foundation

// MARK: - Public API Extensions for BluetoothMeshService

extension BluetoothMeshService {
    
    /// Public method to send a packet through the mesh network
    /// TODO: This is a temporary placeholder until we refactor the private broadcastPacket method
    func sendPacket(_ packet: BitchatPacket) {
        // For now, we'll use the existing message sending infrastructure
        // In the future, this should call broadcastPacket directly
        
        // Temporary workaround: Use existing infrastructure
        if packet.type == MessageType.message.rawValue,
           let _ = BitchatMessage.fromBinaryPayload(packet.payload) {
            // Handle as a regular message
            // This is a hack until we expose broadcastPacket publicly
        } else {
            // For other packet types, we need to wait for proper API
            SecureLogger.log("Cannot send non-message packets through public API yet", category: SecureLogger.session, level: .warning)
        }
    }
    
    /// Send a favorite/unfavorite notification to a specific peer
    func sendFavoriteNotification(to peerID: String, isFavorite: Bool) {
        // Create notification payload with Nostr public key
        var content = isFavorite ? "SYSTEM:FAVORITED" : "SYSTEM:UNFAVORITED"
        
        // Add our Nostr public key if we have one
        if let myNostrIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() {
            // Include our Nostr npub in the message
            content += ":" + myNostrIdentity.npub
            SecureLogger.log("📝 Including our Nostr npub in favorite notification: \(myNostrIdentity.npub)", 
                            category: SecureLogger.session, level: .info)
        }
        
        SecureLogger.log("📤 Sending \(isFavorite ? "favorite" : "unfavorite") notification to \(peerID) via mesh", 
                        category: SecureLogger.session, level: .info)
        
        // Use existing message infrastructure
        if let recipientNickname = getPeerNicknames()[peerID] {
            sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname)
            SecureLogger.log("✅ Sent favorite notification as private message", 
                            category: SecureLogger.session, level: .info)
        } else {
            SecureLogger.log("❌ Failed to send favorite notification - peer not found", 
                            category: SecureLogger.session, level: .error)
        }
    }
}

// Note: BitchatMessage.fromBinaryPayload is already defined in BinaryProtocol.swift