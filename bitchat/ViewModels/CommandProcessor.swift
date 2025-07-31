import Foundation

/// Handles parsing and executing chat commands.
final class CommandProcessor {
    unowned let viewModel: ChatViewModel

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    @MainActor
    func handle(_ command: String) {
        let parts = command.split(separator: " ")
        guard let cmd = parts.first else { return }

        switch cmd {
        case "/m", "/msg":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName

                // Find peer ID for this nickname
                if let peerID = viewModel.getPeerIDForNickname(nickname) {
                    viewModel.startPrivateChat(with: peerID)

                    // If there's a message after the nickname, send it
                    if parts.count > 2 {
                        let messageContent = parts[2...].joined(separator: " ")
                        viewModel.sendPrivateMessage(messageContent, to: peerID)
                    } else {
                        let systemMessage = BitchatMessage(
                            sender: "system",
                            content: "started private chat with \(nickname)",
                            timestamp: Date(),
                            isRelay: false
                        )
                        viewModel.messages.append(systemMessage)
                    }
                } else {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "user '\(nickname)' not found. they may be offline or using a different nickname.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    viewModel.messages.append(systemMessage)
                }
            } else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /m @nickname [message] or /m nickname [message]",
                    timestamp: Date(),
                    isRelay: false
                )
                viewModel.messages.append(systemMessage)
            }
        case "/w":
            let peerNicknames = viewModel.meshService.getPeerNicknames()
            if viewModel.connectedPeers.isEmpty {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "no one else is online right now.",
                    timestamp: Date(),
                    isRelay: false
                )
                viewModel.messages.append(systemMessage)
            } else {
                let onlineList = viewModel.connectedPeers.compactMap { peerID in
                    peerNicknames[peerID]
                }.sorted().joined(separator: ", ")

                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "online users: \(onlineList)",
                    timestamp: Date(),
                    isRelay: false
                )
                viewModel.messages.append(systemMessage)
            }
        case "/clear":
            // Clear messages based on current context
            if let peerID = viewModel.selectedPrivateChatPeer {
                // Clear private chat
                viewModel.privateChats[peerID]?.removeAll()
            } else {
                // Clear main messages
                viewModel.messages.removeAll()
            }
        case "/hug":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName

                // Check if target exists in connected peers
                if let targetPeerID = viewModel.getPeerIDForNickname(nickname) {
                    // Create hug message
                    let hugMessage = BitchatMessage(
                        sender: "system",
                        content: "🫂 \(viewModel.nickname) hugs \(nickname)",
                        timestamp: Date(),
                        isRelay: false,
                        isPrivate: false,
                        recipientNickname: nickname,
                        senderPeerID: viewModel.meshService.myPeerID
                    )

                    // Send as a regular message but it will be displayed as system message due to content
                    let hugContent = "* 🫂 \(viewModel.nickname) hugs \(nickname) *"
                    if viewModel.selectedPrivateChatPeer != nil {
                        // In private chat, send as private message
                        if let peerNickname = viewModel.meshService.getPeerNicknames()[targetPeerID] {
                            viewModel.meshService.sendPrivateMessage("* 🫂 \(viewModel.nickname) hugs you *", to: targetPeerID, recipientNickname: peerNickname)
                        }
                    } else {
                        // In public chat
                        viewModel.meshService.sendMessage(hugContent)
                        viewModel.messages.append(hugMessage)
                    }
                } else {
                    let errorMessage = BitchatMessage(
                        sender: "system",
                        content: "cannot hug \(nickname): user not found.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    viewModel.messages.append(errorMessage)
                }
            } else {
                let usageMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /hug <nickname>",
                    timestamp: Date(),
                    isRelay: false
                )
                viewModel.messages.append(usageMessage)
            }
        case "/slap":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName

                // Check if target exists in connected peers
                if let targetPeerID = viewModel.getPeerIDForNickname(nickname) {
                    // Create slap message
                    let slapMessage = BitchatMessage(
                        sender: "system",
                        content: "🐟 \(viewModel.nickname) slaps \(nickname) around a bit with a large trout",
                        timestamp: Date(),
                        isRelay: false,
                        isPrivate: false,
                        recipientNickname: nickname,
                        senderPeerID: viewModel.meshService.myPeerID
                    )

                    // Send as a regular message but it will be displayed as system message due to content
                    let slapContent = "* 🐟 \(viewModel.nickname) slaps \(nickname) around a bit with a large trout *"
                    if viewModel.selectedPrivateChatPeer != nil {
                        // In private chat, send as private message
                        if let peerNickname = viewModel.meshService.getPeerNicknames()[targetPeerID] {
                            viewModel.meshService.sendPrivateMessage("* 🐟 \(viewModel.nickname) slaps you around a bit with a large trout *", to: targetPeerID, recipientNickname: peerNickname)
                        }
                    } else {
                        // In public chat
                        viewModel.meshService.sendMessage(slapContent)
                        viewModel.messages.append(slapMessage)
                    }
                } else {
                    let errorMessage = BitchatMessage(
                        sender: "system",
                        content: "cannot slap \(nickname): user not found.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    viewModel.messages.append(errorMessage)
                }
            } else {
                let usageMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /slap <nickname>",
                    timestamp: Date(),
                    isRelay: false
                )
                viewModel.messages.append(usageMessage)
            }
        case "/block":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName

                // Find peer ID for this nickname
                if let peerID = viewModel.getPeerIDForNickname(nickname) {
                    // Get fingerprint for persistent blocking
                    if let fingerprintStr = viewModel.meshService.getPeerFingerprint(peerID) {

                        if SecureIdentityStateManager.shared.isBlocked(fingerprint: fingerprintStr) {
                            let systemMessage = BitchatMessage(
                                sender: "system",
                                content: "\(nickname) is already blocked.",
                                timestamp: Date(),
                                isRelay: false
                            )
                            viewModel.messages.append(systemMessage)
                        } else {
                            // Update or create social identity with blocked status
                            if var identity = SecureIdentityStateManager.shared.getSocialIdentity(for: fingerprintStr) {
                                identity.isBlocked = true
                                identity.isFavorite = false  // Remove from favorites if blocked
                                SecureIdentityStateManager.shared.updateSocialIdentity(identity)
                            } else {
                                let blockedIdentity = SocialIdentity(
                                    fingerprint: fingerprintStr,
                                    localPetname: nil,
                                    claimedNickname: nickname,
                                    trustLevel: .unknown,
                                    isFavorite: false,
                                    isBlocked: true,
                                    notes: nil
                                )
                                SecureIdentityStateManager.shared.updateSocialIdentity(blockedIdentity)
                            }

                            // Update local sets for UI
                            viewModel.blockedUsers.insert(fingerprintStr)
                            viewModel.favoritePeers.remove(fingerprintStr)

                            let systemMessage = BitchatMessage(
                                sender: "system",
                                content: "blocked \(nickname). you will no longer receive messages from them.",
                                timestamp: Date(),
                                isRelay: false
                            )
                            viewModel.messages.append(systemMessage)
                        }
                    } else {
                        let systemMessage = BitchatMessage(
                            sender: "system",
                            content: "cannot block \(nickname): unable to verify identity.",
                            timestamp: Date(),
                            isRelay: false
                        )
                        viewModel.messages.append(systemMessage)
                    }
                } else {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "cannot block \(nickname): user not found.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    viewModel.messages.append(systemMessage)
                }
            } else {
                // List blocked users
                if viewModel.blockedUsers.isEmpty {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "no blocked peers.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    viewModel.messages.append(systemMessage)
                } else {
                    // Find nicknames for blocked users
                    var blockedNicknames: [String] = []
                    for (peerID, _) in viewModel.meshService.getPeerNicknames() {
                        if let fingerprintStr = viewModel.meshService.getPeerFingerprint(peerID) {
                            if viewModel.blockedUsers.contains(fingerprintStr) {
                                if let nickname = viewModel.meshService.getPeerNicknames()[peerID] {
                                    blockedNicknames.append(nickname)
                                }
                            }
                        }
                    }

                    let blockedList = blockedNicknames.isEmpty ? "blocked peers(not currently online)" : blockedNicknames.sorted().joined(separator: ", ")
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "blocked peers: \(blockedList)",
                        timestamp: Date(),
                        isRelay: false
                    )
                    viewModel.messages.append(systemMessage)
                }
            }
        case "/unblock":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName

                // Find peer ID for this nickname
                if let peerID = viewModel.getPeerIDForNickname(nickname) {
                    // Get fingerprint
                    if let fingerprintStr = viewModel.meshService.getPeerFingerprint(peerID) {

                        if SecureIdentityStateManager.shared.isBlocked(fingerprint: fingerprintStr) {
                            // Update social identity to unblock
                            SecureIdentityStateManager.shared.setBlocked(fingerprintStr, isBlocked: false)

                            // Update local set for UI
                            viewModel.blockedUsers.remove(fingerprintStr)

                            let systemMessage = BitchatMessage(
                                sender: "system",
                                content: "unblocked \(nickname).",
                                timestamp: Date(),
                                isRelay: false
                            )
                            viewModel.messages.append(systemMessage)
                        } else {
                            let systemMessage = BitchatMessage(
                                sender: "system",
                                content: "\(nickname) is not blocked.",
                                timestamp: Date(),
                                isRelay: false
                            )
                            viewModel.messages.append(systemMessage)
                        }
                    } else {
                        let systemMessage = BitchatMessage(
                            sender: "system",
                            content: "cannot unblock \(nickname): unable to verify identity.",
                            timestamp: Date(),
                            isRelay: false
                        )
                        viewModel.messages.append(systemMessage)
                    }
                } else {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "cannot unblock \(nickname): user not found.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    viewModel.messages.append(systemMessage)
                }
            } else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /unblock <nickname>",
                    timestamp: Date(),
                    isRelay: false
                )
                viewModel.messages.append(systemMessage)
            }
        case "/fav":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName

                // Find peer ID for this nickname
                if let peerID = viewModel.getPeerIDForNickname(nickname) {
                    // Add to favorites using the Nostr integration
                    if let noisePublicKey = Data(hexString: peerID) {
                        // Get or set Nostr public key
                        let existingFavorite = FavoritesPersistenceService.shared.getFavoriteStatus(for: noisePublicKey)
                        FavoritesPersistenceService.shared.addFavorite(
                            peerNoisePublicKey: noisePublicKey,
                            peerNostrPublicKey: existingFavorite?.peerNostrPublicKey,
                            peerNickname: nickname
                        )

                        // Toggle favorite in identity manager for UI
                        viewModel.toggleFavorite(peerID: peerID)

                        // Send favorite notification
                        Task { [weak self] in
                            try? await self?.viewModel.messageRouter?.sendFavoriteNotification(to: noisePublicKey, isFavorite: true)
                        }

                        let systemMessage = BitchatMessage(
                            sender: "system",
                            content: "added \(nickname) to favorites.",
                            timestamp: Date(),
                            isRelay: false
                        )
                        viewModel.messages.append(systemMessage)
                    }
                } else {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "can't find peer: \(nickname)",
                        timestamp: Date(),
                        isRelay: false
                    )
                    viewModel.messages.append(systemMessage)
                }
            } else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /fav <nickname>",
                    timestamp: Date(),
                    isRelay: false
                )
                viewModel.messages.append(systemMessage)
            }
        case "/unfav":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName

                // Find peer ID for this nickname
                if let peerID = viewModel.getPeerIDForNickname(nickname) {
                    // Remove from favorites
                    if let noisePublicKey = Data(hexString: peerID) {
                        FavoritesPersistenceService.shared.removeFavorite(peerNoisePublicKey: noisePublicKey)

                        // Toggle favorite in identity manager for UI
                        viewModel.toggleFavorite(peerID: peerID)

                        // Send unfavorite notification
                        Task { [weak self] in
                            try? await self?.viewModel.messageRouter?.sendFavoriteNotification(to: noisePublicKey, isFavorite: false)
                        }

                        let systemMessage = BitchatMessage(
                            sender: "system",
                            content: "removed \(nickname) from favorites.",
                            timestamp: Date(),
                            isRelay: false
                        )
                        viewModel.messages.append(systemMessage)
                    }
                } else {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "can't find peer: \(nickname)",
                        timestamp: Date(),
                        isRelay: false
                    )
                    viewModel.messages.append(systemMessage)
                }
            } else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /unfav <nickname>",
                    timestamp: Date(),
                    isRelay: false
                )
                viewModel.messages.append(systemMessage)
            }
        case "/testnostr":
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "testing nostr relay connectivity...",
                timestamp: Date(),
                isRelay: false
            )
            viewModel.messages.append(systemMessage)

            Task { @MainActor in
                if let relayManager = self.viewModel.nostrRelayManager {
                    // Simple connectivity test
                    relayManager.connect()

                    // Wait a moment for connections
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

                    let statusMessage = if relayManager.isConnected {
                        "nostr relays connected successfully!"
                    } else {
                        "failed to connect to nostr relays - check console for details"
                    }

                    let completeMessage = BitchatMessage(
                        sender: "system",
                        content: statusMessage,
                        timestamp: Date(),
                        isRelay: false
                    )
                    self.viewModel.messages.append(completeMessage)
                } else {
                    let errorMessage = BitchatMessage(
                        sender: "system",
                        content: "nostr relay manager not initialized",
                        timestamp: Date(),
                        isRelay: false
                    )
                    self.viewModel.messages.append(errorMessage)
                }
            }
        default:
            // Unknown command
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "unknown command: \(cmd).",
                timestamp: Date(),
                isRelay: false
            )
            viewModel.messages.append(systemMessage)
        }
    }
}
