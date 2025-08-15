import Foundation
import Combine

/// Manages persistent group data and operations
@MainActor
public class GroupPersistenceService: ObservableObject {
    
    private static let storageKey = "chat.bitchat.groups"
    private static let keychainService = "chat.bitchat.groups"
    
    @Published private(set) var groups: [String: BitchatGroup] = [:] // groupID -> group
    @Published private(set) var groupChats: [String: [BitchatMessage]] = [:] // groupID -> messages
    @Published private var _pendingInvitations: [String: GroupInvitation] = [:] // groupID -> invitation
    
    private let userDefaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()
    
    public static let shared = GroupPersistenceService()
    
    private init() {
        loadGroups()
        loadGroupChats()
        loadPendingInvitations()
    }
    
    // MARK: - Group Management
    
    /// Create a new group
    func createGroup(name: String, creatorID: String, initialMembers: Set<String> = [], isPrivate: Bool = false, description: String? = nil) -> BitchatGroup {
        let inviteCode = isPrivate ? generateInviteCode() : nil
        let group = BitchatGroup(
            name: name,
            creatorID: creatorID,
            memberIDs: initialMembers.union([creatorID]), // Creator is always a member
            adminIDs: [creatorID], // Creator is always an admin
            isPrivate: isPrivate,
            inviteCode: inviteCode,
            description: description
        )
        
        groups[group.id] = group
        groupChats[group.id] = []
        saveGroups()
        saveGroupChats()
        
        SecureLogger.log("📱 Created group '\(name)' with \(group.memberIDs.count) members",
                        category: SecureLogger.session, level: .info)
        
        return group
    }
    
    /// Create a group with a specific ID (for accepting invitations)
    func createGroupWithID(id: String, name: String, creatorID: String, memberIDs: Set<String> = [], adminIDs: Set<String> = [], isPrivate: Bool = false, inviteCode: String? = nil, description: String? = nil) -> BitchatGroup {
        let group = BitchatGroup(
            id: id,
            name: name,
            creatorID: creatorID,
            memberIDs: memberIDs,
            adminIDs: adminIDs,
            isPrivate: isPrivate,
            inviteCode: inviteCode,
            description: description
        )
        
        groups[id] = group
        groupChats[id] = []
        saveGroups()
        saveGroupChats()
        
        SecureLogger.log("📱 Created group '\(name)' with ID \(id) and \(group.memberIDs.count) members",
                        category: SecureLogger.session, level: .info)
        
        return group
    }
    
    /// Get a group by ID
    func getGroup(_ groupID: String) -> BitchatGroup? {
        return groups[groupID]
    }
    
    /// Get all groups for a peer
    func getGroupsForPeer(_ peerID: String) -> [BitchatGroup] {
        return groups.values.filter { group in
            group.memberIDs.contains(peerID)
        }
    }
    
    /// Update group information
    func updateGroup(_ group: BitchatGroup) {
        groups[group.id] = group
        saveGroups()
        
        SecureLogger.log("📱 Updated group '\(group.name)'",
                        category: SecureLogger.session, level: .info)
    }
    
    /// Delete a group
    func deleteGroup(_ groupID: String) {
        groups.removeValue(forKey: groupID)
        groupChats.removeValue(forKey: groupID)
        saveGroups()
        saveGroupChats()
        
        SecureLogger.log("📱 Deleted group \(groupID)",
                        category: SecureLogger.session, level: .info)
    }
    
    // MARK: - Member Management
    
    /// Add a member to a group
    func addMember(_ peerID: String, to groupID: String, nickname: String) -> Bool {
        guard var group = groups[groupID] else { return false }
        
        // Check if already a member
        if group.memberIDs.contains(peerID) {
            return false
        }
        
        var newMemberIDs = group.memberIDs
        newMemberIDs.insert(peerID)
        
        let updatedGroup = BitchatGroup(
            id: group.id,
            name: group.name,
            creatorID: group.creatorID,
            memberIDs: newMemberIDs,
            adminIDs: group.adminIDs,
            isPrivate: group.isPrivate,
            inviteCode: group.inviteCode,
            description: group.description
        )
        
        groups[groupID] = updatedGroup
        saveGroups()
        
        // Add system message to group chat
        let systemMessage = BitchatMessage(
            sender: "system",
            content: "\(nickname) joined the group",
            timestamp: Date(),
            isRelay: false,
            isPrivate: false
        )
        addMessageToGroup(systemMessage, groupID: groupID)
        
        SecureLogger.log("📱 Added \(nickname) to group '\(group.name)'",
                        category: SecureLogger.session, level: .info)
        
        return true
    }
    
    /// Remove a member from a group
    func removeMember(_ peerID: String, from groupID: String, nickname: String) -> Bool {
        guard var group = groups[groupID] else { return false }
        
        // Creator cannot be removed
        if peerID == group.creatorID {
            return false
        }
        
        var newMemberIDs = group.memberIDs
        newMemberIDs.remove(peerID)
        
        var newAdminIDs = group.adminIDs
        newAdminIDs.remove(peerID)
        
        let updatedGroup = BitchatGroup(
            id: group.id,
            name: group.name,
            creatorID: group.creatorID,
            memberIDs: newMemberIDs,
            adminIDs: newAdminIDs,
            isPrivate: group.isPrivate,
            inviteCode: group.inviteCode,
            description: group.description
        )
        
        groups[groupID] = updatedGroup
        saveGroups()
        
        // Add system message to group chat
        let systemMessage = BitchatMessage(
            sender: "system",
            content: "\(nickname) left the group",
            timestamp: Date(),
            isRelay: false,
            isPrivate: false
        )
        addMessageToGroup(systemMessage, groupID: groupID)
        
        SecureLogger.log("📱 Removed \(nickname) from group '\(group.name)'",
                        category: SecureLogger.session, level: .info)
        
        return true
    }
    
    /// Promote a member to admin
    func promoteToAdmin(_ peerID: String, in groupID: String) -> Bool {
        guard var group = groups[groupID] else { return false }
        
        // Must be a member to be promoted
        if !group.memberIDs.contains(peerID) {
            return false
        }
        
        var newAdminIDs = group.adminIDs
        newAdminIDs.insert(peerID)
        
        let updatedGroup = BitchatGroup(
            id: group.id,
            name: group.name,
            creatorID: group.creatorID,
            memberIDs: group.memberIDs,
            adminIDs: newAdminIDs,
            isPrivate: group.isPrivate,
            inviteCode: group.inviteCode,
            description: group.description
        )
        
        groups[groupID] = updatedGroup
        saveGroups()
        
        return true
    }
    
    /// Demote an admin to regular member
    func demoteFromAdmin(_ peerID: String, in groupID: String) -> Bool {
        guard var group = groups[groupID] else { return false }
        
        // Creator cannot be demoted
        if peerID == group.creatorID {
            return false
        }
        
        var newAdminIDs = group.adminIDs
        newAdminIDs.remove(peerID)
        
        let updatedGroup = BitchatGroup(
            id: group.id,
            name: group.name,
            creatorID: group.creatorID,
            memberIDs: group.memberIDs,
            adminIDs: newAdminIDs,
            isPrivate: group.isPrivate,
            inviteCode: group.inviteCode,
            description: group.description
        )
        
        groups[groupID] = updatedGroup
        saveGroups()
        
        return true
    }
    
    // MARK: - Group Chat Management
    
    /// Add a message to a group chat
    func addMessageToGroup(_ message: BitchatMessage, groupID: String) {
        if groupChats[groupID] == nil {
            groupChats[groupID] = []
        }
        groupChats[groupID]?.append(message)
        
        // Keep only last 1000 messages per group
        if let messages = groupChats[groupID], messages.count > 1000 {
            groupChats[groupID] = Array(messages.suffix(1000))
        }
        
        saveGroupChats()
    }
    
    /// Get messages for a group
    func getGroupMessages(_ groupID: String) -> [BitchatMessage] {
        return groupChats[groupID] ?? []
    }
    
    /// Clear group chat history
    func clearGroupChat(_ groupID: String) {
        groupChats[groupID] = []
        saveGroupChats()
    }
    
    // MARK: - Invitation Management
    
    /// Store a pending invitation
    func storeInvitation(_ invitation: GroupInvitation) {
        SecureLogger.log("📱 About to store invitation for group '\(invitation.groupName)' (ID: \(invitation.groupID))",
                        category: SecureLogger.session, level: .info)
        
        _pendingInvitations[invitation.groupID] = invitation
        savePendingInvitations()
        
        SecureLogger.log("📱 Stored invitation for group '\(invitation.groupName)' - total invitations: \(_pendingInvitations.count)",
                        category: SecureLogger.session, level: .info)
        
        // Force UI update by triggering objectWillChange
        objectWillChange.send()
    }
    
    /// Get a pending invitation
    func getPendingInvitation(_ groupID: String) -> GroupInvitation? {
        // Clean up expired invitations first
        cleanupExpiredInvitations()
        return _pendingInvitations[groupID]
    }
    
    /// Remove a pending invitation
    func removeInvitation(_ groupID: String) {
        _pendingInvitations.removeValue(forKey: groupID)
        savePendingInvitations()
    }
    
    /// Clean up expired invitations
    func cleanupExpiredInvitations() {
        let expiredGroupIDs = _pendingInvitations.compactMap { groupID, invitation in
            invitation.isExpired ? groupID : nil
        }
        
        if !expiredGroupIDs.isEmpty {
            for groupID in expiredGroupIDs {
                _pendingInvitations.removeValue(forKey: groupID)
                SecureLogger.log("📱 Removed expired invitation for group \(groupID)",
                                category: SecureLogger.session, level: .info)
            }
            
            // Trigger UI update by saving
            savePendingInvitations()
        }
    }
    
    /// Get all pending invitations (with expired cleanup)
    var pendingInvitations: [String: GroupInvitation] {
        get {
            // Clean up expired invitations before returning
            cleanupExpiredInvitations()
            return _pendingInvitations
        }
        set {
            _pendingInvitations = newValue
            savePendingInvitations()
        }
    }
    
    /// Validate an invite code
    func validateInviteCode(_ code: String, for groupID: String) -> Bool {
        guard let group = groups[groupID] else { return false }
        return group.inviteCode == code
    }
    
    // MARK: - Utility Methods
    
    /// Generate a random invite code
    private func generateInviteCode() -> String {
        let characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<8).map { _ in characters.randomElement()! })
    }
    
    /// Check if a peer is a member of a group
    func isMember(_ peerID: String, of groupID: String) -> Bool {
        return groups[groupID]?.memberIDs.contains(peerID) ?? false
    }
    
    /// Check if a peer is an admin of a group
    func isAdmin(_ peerID: String, of groupID: String) -> Bool {
        guard let group = groups[groupID] else { return false }
        return group.adminIDs.contains(peerID) || group.creatorID == peerID
    }
    
    /// Check if a peer is the creator of a group
    func isCreator(_ peerID: String, of groupID: String) -> Bool {
        return groups[groupID]?.creatorID == peerID
    }
    
    // MARK: - Persistence
    
    private func loadGroups() {
        if let data = userDefaults.data(forKey: GroupPersistenceService.storageKey),
           let decodedGroups = try? JSONDecoder().decode([String: BitchatGroup].self, from: data) {
            groups = decodedGroups
        }
    }
    
    private func saveGroups() {
        if let encoded = try? JSONEncoder().encode(groups) {
            userDefaults.set(encoded, forKey: GroupPersistenceService.storageKey)
        }
    }
    
    private func loadGroupChats() {
        if let data = userDefaults.data(forKey: "\(GroupPersistenceService.storageKey).chats"),
           let decodedChats = try? JSONDecoder().decode([String: [BitchatMessage]].self, from: data) {
            groupChats = decodedChats
        }
    }
    
    private func saveGroupChats() {
        if let encoded = try? JSONEncoder().encode(groupChats) {
            userDefaults.set(encoded, forKey: "\(GroupPersistenceService.storageKey).chats")
        }
    }
    
    private func loadPendingInvitations() {
        if let data = userDefaults.data(forKey: "\(GroupPersistenceService.storageKey).invitations"),
           let decodedInvitations = try? JSONDecoder().decode([String: GroupInvitation].self, from: data) {
            _pendingInvitations = decodedInvitations
        }
    }
    
    private func savePendingInvitations() {
        if let encoded = try? JSONEncoder().encode(_pendingInvitations) {
            userDefaults.set(encoded, forKey: "\(GroupPersistenceService.storageKey).invitations")
        }
    }
}
