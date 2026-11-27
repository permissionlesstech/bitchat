//
// GroupSheets.swift
// bitchat
//
// Native UI for creating and managing hybrid (BLE mesh + Nostr) encrypted
// private groups without requiring IRC slash commands.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import SwiftUI

struct CreateGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var peerListModel: PeerListModel
    @ThemedPalette private var palette

    @State private var groupName = ""
    @State private var selectedPeerIDs = Set<PeerID>()
    @State private var errorMessage: String?

    let onRequestAddFriend: () -> Void
    let onGroupCreated: () -> Void

    init(
        onRequestAddFriend: @escaping () -> Void = {},
        onGroupCreated: @escaping () -> Void = {}
    ) {
        self.onRequestAddFriend = onRequestAddFriend
        self.onGroupCreated = onGroupCreated
    }

    private var candidates: [GroupInviteCandidate] {
        peerListModel.groupInviteCandidates()
    }

    private var canCreate: Bool {
        let trimmed = groupName.trimmed
        return !trimmed.isEmpty && trimmed.count <= BitchatGroup.maxNameLength
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(
                        String(localized: "groups.create.name_placeholder", defaultValue: "Group name (e.g. Weekend Trip)", comment: "Placeholder for new group name"),
                        text: $groupName
                    )
                    .bitchatFont(size: 16)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
                } header: {
                    Text(String(localized: "groups.create.name_header", defaultValue: "Group Name", comment: "Section header for group name"))
                } footer: {
                    Text(String(localized: "groups.create.encryption_footer", defaultValue: "Messages are end-to-end encrypted and automatically travel over Bluetooth mesh offline and Nostr online.", comment: "Footer explaining hybrid group encryption"))
                }

                Section {
                    if candidates.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "groups.create.no_contacts", defaultValue: "No nearby peers or invited friends yet. You can create the group now and invite friends anytime.", comment: "Empty contacts message when creating a group"))
                                .bitchatFont(size: 13)
                                .foregroundColor(palette.secondary)
                            Button {
                                dismiss()
                                onRequestAddFriend()
                            } label: {
                                Label(
                                    String(localized: "groups.create.invite_friend_cta", defaultValue: "Invite a Friend", comment: "Button to open add friend flow from create group"),
                                    systemImage: "person.badge.plus"
                                )
                                .bitchatFont(size: 13, weight: .semibold)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(candidates) { candidate in
                            let isSelected = selectedPeerIDs.contains(candidate.peerID)
                            Button {
                                toggleSelection(candidate.peerID)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(isSelected ? palette.accent : palette.secondary)
                                        .font(.system(size: 18))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.displayName)
                                            .bitchatFont(size: 15, weight: .medium)
                                            .foregroundColor(palette.primary)
                                        HStack(spacing: 6) {
                                            if candidate.isMeshConnected {
                                                Label(
                                                    String(localized: "groups.transport.mesh", defaultValue: "Bluetooth", comment: "Transport tag for Bluetooth mesh"),
                                                    systemImage: "antenna.radiowaves.left.and.right"
                                                )
                                                .bitchatFont(size: 11)
                                                .foregroundColor(palette.accentBlue)
                                            }
                                            if candidate.isNostrReachable {
                                                Label(
                                                    String(localized: "groups.transport.nostr", defaultValue: "Nostr", comment: "Transport tag for Nostr"),
                                                    systemImage: "globe"
                                                )
                                                .bitchatFont(size: 11)
                                                .foregroundColor(.purple)
                                            }
                                        }
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text(String(localized: "groups.create.members_header", defaultValue: "Add Members (Optional)", comment: "Section header for picking initial group members"))
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .bitchatFont(size: 13)
                            .foregroundColor(palette.alertRed)
                    }
                }
            }
            .navigationTitle(String(localized: "groups.create.title", defaultValue: "New Group", comment: "Title of the create group sheet"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "groups.create.confirm", defaultValue: "Create", comment: "Create group button")) {
                        createGroup()
                    }
                    .disabled(!canCreate)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }

    private func toggleSelection(_ peerID: PeerID) {
        if selectedPeerIDs.contains(peerID) {
            selectedPeerIDs.remove(peerID)
        } else if selectedPeerIDs.count < BitchatGroup.maxMembers - 1 {
            selectedPeerIDs.insert(peerID)
        }
    }

    private func createGroup() {
        let result = peerListModel.createGroup(
            named: groupName.trimmed,
            memberPeerIDs: Array(selectedPeerIDs)
        )
        switch result {
        case .success, .handled:
            errorMessage = nil
            dismiss()
            onGroupCreated()
        case .error(let message):
            errorMessage = message
        }
    }
}

struct GroupInfoSheet: View {
    let groupPeerID: PeerID

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @ThemedPalette private var palette

    @State private var statusMessage: String?
    @State private var isError = false
    @State private var showLeaveConfirmation = false

    private var group: BitchatGroup? {
        privateConversationModel.group(for: groupPeerID)
    }

    private var isCreator: Bool {
        group?.creatorFingerprint == privateConversationModel.myNoiseFingerprint
    }

    private var addableCandidates: [GroupInviteCandidate] {
        guard let group else { return [] }
        let existing = Set(group.members.map(\.fingerprint))
        return peerListModel.groupInviteCandidates(excludingFingerprints: existing)
    }

    var body: some View {
        NavigationStack {
            List {
                if let group {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 24))
                                .foregroundColor(palette.accent)
                                .frame(width: 44, height: 44)
                                .background(palette.accent.opacity(0.14))
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name)
                                    .bitchatFont(size: 17, weight: .semibold)
                                    .foregroundColor(palette.primary)
                                Text(
                                    String(
                                        format: String(localized: "groups.info.member_cap", defaultValue: "%lld of %lld members · Encrypted (BLE + Nostr)", comment: "Subtitle in group info showing member count and transport"),
                                        locale: .current,
                                        group.members.count,
                                        BitchatGroup.maxMembers
                                    )
                                )
                                .bitchatFont(size: 12)
                                .foregroundColor(palette.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Section {
                        Picker(
                            String(localized: "chat.timer.label", defaultValue: "Disappearing messages", comment: "Picker label for disappearing message timer"),
                            selection: Binding(
                                get: { privateConversationModel.disappearingTimer(for: groupPeerID) },
                                set: { privateConversationModel.setDisappearingTimer($0, for: groupPeerID) }
                            )
                        ) {
                            ForEach(DisappearingTimer.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    } header: {
                        Text(String(localized: "groups.info.privacy_header", defaultValue: "History & Privacy", comment: "Section header for group disappearing timer"))
                    }

                    Section {
                        ForEach(group.members, id: \.fingerprint) { member in
                            HStack(spacing: 10) {
                                Text(member.nickname)
                                    .bitchatFont(size: 15)
                                    .foregroundColor(palette.primary)
                                if member.fingerprint == group.creatorFingerprint {
                                    Label(
                                        String(localized: "groups.state.creator", comment: "State label for a group the user created"),
                                        systemImage: "crown.fill"
                                    )
                                    .bitchatFont(size: 11)
                                    .foregroundColor(.orange)
                                }
                                Spacer()
                                if isCreator && member.fingerprint != group.creatorFingerprint {
                                    Button(role: .destructive) {
                                        removeMember(member.fingerprint)
                                    } label: {
                                        Text(String(localized: "groups.action.remove", defaultValue: "Remove", comment: "Button to remove a member from a group"))
                                            .bitchatFont(size: 12, weight: .medium)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    } header: {
                        Text(String(localized: "groups.info.members_header", defaultValue: "Members", comment: "Section header for group member list"))
                    }

                    if isCreator && group.members.count < BitchatGroup.maxMembers {
                        Section {
                            if addableCandidates.isEmpty {
                                Text(String(localized: "groups.info.no_addable", defaultValue: "No other nearby peers or friends available to add yet.", comment: "Empty state when no eligible contacts can be added to a group"))
                                    .bitchatFont(size: 13)
                                    .foregroundColor(palette.secondary)
                            } else {
                                ForEach(addableCandidates) { candidate in
                                    Button {
                                        inviteCandidate(candidate)
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(candidate.displayName)
                                                    .bitchatFont(size: 15)
                                                    .foregroundColor(palette.primary)
                                                Text(
                                                    candidate.isMeshConnected
                                                        ? String(localized: "groups.transport.mesh", defaultValue: "Bluetooth", comment: "Transport tag for Bluetooth mesh")
                                                        : String(localized: "groups.transport.nostr", defaultValue: "Nostr", comment: "Transport tag for Nostr")
                                                )
                                                .bitchatFont(size: 11)
                                                .foregroundColor(palette.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "plus.circle.fill")
                                                .foregroundColor(palette.accent)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } header: {
                            Text(String(localized: "groups.info.add_header", defaultValue: "Add Members", comment: "Section header for inviting more contacts to a group"))
                        }
                    }

                    if let statusMessage {
                        Section {
                            Text(statusMessage)
                                .bitchatFont(size: 13)
                                .foregroundColor(isError ? palette.alertRed : palette.accent)
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            showLeaveConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                Text(String(localized: "groups.action.leave", defaultValue: "Leave Group", comment: "Destructive button to leave a group"))
                                    .bitchatFont(size: 15, weight: .semibold)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "groups.info.title", defaultValue: "Group Info", comment: "Title of the group info sheet"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton { dismiss() }
                }
            }
            .confirmationDialog(
                String(localized: "groups.leave.confirm_title", defaultValue: "Leave this group?", comment: "Confirmation dialog title before leaving a group"),
                isPresented: $showLeaveConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "groups.action.leave", defaultValue: "Leave Group", comment: "Destructive button to leave a group"), role: .destructive) {
                    _ = privateConversationModel.leaveGroup(peerID: groupPeerID)
                    dismiss()
                }
                Button("common.cancel", role: .cancel) {}
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    private func inviteCandidate(_ candidate: GroupInviteCandidate) {
        switch privateConversationModel.inviteMember(peerID: candidate.peerID, into: groupPeerID) {
        case .success(let message):
            statusMessage = message
            isError = false
        case .error(let message):
            statusMessage = message
            isError = true
        case .handled:
            break
        }
    }

    private func removeMember(_ fingerprint: String) {
        switch privateConversationModel.removeMember(fingerprint: fingerprint, from: groupPeerID) {
        case .success(let message):
            statusMessage = message
            isError = false
        case .error(let message):
            statusMessage = message
            isError = true
        case .handled:
            break
        }
    }
}
