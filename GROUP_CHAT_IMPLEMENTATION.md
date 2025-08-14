# Group Chat Implementation for BitChat

This document describes the implementation of group chat functionality for the BitChat application.

## Overview

The group chat feature allows users to create groups, invite members, and send messages to all group members. The implementation leverages the existing mesh networking infrastructure and extends it to support group-based communication.

## Architecture

### Core Components

1. **GroupPersistenceService** - Manages group data persistence and operations
2. **Group-related data structures** - BitchatGroup, GroupInvitation, GroupMember
3. **MessageRouter extensions** - Handles group message routing
4. **ChatViewModel extensions** - Group chat UI logic
5. **UI Components** - GroupCreationView, GroupManagementView, etc.

### Data Structures

#### BitchatGroup
```swift
struct BitchatGroup: Codable, Identifiable, Equatable {
    let id: String                    // Unique group identifier
    let name: String                  // Group display name
    let creatorID: String             // Who created the group
    let memberIDs: Set<String>        // Current members
    let adminIDs: Set<String>         // Group administrators
    let createdAt: Date
    let isPrivate: Bool               // Private vs public group
    let inviteCode: String?           // For private group invites
    let description: String?          // Optional group description
}
```

#### GroupInvitation
```swift
struct GroupInvitation: Codable {
    let groupID: String
    let groupName: String
    let inviterID: String
    let inviterNickname: String
    let inviteCode: String
    let timestamp: Date
    let expiresAt: Date
}
```

#### GroupMember
```swift
struct GroupMember: Codable, Identifiable, Equatable {
    let id: String                    // Peer ID
    let nickname: String
    let joinedAt: Date
    let isAdmin: Bool
    let isCreator: Bool
}
```

## Protocol Extensions

### New Message Types
The protocol has been extended with new message types for group functionality:

- `groupCreate = 0x40` - Create a new group
- `groupInvite = 0x41` - Invite someone to group
- `groupJoin = 0x42` - Accept group invitation
- `groupLeave = 0x43` - Leave group
- `groupMessage = 0x44` - Message sent to group
- `groupMemberAdd = 0x45` - Add member to group
- `groupMemberRemove = 0x46` - Remove member from group
- `groupUpdate = 0x47` - Update group settings

### Message Format
Group messages use structured content with prefixes:

- **Group Invitation**: `GROUP_INVITE:<groupID>:<groupName>:<inviteCode>`
- **Group Message**: `GROUP_MSG:<groupID>:<groupName>:<content>`
- **Group Update**: `GROUP_UPDATE:<updateType>:<groupID>:<groupName>:<memberID>:<memberNickname>`

## Key Features

### 1. Group Creation
- Users can create groups with a name and optional description
- Groups can be public or private
- Private groups generate invite codes
- Creator automatically becomes admin

### 2. Member Management
- Add/remove members (creators cannot be removed)
- Promote/demote admins
- Automatic system messages for member changes

### 3. Invitation System
- Send invitations via mesh network or Nostr
- Invitations expire after 24 hours
- Users can accept/decline invitations

### 4. Message Routing
- Group messages are sent to all members
- Uses existing transport infrastructure (mesh/Nostr)
- Automatic delivery status tracking

### 5. UI Integration
- Groups appear in sidebar with member count
- Group chat interface similar to private chats
- Group management interface for admins

## Implementation Details

### Group Persistence
Groups are stored using UserDefaults with the following keys:
- `chat.bitchat.groups` - Group data
- `chat.bitchat.groups.chats` - Group message history
- `chat.bitchat.groups.invitations` - Pending invitations

### Message Handling
Group messages are processed in the `didReceiveMessage` method of ChatViewModel:

```swift
} else if message.content.hasPrefix("GROUP_INVITE:") {
    // Handle group invitation
} else if message.content.hasPrefix("GROUP_MSG:") {
    // Handle group message
} else if message.content.hasPrefix("GROUP_UPDATE:") {
    // Handle group member update
}
```

### Transport Layer
Group messages use the existing transport infrastructure:
- **Mesh Network**: Direct delivery when peers are connected
- **Nostr**: For offline mutual favorites
- **Fallback**: System messages for unreachable peers

## Security Considerations

1. **Invitation Validation**: Invite codes are required for private groups
2. **Permission Levels**: Only admins can add/remove members
3. **Creator Protection**: Group creators cannot be removed
4. **Message Encryption**: Group messages use the same encryption as private messages

## Usage Examples

### Creating a Group
```swift
viewModel.createGroup(
    name: "My Group",
    initialMembers: ["peer1", "peer2"],
    isPrivate: true,
    description: "A private group"
)
```

### Sending a Group Message
```swift
viewModel.sendGroupMessage("Hello everyone!", to: groupID)
```

### Inviting a Peer
```swift
viewModel.invitePeerToGroup(peerID, groupID: groupID, groupName: groupName)
```

## Testing

Basic tests are included in `GroupChatTests.swift` covering:
- Group creation
- Member management
- Invitation handling
- Data structure validation

## Future Enhancements

1. **Group Encryption**: End-to-end encryption for group messages
2. **File Sharing**: Support for sharing files in groups
3. **Group Roles**: More granular permission system
4. **Group Discovery**: Public group directory
5. **Message Reactions**: Like/react to group messages

## Integration Notes

The group chat implementation is designed to work seamlessly with the existing BitChat infrastructure:

- Uses existing peer discovery and connection management
- Leverages current message routing and delivery systems
- Integrates with the existing UI patterns and navigation
- Maintains compatibility with private messages and public chat

The implementation follows the same offline-first, decentralized principles as the rest of the application.
