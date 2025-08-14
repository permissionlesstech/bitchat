import XCTest
@testable import bitchat

class GroupChatTests: XCTestCase {
    
    var groupService: GroupPersistenceService!
    
    override func setUp() {
        super.setUp()
        groupService = GroupPersistenceService.shared
    }
    
    override func tearDown() {
        // Clear any test data
        super.tearDown()
    }
    
    func testGroupStructures() {
        // Test basic group structure
        let group = BitchatGroup(
            name: "Test Group",
            creatorID: "test-creator",
            memberIDs: ["member1", "member2"],
            adminIDs: ["admin1"],
            isPrivate: false,
            description: "A test group"
        )
        
        XCTAssertEqual(group.name, "Test Group")
        XCTAssertEqual(group.creatorID, "test-creator")
        XCTAssertEqual(group.memberIDs.count, 2)
        XCTAssertTrue(group.memberIDs.contains("member1"))
        XCTAssertTrue(group.memberIDs.contains("member2"))
        XCTAssertFalse(group.isPrivate)
        XCTAssertEqual(group.description, "A test group")
    }
    
    func testGroupInvitation() {
        let invitation = GroupInvitation(
            groupID: "test-group",
            groupName: "Test Group",
            inviterID: "test-inviter",
            inviterNickname: "Test Inviter",
            inviteCode: "ABC123"
        )
        
        XCTAssertEqual(invitation.groupID, "test-group")
        XCTAssertEqual(invitation.groupName, "Test Group")
        XCTAssertEqual(invitation.inviterID, "test-inviter")
        XCTAssertEqual(invitation.inviterNickname, "Test Inviter")
        XCTAssertEqual(invitation.inviteCode, "ABC123")
        XCTAssertFalse(invitation.isExpired)
    }
    
    func testGroupMember() {
        let member = GroupMember(
            id: "test-member",
            nickname: "Test Member",
            isAdmin: true,
            isCreator: false
        )
        
        XCTAssertEqual(member.id, "test-member")
        XCTAssertEqual(member.nickname, "Test Member")
        XCTAssertTrue(member.isAdmin)
        XCTAssertFalse(member.isCreator)
    }
    
    func testCreateGroup() {
        // Test creating a group
        let group = groupService.createGroup(
            name: "Test Group",
            creatorID: "test-creator",
            initialMembers: ["member1", "member2"],
            isPrivate: false,
            description: "A test group"
        )
        
        XCTAssertEqual(group.name, "Test Group")
        XCTAssertEqual(group.creatorID, "test-creator")
        XCTAssertEqual(group.memberIDs.count, 3) // creator + 2 members
        XCTAssertTrue(group.memberIDs.contains("test-creator"))
        XCTAssertTrue(group.memberIDs.contains("member1"))
        XCTAssertTrue(group.memberIDs.contains("member2"))
        XCTAssertFalse(group.isPrivate)
        XCTAssertEqual(group.description, "A test group")
    }
    
    func testAddMember() {
        // Create a group first
        let group = groupService.createGroup(
            name: "Test Group",
            creatorID: "test-creator"
        )
        
        // Add a member
        let success = groupService.addMember("new-member", to: group.id, nickname: "New Member")
        
        XCTAssertTrue(success)
        
        // Verify member was added
        let updatedGroup = groupService.getGroup(group.id)
        XCTAssertNotNil(updatedGroup)
        XCTAssertTrue(updatedGroup!.memberIDs.contains("new-member"))
    }
    
    func testRemoveMember() {
        // Create a group with members
        let group = groupService.createGroup(
            name: "Test Group",
            creatorID: "test-creator",
            initialMembers: ["member1"]
        )
        
        // Remove a member
        let success = groupService.removeMember("member1", from: group.id, nickname: "Member 1")
        
        XCTAssertTrue(success)
        
        // Verify member was removed
        let updatedGroup = groupService.getGroup(group.id)
        XCTAssertNotNil(updatedGroup)
        XCTAssertFalse(updatedGroup!.memberIDs.contains("member1"))
        XCTAssertTrue(updatedGroup!.memberIDs.contains("test-creator")) // Creator should remain
    }
    
    func testCannotRemoveCreator() {
        // Create a group
        let group = groupService.createGroup(
            name: "Test Group",
            creatorID: "test-creator"
        )
        
        // Try to remove the creator
        let success = groupService.removeMember("test-creator", from: group.id, nickname: "Creator")
        
        XCTAssertFalse(success)
        
        // Verify creator is still there
        let updatedGroup = groupService.getGroup(group.id)
        XCTAssertNotNil(updatedGroup)
        XCTAssertTrue(updatedGroup!.memberIDs.contains("test-creator"))
    }
}
