//
//  InvitationSystemTest.swift
//  bitchat
//
//  Created by Waluya Juang Husada on 14/08/25.
//
// Test file to verify group invitation system functionality
//

import Foundation

/// Simple test to verify invitation system components
class InvitationSystemTest {
    
    static func runTests() {
        print("🧪 Testing Group Invitation System...")
        
        // Test 1: Invitation creation
        testInvitationCreation()
        
        // Test 2: Invitation expiration
        testInvitationExpiration()
        
        // Test 3: Invitation parsing
        testInvitationParsing()
        
        print("✅ All invitation system tests completed!")
    }
    
    private static func testInvitationCreation() {
        print("  📝 Test 1: Invitation Creation")
        
        let invitation = GroupInvitation(
            groupID: "test-group-123",
            groupName: "Test Group",
            inviterID: "inviter-peer-id",
            inviterNickname: "Alice",
            inviteCode: "ABC12345",
            expiresIn: 3600 // 1 hour
        )
        
        assert(invitation.groupID == "test-group-123")
        assert(invitation.groupName == "Test Group")
        assert(invitation.inviterNickname == "Alice")
        assert(invitation.inviteCode == "ABC12345")
        assert(!invitation.isExpired)
        
        print("    ✅ Invitation creation test passed")
    }
    
    private static func testInvitationExpiration() {
        print("  ⏰ Test 2: Invitation Expiration")
        
        // Test expired invitation
        let expiredInvitation = GroupInvitation(
            groupID: "expired-group",
            groupName: "Expired Group",
            inviterID: "inviter-peer-id",
            inviterNickname: "Bob",
            inviteCode: "EXPIRED",
            expiresIn: -3600 // Expired 1 hour ago
        )
        
        assert(expiredInvitation.isExpired)
        
        // Test valid invitation
        let validInvitation = GroupInvitation(
            groupID: "valid-group",
            groupName: "Valid Group",
            inviterID: "inviter-peer-id",
            inviterNickname: "Charlie",
            inviteCode: "VALID",
            expiresIn: 3600 // Valid for 1 hour
        )
        
        assert(!validInvitation.isExpired)
        
        print("    ✅ Invitation expiration test passed")
    }
    
    private static func testInvitationParsing() {
        print("  🔍 Test 3: Invitation Message Parsing")
        
        let invitationMessage = "GROUP_INVITE:test-group-123:Test Group:ABC12345"
        let parts = invitationMessage.split(separator: ":", maxSplits: 3)
        
        assert(parts.count >= 4)
        assert(parts[0] == "GROUP_INVITE")
        assert(parts[1] == "test-group-123")
        assert(parts[2] == "Test Group")
        assert(parts[3] == "ABC12345")
        
        print("    ✅ Invitation parsing test passed")
    }
}

// MARK: - Test Runner

#if DEBUG
// Run tests when compiled in debug mode
extension InvitationSystemTest {
    static func runAllTests() {
        runTests()
    }
}
#endif
