import SwiftUI

struct GroupManagementView: View {
    @ObservedObject var viewModel: ChatViewModel
    let group: BitchatGroup
    @Environment(\.dismiss) private var dismiss
    
    @State private var showInviteSheet = false
    @State private var showMemberManagement = false
    
    var body: some View {
        NavigationView {
            List {
                Section("Group Info") {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(group.name)
                            .foregroundColor(.secondary)
                    }
                    
                    if let description = group.description {
                        HStack {
                            Text("Description")
                            Spacer()
                            Text(description)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    HStack {
                        Text("Members")
                        Spacer()
                        Text("\(group.memberIDs.count)")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Type")
                        Spacer()
                        Text(group.isPrivate ? "Private" : "Public")
                            .foregroundColor(.secondary)
                    }
                }
                
                Section("Actions") {
                    Button("Invite Members") {
                        showInviteSheet = true
                    }
                    
                    Button("Manage Members") {
                        showMemberManagement = true
                    }
                    
                    if group.creatorID == viewModel.meshService.myPeerID {
                        Button("Delete Group", role: .destructive) {
                            deleteGroup()
                        }
                    } else {
                        Button("Leave Group", role: .destructive) {
                            leaveGroup()
                        }
                    }
                }
                
                Section("Members") {
                    ForEach(getGroupMembers(), id: \.id) { member in
                        HStack {
                            Text(member.nickname)
                            Spacer()
                            if member.isCreator {
                                Text("Creator")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            } else if member.isAdmin {
                                Text("Admin")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Group Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showInviteSheet) {
            GroupInviteView(viewModel: viewModel, group: group)
        }
        .sheet(isPresented: $showMemberManagement) {
            GroupMemberManagementView(viewModel: viewModel, group: group)
        }
    }
    
    private func getGroupMembers() -> [GroupMember] {
        var members: [GroupMember] = []
        
        for memberID in group.memberIDs {
            let nickname = viewModel.allPeers.first { $0.id == memberID }?.displayName ?? "Unknown"
            let isCreator = memberID == group.creatorID
            let isAdmin = group.adminIDs.contains(memberID)
            
            members.append(GroupMember(
                id: memberID,
                nickname: nickname,
                isAdmin: isAdmin,
                isCreator: isCreator
            ))
        }
        
        return members.sorted { $0.nickname < $1.nickname }
    }
    
    private func deleteGroup() {
        viewModel.groupService.deleteGroup(group.id)
        dismiss()
    }
    
    private func leaveGroup() {
        viewModel.leaveGroup(group.id)
        dismiss()
    }
}

struct GroupInviteView: View {
    @ObservedObject var viewModel: ChatViewModel
    let group: BitchatGroup
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedPeers: Set<String> = []
    
    var body: some View {
        NavigationView {
            List {
                Section("Select Peers to Invite") {
                    ForEach(viewModel.allPeers.filter { !$0.isMe && !group.memberIDs.contains($0.id) }) { peer in
                        HStack {
                            Text(peer.displayName)
                            Spacer()
                            if selectedPeers.contains(peer.id) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedPeers.contains(peer.id) {
                                selectedPeers.remove(peer.id)
                            } else {
                                selectedPeers.insert(peer.id)
                            }
                        }
                    }
                }
                
                if !selectedPeers.isEmpty {
                    Section {
                        Button("Send Invitations") {
                            sendInvitations()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Invite to Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func sendInvitations() {
        for peerID in selectedPeers {
            viewModel.invitePeerToGroup(peerID, groupID: group.id, groupName: group.name)
        }
        dismiss()
    }
}

struct GroupMemberManagementView: View {
    @ObservedObject var viewModel: ChatViewModel
    let group: BitchatGroup
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                ForEach(getGroupMembers(), id: \.id) { member in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(member.nickname)
                            if member.isCreator {
                                Text("Creator")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            } else if member.isAdmin {
                                Text("Admin")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                        
                        Spacer()
                        
                        if !member.isCreator && group.creatorID == viewModel.meshService.myPeerID {
                            Menu {
                                if member.isAdmin {
                                    Button("Remove Admin") {
                                        demoteAdmin(member.id)
                                    }
                                } else {
                                    Button("Make Admin") {
                                        promoteToAdmin(member.id)
                                    }
                                }
                                
                                Button("Remove from Group", role: .destructive) {
                                    removeMember(member.id)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Manage Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func getGroupMembers() -> [GroupMember] {
        var members: [GroupMember] = []
        
        for memberID in group.memberIDs {
            let nickname = viewModel.allPeers.first { $0.id == memberID }?.displayName ?? "Unknown"
            let isCreator = memberID == group.creatorID
            let isAdmin = group.adminIDs.contains(memberID)
            
            members.append(GroupMember(
                id: memberID,
                nickname: nickname,
                isAdmin: isAdmin,
                isCreator: isCreator
            ))
        }
        
        return members.sorted { $0.nickname < $1.nickname }
    }
    
    private func promoteToAdmin(_ memberID: String) {
        viewModel.groupService.promoteToAdmin(memberID, in: group.id)
    }
    
    private func demoteAdmin(_ memberID: String) {
        viewModel.groupService.demoteFromAdmin(memberID, in: group.id)
    }
    
    private func removeMember(_ memberID: String) {
        let nickname = viewModel.allPeers.first { $0.id == memberID }?.displayName ?? "Unknown"
        viewModel.groupService.removeMember(memberID, from: group.id, nickname: nickname)
    }
}
