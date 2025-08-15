//
//  GroupInvitationsView.swift
//  bitchat
//
//  Created by Waluya Juang Husada on 14/08/25.
//

import SwiftUI

struct GroupInvitationsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var groupService = GroupPersistenceService.shared
    @Environment(\.dismiss) private var dismiss
    
    
    var body: some View {
        NavigationView {
            List {
                if groupService.pendingInvitations.isEmpty {
                    Section {
                        VStack(spacing: 16) {
                            Image(systemName: "envelope.open")
                                .font(.system(size: 48))
                                .foregroundColor(.gray)
                            
                            Text("No Pending Invitations")
                                .font(.headline)
                                .foregroundColor(.gray)
                            
                            Text("When someone invites you to join a group, it will appear here.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    }
                } else {
                    Section("Pending Invitations") {
                        ForEach(Array(groupService.pendingInvitations.values), id: \.groupID) { invitation in
                            GroupInvitationRow(
                                invitation: invitation,
                                viewModel: viewModel
                            )
                        }
                    }
                }
            }
            .navigationTitle("Group Invitations (\(groupService.pendingInvitations.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    #if DEBUG
                    Button("Test") {
                        viewModel.debugCreateTestInvitation()
                    }
                    .foregroundColor(.orange)
                    #endif
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct GroupInvitationRow: View {
    let invitation: GroupInvitation
    @ObservedObject var viewModel: ChatViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Group info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "person.3.fill")
                        .foregroundColor(.blue)
                    
                    Text(invitation.groupName)
                        .font(.headline)
                    
                    Spacer()
                    
                    if invitation.isExpired {
                        Text("EXPIRED")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
                
                Text("Invited by \(invitation.inviterNickname)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Text("Invited \(invitation.timestamp.timeAgoDisplay())")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Action buttons
            if !invitation.isExpired {
                HStack(spacing: 12) {
                    Button("Accept") {
                        viewModel.acceptGroupInvitation(invitation.groupID)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    
                    Button("Decline") {
                        viewModel.declineGroupInvitation(invitation.groupID)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Spacer()
                }
            } else {
                Text("This invitation has expired")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Time Ago Extension

extension Date {
    func timeAgoDisplay() -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

// MARK: - Preview

#Preview {
    GroupInvitationsView(viewModel: ChatViewModel())
}
