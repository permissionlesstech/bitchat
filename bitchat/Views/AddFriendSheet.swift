//
// AddFriendSheet.swift
// bitchat
//
// Two-tab sheet for adding friends remotely or in person, using the unified
// ThemedSheetHeader and ThemedCard design system.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import SwiftUI

struct AddFriendSheet: View {
    enum Tab: Hashable {
        case myInvite
        case addFriend
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @ThemedPalette private var palette

    @State private var selectedTab: Tab
    @State private var inviteInput = ""
    @State private var errorMessage: String?
    @State private var copiedLink = false
    @State private var sharePayload: ChannelSharePayload?
    @State private var cameraUnavailable = false

    let onInviteAccepted: (PeerID) -> Void

    init(
        initialTab: Tab = .myInvite,
        onInviteAccepted: @escaping (PeerID) -> Void = { _ in }
    ) {
        _selectedTab = State(initialValue: initialTab)
        self.onInviteAccepted = onInviteAccepted
    }

    var body: some View {
        VStack(spacing: 0) {
            ThemedSheetHeader(
                title: String(localized: "friend_invite.sheet.title", defaultValue: "Invite & Add Friends", comment: "Title of the add friend sheet"),
                onClose: { dismiss() }
            )

            Picker("", selection: $selectedTab) {
                Text(String(localized: "friend_invite.tab.my_invite", defaultValue: "My Invite", comment: "Tab label for showing your own invite link and QR"))
                    .tag(Tab.myInvite)
                Text(String(localized: "friend_invite.tab.add_friend", defaultValue: "Add Friend", comment: "Tab label for scanning or pasting a friend's invite"))
                    .tag(Tab.addFriend)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                switch selectedTab {
                case .myInvite:
                    myInviteContent
                case .addFriend:
                    addFriendContent
                }
            }
        }
        .themedSheetBackground()
        .foregroundColor(palette.primary)
        .sheet(item: $sharePayload) { payload in
            ShareActivityView(text: payload.text)
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 560)
        #endif
    }

    @ViewBuilder
    private var myInviteContent: some View {
        let invite = appChromeModel.buildMyFriendInvite()
        VStack(spacing: 16) {
            Text(String(localized: "friend_invite.my_invite.subtitle", defaultValue: "Share this link or QR with a friend. Tapping it connects you over end-to-end encryption — online via Nostr and offline via Bluetooth mesh.", comment: "Subtitle explaining personal invite links"))
                .bitchatFont(size: 13)
                .foregroundColor(palette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let invite, let urlString = invite.deepLinkURL?.absoluteString ?? invite.universalURL?.absoluteString {
                ThemedCard(padding: 16, spacing: 12) {
                    VStack(spacing: 12) {
                        QRCodeImage(data: urlString, size: 220)
                            .padding(12)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: palette.cardRadius, style: .continuous))

                        Text(verbatim: "@\(invite.nickname)")
                            .bitchatFont(size: 16, weight: .semibold)
                            .foregroundColor(palette.primary)
                    }
                    .frame(maxWidth: .infinity)
                }

                VStack(spacing: 10) {
                    Button {
                        sharePayload = ChannelSharePayload(text: invite.sharePayloadText)
                    } label: {
                        Label(
                            String(localized: "friend_invite.action.share", defaultValue: "Share Invite Link", comment: "Primary button to share personal invite link"),
                            systemImage: "square.and.arrow.up"
                        )
                        .bitchatFont(size: 15, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(palette.accent)
                        .foregroundColor(palette.accentForeground)
                        .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        ClipboardHelper.copy(urlString)
                        copiedLink = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedLink = false
                        }
                    } label: {
                        Label(
                            copiedLink
                                ? String(localized: "friend_invite.action.copied", defaultValue: "Copied!", comment: "Confirmation after copying invite link")
                                : String(localized: "friend_invite.action.copy", defaultValue: "Copy Invite Link", comment: "Secondary button to copy invite link"),
                            systemImage: copiedLink ? "checkmark" : "doc.on.doc"
                        )
                        .bitchatFont(size: 14, weight: .medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous)
                                .stroke(palette.cardBorder, lineWidth: 1)
                        )
                        .foregroundColor(palette.primary)
                        .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ThemedCard {
                    Text(FriendInviteError.missingOwnIdentity.localizedDescription)
                        .bitchatFont(size: 13)
                        .foregroundColor(palette.secondary)
                }
            }
        }
        .padding(16)
    }

    private var addFriendContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                CameraScannerView(
                    isActive: selectedTab == .addFriend,
                    onUnavailable: { cameraUnavailable = true }
                ) { scanned in
                    handleCandidate(scanned)
                }
                if cameraUnavailable {
                    VStack(spacing: 6) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 28))
                            .foregroundColor(palette.secondary)
                        Text(String(localized: "friend_invite.camera_unavailable", defaultValue: "Camera unavailable — paste an invite link below.", comment: "Hint when camera permission is unavailable in Add Friend"))
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
            .frame(height: 220)
            .background(palette.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: palette.cardRadius, style: .continuous)
                    .stroke(palette.cardBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: palette.cardRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                ThemedSectionLabel(text: String(localized: "friend_invite.paste_label", defaultValue: "Or paste an invite link", comment: "Header above paste invite field").uppercased())

                ThemedCard(padding: 10, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField(
                            String(localized: "friend_invite.paste_placeholder", defaultValue: "https://bitchat.free/invite?...", comment: "Placeholder for pasting a friend invite link"),
                            text: $inviteInput
                        )
                        .textFieldStyle(.plain)
                        .bitchatFont(size: 14)
                        .foregroundColor(palette.primary)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit { handleCandidate(inviteInput) }

                        Button {
                            handleCandidate(inviteInput)
                        } label: {
                            Text(String(localized: "friend_invite.action.add", defaultValue: "Add", comment: "Button to add a friend from a pasted invite link"))
                                .bitchatFont(size: 13, weight: .semibold)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(inviteInput.trimmed.isEmpty ? palette.cardBackground : palette.accent)
                                .foregroundColor(inviteInput.trimmed.isEmpty ? palette.secondary : palette.accentForeground)
                                .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(inviteInput.trimmed.isEmpty)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.alertRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
    }

    private func handleCandidate(_ raw: String) {
        switch appChromeModel.acceptFriendInvite(from: raw) {
        case .success(let peerID):
            errorMessage = nil
            dismiss()
            onInviteAccepted(peerID)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}
