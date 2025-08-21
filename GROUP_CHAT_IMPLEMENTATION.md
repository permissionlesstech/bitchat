# Group Chat Implementation

This document describes the group chat functionality that has been added to BitChat.

## Overview

The group chat feature allows users to create and participate in multi-user chat rooms while maintaining the same security and decentralization principles as the existing private chat system.

## Architecture

### Core Components

#### 1. Models (`bitchat/Models/GroupChat.swift`)
- **`GroupChat`**: Main model representing a group chat room
  - Supports multiple members with different roles (admin/member)
  - Tracks online/offline status of members
  - Handles message persistence and pending messages
  - Supports both public and private groups

- **`GroupMember`**: Represents individual members in a group
  - Tracks member status, role, and last seen time
  - Handles nickname updates and online status

- **`GroupInvitation`**: Manages group invitations
  - Tracks invitation status (pending/accepted/declined/expired)
  - Contains group and inviter information

#### 2. Services (`bitchat/Services/GroupChatManager.swift`)
- **`GroupChatManager`**: Central service for group chat operations
  - Group creation, deletion, and management
  - Member management (add/remove/promote)
  - Message routing to group members
  - Invitation system
  - Persistence to UserDefaults
  - Online/offline peer tracking

#### 3. Protocol Extensions
- **`BitchatProtocol.swift`**: Extended with group message types
  - New noise payload types for group operations
  - Group message update structures
  - BitchatDelegate methods for group events

- **`Transport.swift`**: Extended with group messaging methods
  - Group message sending
  - Group invitation handling
  - Member update broadcasting

#### 4. View Models
- **`ChatViewModel.swift`**: Extended with group chat functionality
  - Group creation and management methods
  - Integration with GroupChatManager
  - Group chat delegate implementations
  - UI state management for groups

#### 5. User Interface

##### GroupChatListView (`bitchat/Views/GroupChatListView.swift`)
- Lists all user's group chats
- Shows group status, member count, and unread messages
- Group creation interface
- Invitation management

##### GroupChatView (`bitchat/Views/GroupChatView.swift`)
- Main group chat interface
- Real-time messaging with multiple participants
- Member list and group info access
- Invitation system for adding new members

##### ContentView Integration
- Added group chat navigation to sidebar
- Group chat sheets and full-screen presentations
- Unread message badges for groups

## Features

### Group Management
- **Create Groups**: Users can create public or private groups
- **Group Information**: Editable group name and description (admin only)
- **Member Management**: Add/remove members, promote to admin
- **Group Types**: Public (discoverable) and Private (invitation-only)

### Messaging
- **Real-time Messaging**: Messages sent to all online group members
- **Offline Message Queue**: Messages queued for offline members
- **Message Persistence**: All group messages saved locally
- **Delivery Status**: Track message delivery across group members
- **Mentions**: @username mentions within group messages

### Invitation System
- **Send Invitations**: Admins can invite connected peers
- **Accept/Decline**: Users can manage incoming invitations
- **Invitation Tracking**: Track sent and received invitations
- **Automatic Cleanup**: Handle expired invitations

### Security & Privacy
- **Fingerprint-based Identity**: Groups tied to user fingerprints
- **Admin Controls**: Only admins can manage group settings
- **Creator Protection**: Group creators cannot be removed
- **Encrypted Transport**: Group messages use same encryption as private messages

## Protocol Integration

### Message Types
New noise payload types added:
- `groupMessage` (0x10): Regular group chat messages
- `groupInvitation` (0x11): Group invitations
- `groupInviteResponse` (0x12): Invitation responses
- `groupMemberUpdate` (0x13): Member join/leave/promotion events
- `groupInfoUpdate` (0x14): Group name/description changes
- `groupKeyExchange` (0x15): Future: Group encryption key exchange

### Network Transport
- Group messages sent individually to each member (multicast)
- Leverages existing noise encryption for security
- Automatic retry for offline members when they come online
- Integration with existing message routing (BLE/Nostr)

## Data Persistence

### Local Storage
- Groups stored in UserDefaults as JSON
- Separate storage for invitations (sent/received)
- Message history persisted per group
- Group selection state maintained across app restarts

### Data Structures
- Groups indexed by unique group ID
- Members indexed by fingerprint within groups
- Messages stored chronologically per group
- Pending messages queued separately

## User Experience

### Navigation
- Groups accessible from main sidebar
- "View All Groups" button with unread count badge
- Recent groups (top 3) shown in sidebar
- Group invitations badge in sidebar

### Group Chat Interface
- Chat-style messaging interface
- Member count and online status display
- Group info and member management
- Invite new members functionality

### Notifications
- Unread message counts per group
- Total unread count across all groups
- Invitation notification badges
- System messages for group events

## Integration Points

### Existing Systems
- **PeerService**: Uses existing peer discovery and connection
- **NoiseEncryption**: Leverages existing encryption infrastructure
- **MessageRouter**: Integrates with BLE/Nostr message routing
- **Identity**: Uses existing fingerprint-based identity system

### Future Enhancements
- **Group Encryption**: Dedicated group encryption keys
- **File Sharing**: Share files within groups
- **Group Discovery**: Public group discovery mechanism
- **Advanced Permissions**: More granular permission system
- **Group Avatars**: Custom group profile images

## Usage

### Creating a Group
1. Open sidebar → Groups → "View All Groups"
2. Tap "+" button to create new group
3. Enter group name, optional description
4. Choose public/private setting
5. Group is created with user as admin

### Joining a Group
1. Receive invitation notification
2. Open sidebar → Groups (invitation badge visible)
3. Tap envelope icon to view invitations
4. Accept or decline invitations

### Group Messaging
1. Select group from sidebar or group list
2. Send messages like normal chat
3. See all members and their online status
4. Mention users with @username

### Managing Groups
1. Open group chat → tap group name
2. View group info, edit details (admin only)
3. View/manage members
4. Invite new members from connected peers

## Technical Notes

### Performance Considerations
- Group message sending scales linearly with member count
- Message deduplication prevents duplicate delivery
- Lazy loading of UI components for large member lists
- Efficient state management with published properties

### Error Handling
- Graceful handling of offline members
- Invitation expiration management
- Permission validation for admin actions
- Network failure recovery

### Testing
- Unit tests can be added for GroupChatManager
- UI tests for group creation and messaging flows
- Integration tests for multi-peer group scenarios
- Performance tests for large groups

This implementation provides a solid foundation for group chat functionality while maintaining the security, privacy, and decentralized nature of the BitChat application.
