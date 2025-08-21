//
//  GroupChat.swift
//  bitchat
//
//  Created by Waluya Juang Husada on 21/08/25.
//


//
// GroupChat.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Represents a group chat room that can include multiple participants
/// Similar to PersistentPrivateChat but supports multiple members
struct GroupChat: Codable, Identifiable {
    let id: String // Unique group ID
    var groupName: String
    var members: [GroupMember] // List of group members
    var messages: [BitchatMessage]
    var pendingMessages: [BitchatMessage] // Messages waiting to be sent when members come online
    var lastActivity: Date
    var unreadCount: Int
    var chatCreatedDate: Date
    var groupDescription: String?
    var createdBy: String // Fingerprint of creator
    var admins: Set<String> // Set of fingerprints with admin privileges
    var isPrivate: Bool // Whether the group requires invitation to join
    
    init(id: String? = nil, groupName: String, createdBy: String, isPrivate: Bool = false) {
        self.id = id ?? UUID().uuidString
        self.groupName = groupName
        self.members = []
        self.messages = []
        self.pendingMessages = []
        self.lastActivity = Date()
        self.unreadCount = 0
        self.chatCreatedDate = Date()
        self.groupDescription = nil
        self.createdBy = createdBy
        self.admins = [createdBy] // Creator is automatically an admin
        self.isPrivate = isPrivate
    }
    
    /// Add a member to the group
    mutating func addMember(_ member: GroupMember) {
        if !members.contains(where: { $0.fingerprint == member.fingerprint }) {
            members.append(member)
        }
    }
    
    /// Remove a member from the group
    mutating func removeMember(fingerprint: String) {
        members.removeAll { $0.fingerprint == fingerprint }
        admins.remove(fingerprint)
    }
    
    /// Update member status when they come online
    mutating func memberCameOnline(fingerprint: String, peerID: String) {
        if let index = members.firstIndex(where: { $0.fingerprint == fingerprint }) {
            members[index].peerCameOnline(peerID: peerID)
        }
    }
    
    /// Update member status when they go offline
    mutating func memberWentOffline(fingerprint: String) {
        if let index = members.firstIndex(where: { $0.fingerprint == fingerprint }) {
            members[index].peerWentOffline()
        }
    }
    
    /// Add a new message to the group
    mutating func addMessage(_ message: BitchatMessage) {
        // Check for duplicates
        if !messages.contains(where: { $0.id == message.id }) {
            messages.append(message)
            messages.sort { $0.timestamp < $1.timestamp }
            lastActivity = max(lastActivity, message.timestamp)
            
            // Increment unread count for messages from others
            if let senderID = message.senderPeerID,
               !members.contains(where: { $0.currentPeerID == senderID && $0.fingerprint == createdBy }) {
                unreadCount += 1
            }
        }
    }
    
    /// Add a pending message (to be sent when members come online)
    mutating func addPendingMessage(_ message: BitchatMessage) {
        if !pendingMessages.contains(where: { $0.id == message.id }) {
            pendingMessages.append(message)
        }
    }
    
    /// Move pending messages to sent messages and return them for actual sending
    mutating func promotePendingMessages() -> [BitchatMessage] {
        let toSend = pendingMessages
        for message in toSend {
            addMessage(message)
        }
        pendingMessages.removeAll()
        return toSend
    }
    
    /// Mark all messages as read
    mutating func markAsRead() {
        unreadCount = 0
    }
    
    /// Get online members
    var onlineMembers: [GroupMember] {
        return members.filter { $0.isOnline }
    }
    
    /// Get offline members
    var offlineMembers: [GroupMember] {
        return members.filter { !$0.isOnline }
    }
    
    /// Check if a fingerprint is an admin
    func isAdmin(_ fingerprint: String) -> Bool {
        return admins.contains(fingerprint)
    }
    
    /// Make a member an admin (only existing admins can do this)
    mutating func makeAdmin(_ fingerprint: String, by adminFingerprint: String) -> Bool {
        guard isAdmin(adminFingerprint) && members.contains(where: { $0.fingerprint == fingerprint }) else {
            return false
        }
        admins.insert(fingerprint)
        return true
    }
    
    /// Remove admin privileges (only existing admins can do this, but not the creator)
    mutating func removeAdmin(_ fingerprint: String, by adminFingerprint: String) -> Bool {
        guard isAdmin(adminFingerprint) && fingerprint != createdBy else {
            return false
        }
        admins.remove(fingerprint)
        return true
    }
    
    /// Get display name for the group
    var displayName: String {
        return groupName.isEmpty ? "Group \(id.prefix(8))" : groupName
    }
    
    /// Get status indicator for the group
    var statusIndicator: String {
        let onlineCount = onlineMembers.count
        if onlineCount == 0 {
            return "⚫" // All offline
        } else if !pendingMessages.isEmpty {
            return "🟡" // Has pending messages
        } else {
            return "🟢" // Some members online
        }
    }
    
    /// Get status text
    var statusText: String {
        let onlineCount = onlineMembers.count
        let totalCount = members.count
        
        if onlineCount == 0 {
            return "All offline (\(totalCount) members)"
        } else if !pendingMessages.isEmpty {
            return "Pending (\(pendingMessages.count))"
        } else {
            return "\(onlineCount)/\(totalCount) online"
        }
    }
}

/// Represents a member of a group chat
struct GroupMember: Codable, Identifiable {
    let id: String // Same as fingerprint
    let fingerprint: String
    var nickname: String
    var isOnline: Bool
    var currentPeerID: String? // Current ephemeral peer ID if online
    var lastSeen: Date
    var joinedDate: Date
    var role: GroupMemberRole
    
    init(fingerprint: String, nickname: String, role: GroupMemberRole = .member) {
        self.id = fingerprint
        self.fingerprint = fingerprint
        self.nickname = nickname
        self.isOnline = false
        self.currentPeerID = nil
        self.lastSeen = Date()
        self.joinedDate = Date()
        self.role = role
    }
    
    /// Update member status when they come online
    mutating func peerCameOnline(peerID: String) {
        self.isOnline = true
        self.currentPeerID = peerID
        self.lastSeen = Date()
    }
    
    /// Update member status when they go offline
    mutating func peerWentOffline() {
        self.isOnline = false
        self.currentPeerID = nil
        self.lastSeen = Date()
    }
    
    /// Update member nickname
    mutating func updateNickname(_ newNickname: String) {
        self.nickname = newNickname
    }
    
    /// Get display name for the member
    var displayName: String {
        return nickname.isEmpty ? "Unknown (\(fingerprint.prefix(8)))" : nickname
    }
}

/// Role of a group member
enum GroupMemberRole: String, Codable, CaseIterable {
    case admin = "admin"
    case member = "member"
    
    var displayName: String {
        switch self {
        case .admin:
            return "Admin"
        case .member:
            return "Member"
        }
    }
}

/// Group invitation structure
struct GroupInvitation: Codable {
    let id: String
    let groupID: String
    let groupName: String
    let inviterFingerprint: String
    let inviterNickname: String
    let inviteeFingerprint: String
    let timestamp: Date
    var status: InvitationStatus
    
    init(groupID: String, groupName: String, inviterFingerprint: String, inviterNickname: String, inviteeFingerprint: String) {
        self.id = UUID().uuidString
        self.groupID = groupID
        self.groupName = groupName
        self.inviterFingerprint = inviterFingerprint
        self.inviterNickname = inviterNickname
        self.inviteeFingerprint = inviteeFingerprint
        self.timestamp = Date()
        self.status = .pending
    }
}

/// Status of a group invitation
enum InvitationStatus: String, Codable {
    case pending = "pending"
    case accepted = "accepted"
    case declined = "declined"
    case expired = "expired"
}

/// Group message types for protocol extensions
enum GroupMessageType: UInt8 {
    case groupMessage = 0x30        // Regular group message
    case groupInvitation = 0x31     // Group invitation
    case groupInviteResponse = 0x32 // Response to invitation
    case groupMemberUpdate = 0x33   // Member joined/left/promoted
    case groupInfoUpdate = 0x34     // Group name/description changed
    case groupKeyExchange = 0x35    // Group encryption key exchange
}
