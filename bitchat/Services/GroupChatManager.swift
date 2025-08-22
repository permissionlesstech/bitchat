//
//  GroupChatManager.swift
//  bitchat
//
//  Created by Waluya Juang Husada on 21/08/25.
//


//
// GroupChatManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import SwiftUI

/// Manages group chat functionality
/// Handles creation, persistence, member management, and messaging for group chats
class GroupChatManager: ObservableObject {
    @Published var groupChats: [String: GroupChat] = [:] // groupID -> chat
    @Published var selectedGroupID: String? = nil
    @Published var pendingInvitations: [GroupInvitation] = []
    @Published var sentInvitations: [GroupInvitation] = []
    
    private let userDefaults = UserDefaults.standard
    private let groupChatsKey = "bitchat.groupChats"
    private let selectedGroupKey = "bitchat.selectedGroup"
    private let pendingInvitationsKey = "bitchat.pendingInvitations"
    private let sentInvitationsKey = "bitchat.sentInvitations"
    
    // Dependencies
    weak var meshService: Transport?
    weak var messageRouter: MessageRouter?
    
    // Tracking
    private var onlinePeers: [String: String] = [:] // peerID -> fingerprint
    private var peerFingerprints: [String: String] = [:] // fingerprint -> current peerID
    
    init(meshService: Transport? = nil) {
        self.meshService = meshService
        loadGroupChats()
        loadSelectedGroup()
        loadInvitations()
    }
    
    // MARK: - Persistence
    
    /// Load group chats from storage
    private func loadGroupChats() {
        guard let data = userDefaults.data(forKey: groupChatsKey) else {
            print("📱 No group chats found in storage")
            return
        }
        
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let chats = try decoder.decode([String: GroupChat].self, from: data)
            DispatchQueue.main.async { [weak self] in
                self?.groupChats = chats
            }
            print("📱 Loaded \(chats.count) group chats")
            
            // Debug logging
            for (_, chat) in chats {
                print("📱 Group '\(chat.groupName)': \(chat.messages.count) messages, \(chat.members.count) members")
            }
        } catch {
            print("❌ Failed to load group chats: \(error)")
        }
    }
    
    /// Save group chats to storage
    private func saveGroupChats() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(groupChats)
            userDefaults.set(data, forKey: groupChatsKey)
            userDefaults.synchronize()
            print("💾 Saved \(groupChats.count) group chats")
        } catch {
            print("❌ Failed to save group chats: \(error)")
            print("❌ Error details: \(error.localizedDescription)")
            
            // Try to save individual groups to identify the problematic one
            for (groupID, group) in groupChats {
                do {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    _ = try encoder.encode(group)
                    print("✅ Group '\(group.groupName)' (\(groupID.prefix(8))) encoded successfully")
                } catch let groupError {
                    print("❌ Failed to encode group '\(group.groupName)' (\(groupID.prefix(8))): \(groupError)")
                    
                    // Try to identify which part of the group is problematic
                    do {
                        let testEncoder = JSONEncoder()
                        testEncoder.dateEncodingStrategy = .iso8601
                        _ = try testEncoder.encode(group.members)
                        print("✅   Members encoded successfully")
                    } catch {
                        print("❌   Members failed: \(error)")
                    }
                    
                    do {
                        let testEncoder = JSONEncoder()
                        testEncoder.dateEncodingStrategy = .iso8601
                        _ = try testEncoder.encode(group.messages)
                        print("✅   Messages encoded successfully") 
                    } catch {
                        print("❌   Messages failed: \(error)")
                    }
                    
                    do {
                        let testEncoder = JSONEncoder()
                        testEncoder.dateEncodingStrategy = .iso8601
                        _ = try testEncoder.encode(group.pendingMessages)
                        print("✅   Pending messages encoded successfully")
                    } catch {
                        print("❌   Pending messages failed: \(error)")
                    }
                }
            }
        }
    }
    
    /// Load selected group from storage
    private func loadSelectedGroup() {
        selectedGroupID = userDefaults.string(forKey: selectedGroupKey)
    }
    
    /// Save selected group to storage
    private func saveSelectedGroup() {
        if let groupID = selectedGroupID {
            userDefaults.set(groupID, forKey: selectedGroupKey)
        } else {
            userDefaults.removeObject(forKey: selectedGroupKey)
        }
        userDefaults.synchronize()
    }
    
    /// Load invitations from storage
    private func loadInvitations() {
        // Load pending invitations
        if let data = userDefaults.data(forKey: pendingInvitationsKey) {
            do {
                let invitations = try JSONDecoder().decode([GroupInvitation].self, from: data)
                DispatchQueue.main.async { [weak self] in
                    self?.pendingInvitations = invitations
                }
            } catch {
                print("❌ Failed to load pending invitations: \(error)")
            }
        }
        
        // Load sent invitations
        if let data = userDefaults.data(forKey: sentInvitationsKey) {
            do {
                let invitations = try JSONDecoder().decode([GroupInvitation].self, from: data)
                DispatchQueue.main.async { [weak self] in
                    self?.sentInvitations = invitations
                }
            } catch {
                print("❌ Failed to load sent invitations: \(error)")
            }
        }
    }
    
    /// Save invitations to storage
    private func saveInvitations() {
        do {
            let pendingData = try JSONEncoder().encode(pendingInvitations)
            userDefaults.set(pendingData, forKey: pendingInvitationsKey)
            
            let sentData = try JSONEncoder().encode(sentInvitations)
            userDefaults.set(sentData, forKey: sentInvitationsKey)
            
            userDefaults.synchronize()
        } catch {
            print("❌ Failed to save invitations: \(error)")
        }
    }
    
    // MARK: - Group Management
    
    /// Create a new group chat
    func createGroup(name: String, description: String? = nil, isPrivate: Bool = false, creatorFingerprint: String) -> GroupChat {
        var newGroup = GroupChat(groupName: name, createdBy: creatorFingerprint, isPrivate: isPrivate)
        newGroup.groupDescription = description
        
        // Add creator as first member with admin role
        let creator = GroupMember(fingerprint: creatorFingerprint, nickname: meshService?.myNickname ?? "Me", role: .admin)
        newGroup.addMember(creator)
        
        DispatchQueue.main.async { [weak self] in
            self?.groupChats[newGroup.id] = newGroup
            self?.saveGroupChats()
        }
        
        print("✅ Created new group '\(name)' with ID \(newGroup.id.prefix(8))")
        return newGroup
    }
    
    /// Delete a group (only admins can do this)
    func deleteGroup(_ groupID: String, requestedBy fingerprint: String) -> Bool {
        guard let group = groupChats[groupID],
              group.isAdmin(fingerprint) else {
            print("❌ Cannot delete group: insufficient permissions")
            return false
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.groupChats.removeValue(forKey: groupID)
            
            // Clear selection if this group was selected
            if self?.selectedGroupID == groupID {
                self?.selectedGroupID = nil
                self?.saveSelectedGroup()
            }
        }
        
        saveGroupChats()
        print("🗑️ Deleted group '\(group.groupName)' (\(groupID.prefix(8)))")
        return true
    }
    
    /// Join a group chat
    func joinGroup(_ groupID: String) {
        DispatchQueue.main.async { [weak self] in
            self?.selectedGroupID = groupID
        }
        saveSelectedGroup()
        
        // Mark messages as read
        markGroupAsRead(groupID: groupID)
    }
    
    /// Leave current group
    func leaveCurrentGroup() {
        DispatchQueue.main.async { [weak self] in
            self?.selectedGroupID = nil
        }
        saveSelectedGroup()
    }
    
    /// Add member to group
    func addMember(fingerprint: String, nickname: String, to groupID: String, addedBy adminFingerprint: String) -> Bool {
        guard var group = groupChats[groupID],
              group.isAdmin(adminFingerprint) else {
            print("❌ Cannot add member: insufficient permissions")
            return false
        }
        
        let newMember = GroupMember(fingerprint: fingerprint, nickname: nickname)
        group.addMember(newMember)
        
        DispatchQueue.main.async { [weak self] in
            self?.groupChats[groupID] = group
        }
        saveGroupChats()
        
        print("✅ Added \(nickname) to group '\(group.groupName)'")
        return true
    }
    
    /// Remove member from group
    func removeMember(fingerprint: String, from groupID: String, removedBy adminFingerprint: String) -> Bool {
        guard var group = groupChats[groupID],
              group.isAdmin(adminFingerprint),
              fingerprint != group.createdBy else { // Can't remove creator
            print("❌ Cannot remove member: insufficient permissions")
            return false
        }
        
        group.removeMember(fingerprint: fingerprint)
        
        DispatchQueue.main.async { [weak self] in
            self?.groupChats[groupID] = group
        }
        saveGroupChats()
        
        print("🚫 Removed member (\(fingerprint.prefix(8))) from group '\(group.groupName)'")
        return true
    }
    
    /// Update group info (name, description)
    func updateGroupInfo(groupID: String, name: String? = nil, description: String? = nil, updatedBy adminFingerprint: String) -> Bool {
        guard var group = groupChats[groupID],
              group.isAdmin(adminFingerprint) else {
            print("❌ Cannot update group info: insufficient permissions")
            return false
        }
        
        if let name = name {
            group.groupName = name
        }
        
        if let description = description {
            group.groupDescription = description
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.groupChats[groupID] = group
        }
        saveGroupChats()
        
        print("✏️ Updated group info for '\(group.groupName)'")
        return true
    }
    
    // MARK: - Messaging
    
    /// Send message to a group
    func sendMessage(_ content: String, to groupID: String, senderPeerID: String, senderNickname: String, senderFingerprint: String) {
        guard var group = groupChats[groupID],
              group.members.contains(where: { $0.fingerprint == senderFingerprint }) else {
            print("❌ Cannot send message: not a member of the group")
            return
        }
        
        let messageID = UUID().uuidString
        let message = BitchatMessage(
            id: messageID,
            sender: senderNickname,
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: false, // Group messages are not private in the traditional sense
            recipientNickname: nil, // Group message, no specific recipient
            senderPeerID: senderPeerID,
            mentions: extractMentions(from: content, in: group),
            deliveryStatus: .sending
        )
        
        // Add message to group
        group.addMessage(message)
        
        // Send to all online members except sender
        let onlineMembers = group.onlineMembers.filter { $0.fingerprint != senderFingerprint }
        
        if !onlineMembers.isEmpty {
            // Send immediately to online members
            for member in onlineMembers {
                if let peerID = member.currentPeerID {
                    sendGroupMessage(message, to: peerID, groupID: groupID)
                }
            }
            print("📨 Sent group message to \(onlineMembers.count) online members")
        }
        
        // Queue for offline members
        let offlineMembers = group.offlineMembers.filter { $0.fingerprint != senderFingerprint }
        if !offlineMembers.isEmpty {
            group.addPendingMessage(message)
            print("📝 Queued group message for \(offlineMembers.count) offline members")
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.groupChats[groupID] = group
        }
        saveGroupChats()
    }
    
    /// Handle incoming group message
    func handleIncomingGroupMessage(_ message: BitchatMessage, from fingerprint: String, groupID: String) {
        guard var group = groupChats[groupID],
              group.members.contains(where: { $0.fingerprint == fingerprint }) else {
            print("❌ Received group message from non-member")
            return
        }
        
        group.addMessage(message)
        
        DispatchQueue.main.async { [weak self] in
            self?.groupChats[groupID] = group
        }
        saveGroupChats()
        
        print("📥 Received group message in '\(group.groupName)'")
    }
    
    /// Extract mentions from message content
    private func extractMentions(from content: String, in group: GroupChat) -> [String]? {
        let mentionPattern = #"@(\w+)"#
        guard let regex = try? NSRegularExpression(pattern: mentionPattern) else { return nil }
        
        let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        let mentions = matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: content) else { return nil }
            let mention = String(content[range])
            
            // Check if mentioned user is in the group
            return group.members.contains { $0.nickname.lowercased() == mention.lowercased() } ? mention : nil
        }
        
        return mentions.isEmpty ? nil : mentions
    }
    
    /// Send group message via transport
    private func sendGroupMessage(_ message: BitchatMessage, to peerID: String, groupID: String) {
        // Send via MessageRouter using proper group message protocol
        Task { @MainActor in
            if let router = messageRouter {
                let mentions = message.mentions ?? []
                router.sendGroupMessage(message.content, to: groupID, mentions: mentions)
                print("📨 Sent group message via router to group \(groupID.prefix(8))")
            } else {
                // Fallback: use private message mechanism with group metadata
                let groupMessageData: [String: Any] = [
                    "type": "group_message",
                    "groupID": groupID,
                    "messageID": message.id,
                    "content": message.content,
                    "timestamp": ISO8601DateFormatter().string(from: message.timestamp)
                ]
                
                if let jsonData = try? JSONSerialization.data(withJSONObject: groupMessageData),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    meshService?.sendPrivateMessage(jsonString, to: peerID, recipientNickname: "Group", messageID: message.id)
                }
                print("📨 Sent group message via fallback private message to \(peerID)")
            }
        }
    }
    
    // MARK: - Peer Status Management
    
    /// Update peer status when they come online
    func peerCameOnline(peerID: String, fingerprint: String, nickname: String) {
        onlinePeers[peerID] = fingerprint
        peerFingerprints[fingerprint] = peerID
        
        // Update member status in all groups
        for (groupID, var group) in groupChats {
            if group.members.contains(where: { $0.fingerprint == fingerprint }) {
                group.memberCameOnline(fingerprint: fingerprint, peerID: peerID)
                
                // Update nickname if changed
                if let memberIndex = group.members.firstIndex(where: { $0.fingerprint == fingerprint }) {
                    group.members[memberIndex].updateNickname(nickname)
                }
                
                DispatchQueue.main.async { [weak self] in
                    self?.groupChats[groupID] = group
                }
                
                // Send pending messages for this group
                sendPendingGroupMessages(groupID: groupID, to: fingerprint)
            }
        }
        
        saveGroupChats()
        print("🟢 Peer \(nickname) came online in groups")
    }
    
    /// Update peer status when they go offline
    func peerWentOffline(peerID: String) {
        guard let fingerprint = onlinePeers[peerID] else { return }
        
        onlinePeers.removeValue(forKey: peerID)
        peerFingerprints.removeValue(forKey: fingerprint)
        
        // Update member status in all groups
        for (groupID, var group) in groupChats {
            if group.members.contains(where: { $0.fingerprint == fingerprint }) {
                group.memberWentOffline(fingerprint: fingerprint)
                DispatchQueue.main.async { [weak self] in
                    self?.groupChats[groupID] = group
                }
            }
        }
        
        saveGroupChats()
        print("⚫ Peer went offline in groups")
    }
    
    /// Send pending group messages when member comes online
    private func sendPendingGroupMessages(groupID: String, to fingerprint: String) {
        guard var group = groupChats[groupID],
              let peerID = peerFingerprints[fingerprint],
              !group.pendingMessages.isEmpty else { return }
        
        let messagesToSend = group.promotePendingMessages()
        DispatchQueue.main.async { [weak self] in
            self?.groupChats[groupID] = group
        }
        saveGroupChats()
        
        // Send each pending message
        for message in messagesToSend {
            sendGroupMessage(message, to: peerID, groupID: groupID)
        }
        
        print("📤 Sent \(messagesToSend.count) pending group messages")
    }
    
    // MARK: - Invitation Management
    
    /// Send group invitation
    func sendInvitation(groupID: String, to fingerprint: String, nickname: String, from inviterFingerprint: String) -> Bool {
        print("🔍 Attempting to send invitation to \(nickname) (\(fingerprint.prefix(8))) for group \(groupID.prefix(8))")
        
        guard let group = groupChats[groupID] else {
            print("❌ Cannot send invitation: group not found")
            return false
        }
        
        guard group.isAdmin(inviterFingerprint) else {
            print("❌ Cannot send invitation: insufficient permissions")
            return false
        }
        
        guard !group.members.contains(where: { $0.fingerprint == fingerprint }) else {
            print("❌ Cannot send invitation: user is already a member")
            return false
        }
        
        let invitation = GroupInvitation(
            groupID: groupID,
            groupName: group.groupName,
            inviterFingerprint: inviterFingerprint,
            inviterNickname: meshService?.myNickname ?? "Unknown",
            inviteeFingerprint: fingerprint
        )
        
        DispatchQueue.main.async { [weak self] in
            self?.sentInvitations.append(invitation)
        }
        saveInvitations()
        
        // Send invitation via transport
        sendInvitationMessage(invitation, to: fingerprint)
        
        print("📤 Sent group invitation to \(nickname)")
        return true
    }
    
    /// Handle received invitation
    func handleIncomingInvitation(_ invitation: GroupInvitation) {
        print("📋 GroupChatManager.handleIncomingInvitation called")
        print("📋   Group: \(invitation.groupName)")
        print("📋   Invitation ID: \(invitation.id)")
        print("📋   Current pending invitations: \(pendingInvitations.count)")
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Check for duplicates
            let isDuplicate = self.pendingInvitations.contains(where: { $0.id == invitation.id })
            print("📋   Is duplicate: \(isDuplicate)")
            
            if !isDuplicate {
                self.pendingInvitations.append(invitation)
                self.saveInvitations()
                print("📋   Added invitation to pending list. New count: \(self.pendingInvitations.count)")
            } else {
                print("📋   Skipped duplicate invitation")
            }
        }
        print("📥 Received group invitation for '\(invitation.groupName)'")
    }
    
    /// Accept group invitation
    func acceptInvitation(_ invitationID: String, userFingerprint: String) -> Bool {
        guard let invitation = pendingInvitations.first(where: { $0.id == invitationID }) else {
            return false
        }
        
        // Create or join the group
        var group = groupChats[invitation.groupID] ?? GroupChat(
            id: invitation.groupID,
            groupName: invitation.groupName,
            createdBy: invitation.inviterFingerprint
        )
        
        // Add user as member
        let newMember = GroupMember(fingerprint: userFingerprint, nickname: meshService?.myNickname ?? "Me")
        group.addMember(newMember)
        
        DispatchQueue.main.async { [weak self] in
            self?.groupChats[invitation.groupID] = group
            self?.pendingInvitations.removeAll { $0.id == invitationID }
        }
        
        saveGroupChats()
        saveInvitations()
        
        // Send acceptance response
        sendInvitationResponse(invitationID: invitationID, accepted: true, to: invitation.inviterFingerprint)
        
        print("✅ Accepted invitation to '\(invitation.groupName)'")
        return true
    }
    
    /// Decline group invitation
    func declineInvitation(_ invitationID: String) -> Bool {
        guard let invitation = pendingInvitations.first(where: { $0.id == invitationID }) else {
            print("❌ Invitation not found: \(invitationID)")
            return false
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.pendingInvitations.removeAll { $0.id == invitationID }
        }
        saveInvitations()
        
        // Send decline response
        sendInvitationResponse(invitationID: invitationID, accepted: false, to: invitation.inviterFingerprint)
        
        print("❌ Declined invitation to '\(invitation.groupName)'")
        return true
    }
    
    /// Send invitation message via transport
    private func sendInvitationMessage(_ invitation: GroupInvitation, to fingerprint: String) {
        print("🔍 Looking for peerID for fingerprint: \(fingerprint.prefix(8))")
        print("🔍 Available peer fingerprints: \(peerFingerprints.keys.map { $0.prefix(8) })")
        
        guard let peerID = peerFingerprints[fingerprint] else {
            print("📝 Queuing invitation for offline peer (\(fingerprint.prefix(8)))")
            print("❌ No peerID found for fingerprint - peer might be offline")
            return
        }
        
        print("🔍 Found peerID \(peerID) for fingerprint \(fingerprint.prefix(8))")
        
        // Send via Noise transport using the group invitation payload type
        Task { @MainActor in
            if let router = messageRouter {
                print("🔍 MessageRouter available, sending invitation...")
                router.sendGroupInvitation(invitation, to: peerID)
                print("📤 Sent group invitation via Noise transport to \(peerID)")
            } else {
                print("❌ Message router not available for sending invitation")
            }
        }
    }
    
    /// Send invitation response
    private func sendInvitationResponse(invitationID: String, accepted: Bool, to fingerprint: String) {
        guard let peerID = peerFingerprints[fingerprint] else { 
            print("❌ Cannot send invitation response: peer offline (\(fingerprint.prefix(8)))")
            return 
        }
        
        // Send via Noise transport using the group invite response payload type
        Task { @MainActor in
            if let router = messageRouter {
                router.sendGroupInviteResponse(invitationID: invitationID, accepted: accepted, to: peerID)
                print("📤 Sent group invitation response (\(accepted ? "accepted" : "declined")) to \(peerID)")
            } else {
                print("❌ Message router not available for sending response")
            }
        }
    }
    
    // MARK: - Utility Methods
    
    /// Mark group as read
    func markGroupAsRead(groupID: String) {
        guard var group = groupChats[groupID] else { return }
        group.markAsRead()
        DispatchQueue.main.async { [weak self] in
            self?.groupChats[groupID] = group
        }
        saveGroupChats()
    }
    
    /// Get group by ID
    func getGroup(groupID: String) -> GroupChat? {
        return groupChats[groupID]
    }
    
    /// Get all groups sorted by last activity
    func getAllGroups() -> [GroupChat] {
        return groupChats.values.sorted { $0.lastActivity > $1.lastActivity }
    }
    
    /// Clear all groups (for panic mode)
    func clearAllGroups() {
        DispatchQueue.main.async { [weak self] in
            self?.groupChats.removeAll()
            self?.selectedGroupID = nil
            self?.pendingInvitations.removeAll()
            self?.sentInvitations.removeAll()
            self?.onlinePeers.removeAll()
            self?.peerFingerprints.removeAll()
        }
        
        userDefaults.removeObject(forKey: groupChatsKey)
        userDefaults.removeObject(forKey: selectedGroupKey)
        userDefaults.removeObject(forKey: pendingInvitationsKey)
        userDefaults.removeObject(forKey: sentInvitationsKey)
        userDefaults.synchronize()
        
        print("🧹 Cleared all group chats")
    }
}
