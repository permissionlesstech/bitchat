//
//  GroupChatView.swift
//  bitchat
//
//  Created by Waluya Juang Husada on 21/08/25.
//


//
// GroupChatView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct GroupChatView: View {
    let group: GroupChat
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.presentationMode) var presentationMode
    
    @State private var messageText = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var showGroupInfo = false
    @State private var showMembersList = false
    @State private var showInviteMembers = false
    
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
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: {
                    viewModel.leaveCurrentGroup()
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                        .foregroundColor(textColor)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName)
                        .font(.headline)
                        .foregroundColor(textColor)
                        .lineLimit(1)
                    
                    Text(group.statusText)
                        .font(.caption)
                        .foregroundColor(secondaryTextColor)
                }
                .onTapGesture {
                    showGroupInfo = true
                }
                
                Spacer()
                
                // Members button
                Button(action: {
                    showMembersList = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2")
                            .font(.title3)
                        Text("\(group.members.count)")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(textColor)
                }
                
                // More options menu
                Menu {
                    Button("Group Info") {
                        showGroupInfo = true
                    }
                    
                    Button("Invite Members") {
                        showInviteMembers = true
                    }
                    
                    Button("Leave Group", role: .destructive) {
                        viewModel.leaveCurrentGroup()
                        presentationMode.wrappedValue.dismiss()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundColor(textColor)
                }
            }
            .padding()
            
            Divider()
                .background(textColor.opacity(0.3))
            
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(group.messages, id: \.id) { message in
                            GroupMessageRowView(message: message, group: group)
                                .environmentObject(viewModel)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: group.messages.count) { _ in
                    // Auto-scroll to bottom when new messages arrive
                    if let lastMessage = group.messages.last {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            // Message input
            HStack(spacing: 12) {
                TextField("Type a message...", text: $messageText, axis: .vertical)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .foregroundColor(textColor)
                    .focused($isTextFieldFocused)
                    .lineLimit(1...5)
                    .onSubmit {
                        sendMessage()
                    }
                
                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .font(.title2)
                        .foregroundColor(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? secondaryTextColor : textColor)
                }
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .background(backgroundColor)
        .sheet(isPresented: $showGroupInfo) {
            GroupInfoView(group: group)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showMembersList) {
            GroupMembersView(group: group)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showInviteMembers) {
            InviteMembersView(group: group)
                .environmentObject(viewModel)
        }
        .onAppear {
            // Mark group as read when view appears
            viewModel.groupChatManagerPublic.markGroupAsRead(groupID: group.id)
        }
    }
    
    private func sendMessage() {
        let trimmedText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        
        viewModel.sendGroupMessage(trimmedText)
        messageText = ""
    }
}

struct GroupMessageRowView: View {
    let message: BitchatMessage
    let group: GroupChat
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    private var isFromCurrentUser: Bool {
        message.senderPeerID == viewModel.meshService.myPeerID
    }
    
    var body: some View {
        HStack {
            if isFromCurrentUser {
                Spacer()
            }
            
            VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: 4) {
                if !isFromCurrentUser {
                    Text(message.sender)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(getSenderColor())
                }
                
                Text(message.content)
                    .font(.body)
                    .foregroundColor(textColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(isFromCurrentUser ? textColor.opacity(0.2) : Color.gray.opacity(0.1))
                    )
                
                HStack(spacing: 4) {
                    Text(formatMessageTime(message.timestamp))
                        .font(.caption2)
                        .foregroundColor(secondaryTextColor)
                    
                    if isFromCurrentUser, let status = message.deliveryStatus {
                        Text(status.displayText)
                            .font(.caption2)
                            .foregroundColor(secondaryTextColor)
                    }
                }
            }
            
            if !isFromCurrentUser {
                Spacer()
            }
        }
    }
    
    private func getSenderColor() -> Color {
        // Generate a consistent color for each sender based on their name
        let hash = abs(message.sender.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.7, brightness: colorScheme == .dark ? 0.8 : 0.6)
    }
    
    private func formatMessageTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct GroupInfoView: View {
    let group: GroupChat
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.colorScheme) var colorScheme
    
    @State private var editingName = false
    @State private var editingDescription = false
    @State private var newName = ""
    @State private var newDescription = ""
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    private var isAdmin: Bool {
        guard let currentFingerprint = viewModel.meshService.getFingerprint(for: viewModel.meshService.myPeerID) else { return false }
        return group.isAdmin(currentFingerprint)
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Group icon and name
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(textColor.opacity(0.2))
                                .frame(width: 100, height: 100)
                            
                            Text(String(group.groupName.prefix(1).uppercased()))
                                .font(.system(size: 40, weight: .bold))
                                .foregroundColor(textColor)
                        }
                        
                        if editingName && isAdmin {
                            TextField("Group name", text: $newName)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.title2)
                                .multilineTextAlignment(.center)
                        } else {
                            Text(group.displayName)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(textColor)
                                .multilineTextAlignment(.center)
                        }
                        
                        if isAdmin {
                            Button(editingName ? "Save" : "Edit Name") {
                                if editingName {
                                    // Save name change
                                    let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmedName.isEmpty && trimmedName != group.groupName {
                                        if let currentFingerprint = viewModel.meshService.getFingerprint(for: viewModel.meshService.myPeerID) {
                                            _ = viewModel.groupChatManagerPublic.updateGroupInfo(
                                                groupID: group.id,
                                                name: trimmedName,
                                                updatedBy: currentFingerprint
                                            )
                                        }
                                    }
                                    editingName = false
                                } else {
                                    newName = group.groupName
                                    editingName = true
                                }
                            }
                            .font(.caption)
                            .foregroundColor(textColor)
                        }
                    }
                    
                    Divider()
                        .background(textColor.opacity(0.3))
                    
                    // Group details
                    VStack(alignment: .leading, spacing: 16) {
                        InfoRowView(title: "Members", value: "\(group.members.count)")
                        InfoRowView(title: "Created", value: formatDate(group.chatCreatedDate))
                        InfoRowView(title: "Type", value: group.isPrivate ? "Private" : "Public")
                        
                        if let description = group.groupDescription, !description.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Description")
                                    .font(.headline)
                                    .foregroundColor(textColor)
                                
                                if editingDescription && isAdmin {
                                    TextField("Group description", text: $newDescription, axis: .vertical)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .lineLimit(3...6)
                                } else {
                                    Text(description)
                                        .font(.body)
                                        .foregroundColor(secondaryTextColor)
                                }
                                
                                if isAdmin {
                                    Button(editingDescription ? "Save" : "Edit Description") {
                                        if editingDescription {
                                            // Save description change
                                            if let currentFingerprint = viewModel.meshService.getFingerprint(for: viewModel.meshService.myPeerID) {
                                                _ = viewModel.groupChatManagerPublic.updateGroupInfo(
                                                    groupID: group.id,
                                                    description: newDescription,
                                                    updatedBy: currentFingerprint
                                                )
                                            }
                                            editingDescription = false
                                        } else {
                                            newDescription = description
                                            editingDescription = true
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundColor(textColor)
                                }
                            }
                        }
                    }
                    
                    Spacer()
                }
                .padding()
            }
            .background(backgroundColor)
            .navigationTitle("Group Info")
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
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

struct InfoRowView: View {
    let title: String
    let value: String
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundColor(textColor)
            
            Spacer()
            
            Text(value)
                .font(.body)
                .foregroundColor(secondaryTextColor)
        }
    }
}

struct GroupMembersView: View {
    let group: GroupChat
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
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(group.members.sorted(by: { $0.nickname < $1.nickname }), id: \.id) { member in
                        GroupMemberRowView(member: member, group: group)
                            .environmentObject(viewModel)
                    }
                }
                .padding(.vertical)
            }
            .background(backgroundColor)
            .navigationTitle("Members (\(group.members.count))")
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

struct GroupMemberRowView: View {
    let member: GroupMember
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
            // Member avatar
            ZStack {
                Circle()
                    .fill(textColor.opacity(0.2))
                    .frame(width: 40, height: 40)
                
                Text(String(member.nickname.prefix(1).uppercased()))
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(textColor)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(member.displayName)
                        .font(.headline)
                        .foregroundColor(textColor)
                    
                    if member.role == .admin {
                        Text("ADMIN")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange)
                            .cornerRadius(4)
                    }
                    
                    Spacer()
                    
                    Text(member.isOnline ? "🟢" : "⚫")
                        .font(.caption)
                }
                
                Text(member.isOnline ? "Online" : "Last seen \(formatRelativeTime(member.lastSeen))")
                    .font(.caption)
                    .foregroundColor(secondaryTextColor)
            }
            
            Spacer()
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

struct InviteMembersView: View {
    let group: GroupChat
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    // Filter connected peers who are not already in the group
    private var availablePeers: [BitchatPeer] {
        viewModel.allPeers.filter { peer in
            let isConnected = viewModel.connectedPeers.contains(peer.id)
            let isNotInGroup = !group.members.contains { $0.fingerprint == peer.noisePublicKey.hexEncodedString() }
            return isConnected && isNotInGroup
        }
    }
    
    var body: some View {
        NavigationView {
            VStack {
                if availablePeers.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 60))
                            .foregroundColor(textColor.opacity(0.6))
                        
                        Text("No Available Peers")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(textColor)
                        
                        Text("Connect to peers who aren't in this group to invite them")
                            .font(.body)
                            .foregroundColor(textColor.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(availablePeers, id: \.id) { peer in
                                InvitePeerRowView(peer: peer, group: group)
                                    .environmentObject(viewModel)
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .background(backgroundColor)
            .navigationTitle("Invite Members")
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

struct InvitePeerRowView: View {
    let peer: BitchatPeer
    let group: GroupChat
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    @State private var inviteSent = false
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Peer avatar
            ZStack {
                Circle()
                    .fill(textColor.opacity(0.2))
                    .frame(width: 40, height: 40)
                
                Text(String(peer.nickname.prefix(1).uppercased()))
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(textColor)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.nickname)
                    .font(.headline)
                    .foregroundColor(textColor)
                
                Text("Online")
                    .font(.caption)
                    .foregroundColor(secondaryTextColor)
            }
            
            Spacer()
            
            Button(action: {
                if viewModel.sendGroupInvitation(groupID: group.id, to: peer.id) {
                    inviteSent = true
                }
            }) {
                Text(inviteSent ? "Invited" : "Invite")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(inviteSent ? Color.gray : textColor)
                    .cornerRadius(8)
            }
            .disabled(inviteSent)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(colorScheme == .dark ? Color.gray.opacity(0.1) : Color.gray.opacity(0.05))
        )
        .padding(.horizontal)
    }
}

#Preview {
    let sampleGroup = GroupChat(groupName: "Test Group", createdBy: "sample_fingerprint")
    return GroupChatView(group: sampleGroup)
        .environmentObject(ChatViewModel())
}
