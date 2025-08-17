//
// CommandProcessor.swift
// bitchat
//
// Handles command parsing and execution for BitChat
// This is free and unencumbered software released into the public domain.
//

import Foundation

/// Result of command processing
enum CommandResult {
    case success(message: String?)
    case error(message: String)
    case handled  // Command handled, no message needed
}

/// Processes chat commands in a focused, efficient way
@MainActor
class CommandProcessor {
    weak var chatViewModel: ChatViewModel?
    weak var meshService: Transport?
    
    init(chatViewModel: ChatViewModel? = nil, meshService: Transport? = nil) {
        self.chatViewModel = chatViewModel
        self.meshService = meshService
    }
    
    /// Process a command string
    @MainActor
    func process(_ command: String) -> CommandResult {
        let parts = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let cmd = parts.first else { return .error(message: "Invalid command") }
        let args = parts.count > 1 ? String(parts[1]) : ""
        
        switch cmd {
        case "/m", "/msg":
            return handleMessage(args)
        case "/w", "/who":
            return handleWho()
        case "/clear":
            return handleClear()
        case "/hug":
            return handleEmote(args, action: "hugs", emoji: "🫂")
        case "/slap":
            return handleEmote(args, action: "slaps", emoji: "🐟", suffix: " around a bit with a large trout")
        case "/block":
            return handleBlock(args)
        case "/unblock":
            return handleUnblock(args)
        case "/fav":
            return handleFavorite(args, add: true)
        case "/unfav":
            return handleFavorite(args, add: false)
        case "/help", "/h":
            return handleHelp()
        default:
            return .error(message: "unknown command: \(cmd)")
        }
    }
    
    // MARK: - Command Handlers
    
    private func handleMessage(_ args: String) -> CommandResult {
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts.isEmpty else {
            return .error(message: "usage: /msg @nickname [message]")
        }
        
        let targetName = String(parts[0])
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        guard let peerID = chatViewModel?.getPeerIDForNickname(nickname) else {
            return .error(message: "'\(nickname)' not found")
        }
        
        chatViewModel?.startPrivateChat(with: peerID)
        
        if parts.count > 1 {
            let message = String(parts[1])
            chatViewModel?.sendPrivateMessage(message, to: peerID)
        }
        
        return .success(message: "started private chat with \(nickname)")
    }
    
    private func handleWho() -> CommandResult {
        guard let peers = meshService?.getPeerNicknames(), !peers.isEmpty else {
            return .success(message: "no one else is online right now")
        }
        
        let onlineList = peers.values.sorted().joined(separator: ", ")
        return .success(message: "online: \(onlineList)")
    }
    
    private func handleClear() -> CommandResult {
        if let peerID = chatViewModel?.selectedPrivateChatPeer {
            chatViewModel?.privateChats[peerID]?.removeAll()
        } else {
            chatViewModel?.messages.removeAll()
        }
        return .handled
    }
    
    private func handleEmote(_ args: String, action: String, emoji: String, suffix: String = "") -> CommandResult {
        let targetName = args.trimmingCharacters(in: .whitespaces)
        guard !targetName.isEmpty else {
            return .error(message: "usage: /\(action) <nickname>")
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        guard let targetPeerID = chatViewModel?.getPeerIDForNickname(nickname),
              let myNickname = chatViewModel?.nickname else {
            return .error(message: "cannot \(action) \(nickname): not found")
        }
        
        let emoteContent = "* \(emoji) \(myNickname) \(action) \(nickname)\(suffix) *"
        
        if chatViewModel?.selectedPrivateChatPeer != nil {
            // In private chat
            if let peerNickname = meshService?.getPeerNicknames()[targetPeerID] {
                let personalMessage = "* \(emoji) \(myNickname) \(action) you\(suffix) *"
                meshService?.sendPrivateMessage(personalMessage, to: targetPeerID, 
                                               recipientNickname: peerNickname, 
                                               messageID: UUID().uuidString)
            }
        } else {
            // In public chat
            meshService?.sendMessage(emoteContent, mentions: [])
        }
        
        return .handled
    }
    
    private func handleBlock(_ args: String) -> CommandResult {
        let targetName = args.trimmingCharacters(in: .whitespaces)
        
        if targetName.isEmpty {
            // List blocked users
            guard let blockedUsers = chatViewModel?.blockedUsers, !blockedUsers.isEmpty else {
                return .success(message: "no blocked peers")
            }
            
            var blockedNicknames: [String] = []
            if let peers = meshService?.getPeerNicknames() {
                for (peerID, nickname) in peers {
                    if let fingerprint = meshService?.getFingerprint(for: peerID),
                       blockedUsers.contains(fingerprint) {
                        blockedNicknames.append(nickname)
                    }
                }
            }
            
            let list = blockedNicknames.isEmpty ? "blocked peers (not currently online)" 
                                                 : blockedNicknames.sorted().joined(separator: ", ")
            return .success(message: "blocked peers: \(list)")
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        guard let peerID = chatViewModel?.getPeerIDForNickname(nickname),
              let fingerprint = meshService?.getFingerprint(for: peerID) else {
            return .error(message: "cannot block \(nickname): not found or unable to verify identity")
        }
        
        if SecureIdentityStateManager.shared.isBlocked(fingerprint: fingerprint) {
            return .success(message: "\(nickname) is already blocked")
        }
        
        // Block the user
        if var identity = SecureIdentityStateManager.shared.getSocialIdentity(for: fingerprint) {
            identity.isBlocked = true
            identity.isFavorite = false
            SecureIdentityStateManager.shared.updateSocialIdentity(identity)
        } else {
            let blockedIdentity = SocialIdentity(
                fingerprint: fingerprint,
                localPetname: nil,
                claimedNickname: nickname,
                trustLevel: .unknown,
                isFavorite: false,
                isBlocked: true,
                notes: nil
            )
            SecureIdentityStateManager.shared.updateSocialIdentity(blockedIdentity)
        }
        
        // The peerStateManager and SecureIdentityStateManager handle the blocking state
        
        return .success(message: "blocked \(nickname). you will no longer receive messages from them")
    }
    
    private func handleUnblock(_ args: String) -> CommandResult {
        let targetName = args.trimmingCharacters(in: .whitespaces)
        guard !targetName.isEmpty else {
            return .error(message: "usage: /unblock <nickname>")
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        guard let peerID = chatViewModel?.getPeerIDForNickname(nickname),
              let fingerprint = meshService?.getFingerprint(for: peerID) else {
            return .error(message: "cannot unblock \(nickname): not found")
        }
        
        if !SecureIdentityStateManager.shared.isBlocked(fingerprint: fingerprint) {
            return .success(message: "\(nickname) is not blocked")
        }
        
        SecureIdentityStateManager.shared.setBlocked(fingerprint, isBlocked: false)
        // The SecureIdentityStateManager handles the unblocking state
        
        return .success(message: "unblocked \(nickname)")
    }
    
    private func handleFavorite(_ args: String, add: Bool) -> CommandResult {
        let targetName = args.trimmingCharacters(in: .whitespaces)
        guard !targetName.isEmpty else {
            return .error(message: "usage: /\(add ? "fav" : "unfav") <nickname>")
        }
        
        let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
        
        guard let peerID = chatViewModel?.getPeerIDForNickname(nickname),
              let noisePublicKey = Data(hexString: peerID) else {
            return .error(message: "can't find peer: \(nickname)")
        }
        
        if add {
            let existingFavorite = FavoritesPersistenceService.shared.getFavoriteStatus(for: noisePublicKey)
            FavoritesPersistenceService.shared.addFavorite(
                peerNoisePublicKey: noisePublicKey,
                peerNostrPublicKey: existingFavorite?.peerNostrPublicKey,
                peerNickname: nickname
            )
            
            chatViewModel?.toggleFavorite(peerID: peerID)
            chatViewModel?.sendFavoriteNotification(to: peerID, isFavorite: true)
            
            return .success(message: "added \(nickname) to favorites")
        } else {
            FavoritesPersistenceService.shared.removeFavorite(peerNoisePublicKey: noisePublicKey)
            
            chatViewModel?.toggleFavorite(peerID: peerID)
            chatViewModel?.sendFavoriteNotification(to: peerID, isFavorite: false)
            
            return .success(message: "removed \(nickname) from favorites")
        }
    }
    
    private func handleHelp() -> CommandResult {
        let helpText = """
        commands:
        /msg @name - start private chat
        /who - list who's online
        /clear - clear messages
        /hug @name - send a hug
        /slap @name - slap with a trout
        /fav @name - add to favorites
        /unfav @name - remove from favorites
        /block @name - block
        /unblock @name - unblock
        """
        return .success(message: helpText)
    }
}
