//
//  GroupChatListView.swift
//  bitchat
//
//  Created by Waluya Juang Husada on 21/08/25.
//


//
// GroupChatListView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct GroupChatListView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    @State private var showCreateGroupSheet = false
    @State private var showInvitationsSheet = false
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header with actions
                HStack {
                    Text("Group Chats")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(textColor)
                    
                    Spacer()
                    
                    // Invitations button with badge
                    Button(action: {
                        showInvitationsSheet = true
                    }) {
                        ZStack {
                            Image(systemName: "envelope")
                                .font(.title2)
                                .foregroundColor(textColor)
                            
                            if viewModel.pendingInvitationsCount > 0 {
                                Text("\(viewModel.pendingInvitationsCount)")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(Color.red)
                                    .clipShape(Circle())
                                    .offset(x: 8, y: -8)
                            }
                        }
                    }
                    
                    // Create group button
                    Button(action: {
                        showCreateGroupSheet = true
                    }) {
                        Image(systemName: "plus.circle")
                            .font(.title2)
                            .foregroundColor(textColor)
                    }
                }
                .padding()
                
                Divider()
                    .background(textColor.opacity(0.3))
                
                // Group list
                if viewModel.groupChats.isEmpty {
                    // Empty state
                    VStack(spacing: 16) {
                        Image(systemName: "person.3")
                            .font(.system(size: 60))
                            .foregroundColor(secondaryTextColor)
                        
                        Text("No Group Chats")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(textColor)
                        
                        Text("Create a group to start chatting with multiple people")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        Button(action: {
                            showCreateGroupSheet = true
                        }) {
                            Text("Create Group")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .background(textColor)
                                .cornerRadius(10)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Group list
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(viewModel.groupChats, id: \.id) { group in
                                GroupChatRowView(group: group)
                                    .environmentObject(viewModel)
                                    .background(backgroundColor)
                                    .onTapGesture {
                                        viewModel.joinGroup(group.id)
                                    }
                            }
                        }
                    }
                }
                
                Spacer()
            }
            .background(backgroundColor)
            .sheet(isPresented: $showCreateGroupSheet) {
                CreateGroupView()
                    .environmentObject(viewModel)
            }
            .sheet(isPresented: $showInvitationsSheet) {
                GroupInvitationsView()
                    .environmentObject(viewModel)
            }
        }
    }
}

struct GroupChatRowView: View {
    let group: GroupChat
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Group avatar/icon
            ZStack {
                Circle()
                    .fill(textColor.opacity(0.2))
                    .frame(width: 50, height: 50)
                
                Text(String(group.groupName.prefix(1).uppercased()))
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(textColor)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(group.displayName)
                        .font(.headline)
                        .foregroundColor(textColor)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    // Status indicator
                    Text(group.statusIndicator)
                        .font(.caption)
                    
                    // Last activity time
                    Text(formatRelativeTime(group.lastActivity))
                        .font(.caption)
                        .foregroundColor(secondaryTextColor)
                }
                
                HStack {
                    Text(group.statusText)
                        .font(.caption)
                        .foregroundColor(secondaryTextColor)
                    
                    Spacer()
                    
                    // Unread count badge
                    if group.unreadCount > 0 {
                        Text("\(group.unreadCount)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red)
                            .cornerRadius(10)
                    }
                }
                
                // Last message preview
                if let lastMessage = group.messages.last {
                    Text("\(lastMessage.sender): \(lastMessage.content)")
                        .font(.caption)
                        .foregroundColor(secondaryTextColor)
                        .lineLimit(1)
                } else if !group.pendingMessages.isEmpty {
                    Text("Pending messages...")
                        .font(.caption)
                        .foregroundColor(secondaryTextColor)
                        .italic()
                } else {
                    Text("No messages yet")
                        .font(.caption)
                        .foregroundColor(secondaryTextColor)
                        .italic()
                }
            }
            
            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(colorScheme == .dark ? Color.gray.opacity(0.1) : Color.gray.opacity(0.05))
        )
        .padding(.horizontal)
        .padding(.vertical, 2)
    }
    
    private func formatRelativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct CreateGroupView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.colorScheme) var colorScheme
    
    @State private var groupName = ""
    @State private var groupDescription = ""
    @State private var isPrivate = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Create Group")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(textColor)
                    .padding(.top)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Group Name")
                        .font(.headline)
                        .foregroundColor(textColor)
                    
                    TextField("Enter group name", text: $groupName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .foregroundColor(textColor)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Description (Optional)")
                        .font(.headline)
                        .foregroundColor(textColor)
                    
                    TextField("Enter group description", text: $groupDescription, axis: .vertical)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .foregroundColor(textColor)
                        .lineLimit(3...6)
                }
                
                Toggle(isOn: $isPrivate) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Private Group")
                            .font(.headline)
                            .foregroundColor(textColor)
                        
                        Text("Only invited members can join")
                            .font(.caption)
                            .foregroundColor(textColor.opacity(0.8))
                    }
                }
                .tint(textColor)
                
                Spacer()
                
                // Action buttons
                HStack(spacing: 16) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .font(.headline)
                    .foregroundColor(textColor)
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(10)
                    
                    Button("Create") {
                        createGroup()
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .background(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : textColor)
                    .cornerRadius(10)
                    .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
            .background(backgroundColor)
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private func createGroup() {
        let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedName.isEmpty else {
            errorMessage = "Group name is required"
            showError = true
            return
        }
        
        guard trimmedName.count <= 50 else {
            errorMessage = "Group name must be 50 characters or less"
            showError = true
            return
        }
        
        if let newGroup = viewModel.createGroup(
            name: trimmedName,
            description: groupDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : groupDescription,
            isPrivate: isPrivate
        ) {
            viewModel.joinGroup(newGroup.id)
            presentationMode.wrappedValue.dismiss()
        } else {
            errorMessage = "Failed to create group. Please try again."
            showError = true
        }
    }
}

struct GroupInvitationsView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Group Invitations")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(textColor)
                    .padding()
                
                Divider()
                    .background(textColor.opacity(0.3))
                
                if viewModel.groupChatManagerPublic.pendingInvitations.isEmpty {
                    // Empty state
                    VStack(spacing: 16) {
                        Image(systemName: "envelope.open")
                            .font(.system(size: 60))
                            .foregroundColor(secondaryTextColor)
                        
                        Text("No Invitations")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(textColor)
                        
                        Text("You don't have any pending group invitations")
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Invitations list
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(viewModel.groupChatManagerPublic.pendingInvitations, id: \.id) { invitation in
                                GroupInvitationRowView(invitation: invitation)
                                    .environmentObject(viewModel)
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .background(backgroundColor)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .foregroundColor(textColor)
                }
            }
        }
    }
}

struct GroupInvitationRowView: View {
    let invitation: GroupInvitation
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(invitation.groupName)
                        .font(.headline)
                        .foregroundColor(textColor)
                    
                    Text("Invited by \(invitation.inviterNickname)")
                        .font(.subheadline)
                        .foregroundColor(secondaryTextColor)
                    
                    Text(formatRelativeTime(invitation.timestamp))
                        .font(.caption)
                        .foregroundColor(secondaryTextColor)
                }
                
                Spacer()
            }
            
            HStack(spacing: 12) {
                Button("Decline") {
                    _ = viewModel.declineGroupInvitation(invitation.id)
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.red)
                .cornerRadius(8)
                
                Button("Accept") {
                    _ = viewModel.acceptGroupInvitation(invitation.id)
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(textColor)
                .cornerRadius(8)
                
                Spacer()
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(colorScheme == .dark ? Color.gray.opacity(0.1) : Color.gray.opacity(0.05))
        )
        .padding(.horizontal)
    }
    
    private func formatRelativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    GroupChatListView()
        .environmentObject(ChatViewModel())
}
