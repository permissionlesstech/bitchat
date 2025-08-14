import XCTest
@testable import bitchat

class SimpleGroupTest: XCTestCase {
    
    func testBasicGroupCreation() {
        // Test that we can create a basic group structure
        let group = BitchatGroup(
            name: "Test Group",
            creatorID: "test-creator"
        )
        
        XCTAssertEqual(group.name, "Test Group")
        XCTAssertEqual(group.creatorID, "test-creator")
        XCTAssertTrue(group.memberIDs.contains("test-creator"))
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
    }
}
