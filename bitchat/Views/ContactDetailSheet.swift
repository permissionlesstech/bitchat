//
// ContactDetailSheet.swift
// bitchat
//
// Unified contact detail & verification sheet presented from a 1:1 DM header:
// combines identity/alias, live reachability, mute/favorite/disappearing timer
// controls, shared media, shared private groups, cryptographic fingerprint
// verification (with QR verification), and clear/block safety controls.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ContactDetailSheet: View {
    @EnvironmentObject private var verificationModel: VerificationModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var privateInboxModel: PrivateInboxModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @ThemedPalette private var palette

    let peerID: PeerID
    let conversationPeerID: PeerID
    @Binding var imagePreviewURL: URL?

    @State private var aliasDraft = ""
    @State private var didLoadAlias = false
    @State private var showFingerprints = false
    @State private var showQRVerifySheet = false
    @State private var showClearConfirm = false
    @State private var showBlockConfirm = false

    private var headerState: PrivateConversationHeaderState? {
        privateConversationModel.selectedHeaderState
    }

    private var sharedImageURLs: [URL] {
        let messages = privateInboxModel.messages(for: conversationPeerID)
        return messages.compactMap { msg in
            guard let media = conversationUIModel.mediaAttachment(for: msg),
                  case .image(let url) = media else {
                return nil
            }
            return url
        }.reversed()
    }

    var body: some View {
        let fpState = verificationModel.fingerprintPresentation(for: peerID)
        let sharedGroups = privateConversationModel.sharedGroups(for: peerID)
        let isMuted = privateConversationModel.isMuted(for: conversationPeerID)
        let isBlocked = privateConversationModel.isBlocked(peerID: peerID)
        let activeTimer = privateConversationModel.disappearingTimer(for: conversationPeerID)
        let displayName = headerState?.displayName ?? fpState.peerNickname
        let avatarTint = peerListModel.colorForPeer(id: peerID, isDark: colorScheme == .dark)

        VStack(spacing: 0) {
            ThemedSheetHeader(
                title: String(localized: "contact.detail.title", defaultValue: "Contact Info", comment: "Title of the unified contact detail sheet"),
                onClose: {
                    commitAlias()
                    dismiss()
                }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    profileCard(
                        displayName: displayName,
                        avatarTint: avatarTint,
                        fpState: fpState
                    )

                    controlsCard(
                        isMuted: isMuted,
                        activeTimer: activeTimer
                    )

                    if !sharedImageURLs.isEmpty {
                        sharedMediaCard(urls: sharedImageURLs)
                    }

                    if !sharedGroups.isEmpty {
                        sharedGroupsCard(groups: sharedGroups)
                    }

                    securityCard(fpState: fpState)

                    safetyCard(
                        displayName: displayName,
                        isBlocked: isBlocked
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .themedSheetBackground()
        .foregroundColor(palette.primary)
        .onAppear {
            if !didLoadAlias && fpState.canEditLocalAlias {
                aliasDraft = fpState.localPetname ?? ""
                didLoadAlias = true
            }
        }
        .onChange(of: fpState.theirFingerprint) { _ in
            if !didLoadAlias {
                let updated = verificationModel.fingerprintPresentation(for: peerID)
                if updated.canEditLocalAlias {
                    aliasDraft = updated.localPetname ?? ""
                    didLoadAlias = true
                }
            }
        }
        .onDisappear {
            commitAlias()
        }
        .sheet(isPresented: $showQRVerifySheet) {
            VerificationSheetView(isPresented: $showQRVerifySheet)
                .environmentObject(verificationModel)
        }
        .confirmationDialog(
            String(localized: "content.clear.confirm_title", defaultValue: "Clear This Chat?", comment: "Confirmation title before clearing DM history"),
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "content.clear.confirm_action", defaultValue: "Clear Chat", comment: "Destructive action to clear chat messages"),
                role: .destructive
            ) {
                privateConversationModel.clearHistory(for: conversationPeerID)
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            String(
                format: String(localized: "contact.detail.block_confirm_title", defaultValue: "Block %@?", comment: "Confirmation dialog title before blocking a contact"),
                locale: .current,
                displayName
            ),
            isPresented: $showBlockConfirm,
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "content.actions.block", defaultValue: "Block", comment: "Destructive action to block a peer"),
                role: .destructive
            ) {
                privateConversationModel.toggleBlock(for: peerID, displayName: displayName)
                dismiss()
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 540)
        #endif
    }

    // MARK: - Sections

    private func profileCard(
        displayName: String,
        avatarTint: Color,
        fpState: FingerprintPresentationState
    ) -> some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(avatarTint.opacity(0.18))
                            .frame(width: 54, height: 54)
                        Text(verbatim: String(displayName.prefix(1)).uppercased())
                            .bitchatFont(size: 22, weight: .bold)
                            .foregroundColor(avatarTint)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(verbatim: displayName)
                                .bitchatFont(size: 18, weight: .bold)
                                .foregroundColor(palette.primary)
                                .lineLimit(1)

                            if fpState.isVerified {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.green)
                            } else if fpState.isVouched {
                                Image(systemName: "checkmark.seal")
                                    .font(.system(size: 14))
                                    .foregroundColor(.teal)
                            }
                        }

                        HStack(spacing: 6) {
                            let status = reachabilityBadge
                            Image(systemName: status.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(status.color)
                            Text(status.label)
                                .bitchatFont(size: 12, weight: .medium)
                                .foregroundColor(palette.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                }

                if fpState.canEditLocalAlias {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "fingerprint.local_alias.label", defaultValue: "Local Alias", comment: "Label for local alias field"))
                            .bitchatFont(size: 11, weight: .semibold)
                            .foregroundColor(palette.secondary)

                        TextField(
                            String(localized: "fingerprint.local_alias.placeholder", defaultValue: "Name for this person", comment: "Placeholder for local alias field"),
                            text: $aliasDraft
                        )
                        .textFieldStyle(.plain)
                        .bitchatFont(size: 14)
                        .foregroundColor(palette.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(palette.background)
                        .overlay(
                            RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous)
                                .stroke(palette.cardBorder, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
                        .onSubmit { commitAlias() }

                        Text(String(localized: "fingerprint.local_alias.hint", defaultValue: "Only on this device. Leave blank to use their claimed nickname.", comment: "Explanation under local alias field"))
                            .bitchatFont(size: 11)
                            .foregroundColor(palette.secondary)
                    }
                }
            }
        }
    }

    private func controlsCard(
        isMuted: Bool,
        activeTimer: DisappearingTimer
    ) -> some View {
        ThemedCard {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: isMuted ? "bell.slash.fill" : "bell.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(isMuted ? .orange : palette.secondary)
                        .frame(width: 22)

                    Text(String(localized: "contact.detail.mute_notifications", defaultValue: "Mute Notifications", comment: "Toggle label to mute notifications from a contact"))
                        .bitchatFont(size: 14, weight: .medium)
                        .foregroundColor(palette.primary)

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { isMuted },
                        set: { _ in privateConversationModel.toggleMute(for: conversationPeerID) }
                    ))
                    .labelsHidden()
                }
                .padding(.vertical, 4)

                if headerState?.supportsFavoriteToggle == true {
                    Divider().background(palette.divider).padding(.vertical, 8)

                    Button {
                        privateConversationModel.toggleFavoriteForSelectedConversation()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: headerState?.isFavorite == true ? "star.fill" : "star")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(headerState?.isFavorite == true ? .yellow : palette.secondary)
                                .frame(width: 22)

                            Text(
                                headerState?.isFavorite == true
                                    ? String(localized: "content.accessibility.remove_favorite", defaultValue: "Remove from Favorites", comment: "Button to unfavorite a peer")
                                    : String(localized: "content.accessibility.add_favorite", defaultValue: "Add to Favorites", comment: "Button to favorite a peer")
                            )
                            .bitchatFont(size: 14, weight: .medium)
                            .foregroundColor(palette.primary)

                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Divider().background(palette.divider).padding(.vertical, 8)

                HStack(spacing: 12) {
                    Image(systemName: activeTimer.iconName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(activeTimer == .off ? palette.secondary : .orange)
                        .frame(width: 22)

                    Text(String(localized: "chat.timer.label", defaultValue: "Disappearing Messages", comment: "Row label for disappearing messages setting"))
                        .bitchatFont(size: 14, weight: .medium)
                        .foregroundColor(palette.primary)

                    Spacer()

                    Menu {
                        ForEach(DisappearingTimer.allCases) { option in
                            Button {
                                privateConversationModel.setDisappearingTimer(option, for: conversationPeerID)
                            } label: {
                                HStack {
                                    Text(option.displayName)
                                    if activeTimer == option {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(activeTimer.shortLabel)
                                .bitchatFont(size: 13, weight: .semibold)
                                .foregroundColor(activeTimer == .off ? palette.secondary : .orange)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(palette.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(palette.background)
                        .clipShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding(.vertical, 4)

                if !conversationPeerID.isGeoDM {
                    Divider().background(palette.divider).padding(.vertical, 8)

                    let autoListen = privateConversationModel.autoListenPolicy(for: conversationPeerID)
                    HStack(spacing: 12) {
                        Image(systemName: autoListen == .never ? "speaker.slash.fill" : "radio")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(autoListen == .always ? palette.accent : palette.secondary)
                            .frame(width: 22)

                        Text(String(localized: "contact.detail.walkie_autolisten", defaultValue: "Walkie-Talkie Auto-Play", comment: "Row label for per-chat live voice auto-play setting"))
                            .bitchatFont(size: 14, weight: .medium)
                            .foregroundColor(palette.primary)

                        Spacer()

                        Menu {
                            ForEach(PTTAutoListenPolicy.allCases) { option in
                                Button {
                                    privateConversationModel.setAutoListenPolicy(option, for: conversationPeerID)
                                } label: {
                                    HStack {
                                        Text(option.displayName)
                                        if autoListen == option {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(autoListen.shortLabel)
                                    .bitchatFont(size: 13, weight: .semibold)
                                    .foregroundColor(autoListen == .automatic ? palette.secondary : palette.accent)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(palette.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(palette.background)
                            .clipShape(Capsule())
                        }
                        .menuStyle(.borderlessButton)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func sharedMediaCard(urls: [URL]) -> some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(String(localized: "contact.detail.shared_media", defaultValue: "Shared Media", comment: "Section header for shared media in contact detail sheet"))
                        .bitchatFont(size: 13, weight: .semibold)
                        .foregroundColor(palette.primary)
                    Spacer()
                    Text(verbatim: "\(urls.count)")
                        .bitchatFont(size: 12, weight: .medium)
                        .foregroundColor(palette.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(urls.prefix(12), id: \.self) { url in
                            ContactMediaThumbnail(url: url) {
                                imagePreviewURL = url
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
    }

    private func sharedGroupsCard(groups: [BitchatGroup]) -> some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "contact.detail.shared_groups", defaultValue: "Groups in Common", comment: "Section header for shared private groups in contact detail sheet"))
                    .bitchatFont(size: 13, weight: .semibold)
                    .foregroundColor(palette.primary)

                ForEach(Array(groups.enumerated()), id: \.element.groupID) { index, group in
                    if index > 0 {
                        Divider().background(palette.divider)
                    }
                    Button {
                        dismiss()
                        privateConversationModel.openConversation(for: group.peerID)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(palette.accent)
                                .frame(width: 28, height: 28)
                                .background(palette.accent.opacity(0.14))
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: group.name)
                                    .bitchatFont(size: 14, weight: .semibold)
                                    .foregroundColor(palette.primary)
                                Text(
                                    String(
                                        format: String(localized: "group.info.members_count", defaultValue: "%lld members", comment: "Member count subtitle for a shared group"),
                                        locale: .current,
                                        group.members.count
                                    )
                                )
                                .bitchatFont(size: 11)
                                .foregroundColor(palette.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: ChromeMetrics.rowChevronSize, weight: .semibold))
                                .foregroundColor(palette.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func securityCard(fpState: FingerprintPresentationState) -> some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: fpState.isVerified ? "checkmark.shield.fill" : "lock.shield.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(fpState.isVerified ? .green : palette.accent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "fingerprint.title", defaultValue: "Security Verification", comment: "Title for security verification section"))
                            .bitchatFont(size: 14, weight: .semibold)
                            .foregroundColor(palette.primary)
                        Text(fpState.encryptionStatus.description)
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.secondary)
                    }

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showFingerprints.toggle()
                        }
                    } label: {
                        Image(systemName: showFingerprints ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(palette.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }

                if fpState.isVouched && !fpState.isVerified {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 12))
                            .foregroundColor(.teal)
                        Text(
                            String(
                                format: String(localized: "fingerprint.message.vouched_by", comment: "Vouched-by count"),
                                locale: .current,
                                fpState.voucherCount
                            )
                        )
                        .bitchatFont(size: 12)
                        .foregroundColor(.teal)
                    }
                }

                if showFingerprints {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "fingerprint.their_label"))
                            .bitchatFont(size: 11, weight: .bold)
                            .foregroundColor(palette.secondary)

                        if let fp = fpState.theirFingerprint {
                            fingerprintBlock(fp)
                        } else {
                            Text(String(localized: "fingerprint.handshake_pending"))
                                .bitchatFont(size: 12)
                                .foregroundColor(.orange)
                        }

                        Text(String(localized: "fingerprint.your_label"))
                            .bitchatFont(size: 11, weight: .bold)
                            .foregroundColor(palette.secondary)
                            .padding(.top, 4)

                        fingerprintBlock(fpState.myFingerprint)
                    }
                }

                HStack(spacing: 8) {
                    if fpState.canToggleVerification {
                        Button {
                            if fpState.isVerified {
                                verificationModel.unverifyFingerprint(for: peerID)
                            } else {
                                verificationModel.verifyFingerprint(for: peerID)
                            }
                        } label: {
                            Text(fpState.isVerified ? LocalizedStringKey("fingerprint.action.remove_verification") : LocalizedStringKey("fingerprint.action.mark_verified"))
                                .bitchatFont(size: 13, weight: .semibold)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(fpState.isVerified ? Color.red.opacity(0.85) : Color.green)
                                .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        showQRVerifySheet = true
                    } label: {
                        Label(
                            String(localized: "contact.detail.verify_qr", defaultValue: "Verify QR", comment: "Button to open QR code verification sheet"),
                            systemImage: "qrcode"
                        )
                        .bitchatFont(size: 13, weight: .semibold)
                        .foregroundColor(palette.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(palette.background)
                        .overlay(
                            RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous)
                                .stroke(palette.cardBorder, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func fingerprintBlock(_ fingerprint: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: formattedFingerprint(fingerprint))
                .bitchatFont(size: 12)
                .foregroundColor(palette.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                ClipboardHelper.copy(fingerprint)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundColor(palette.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "common.copy", defaultValue: "Copy", comment: "Copy fingerprint"))
        }
        .padding(10)
        .background(palette.background)
        .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
    }

    private func safetyCard(displayName: String, isBlocked: Bool) -> some View {
        ThemedCard {
            VStack(spacing: 0) {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 22)
                        Text(String(localized: "content.clear.confirm_action", defaultValue: "Clear Chat", comment: "Action to clear messages in this conversation"))
                            .bitchatFont(size: 14, weight: .medium)
                        Spacer()
                    }
                    .foregroundColor(.red)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().background(palette.divider).padding(.vertical, 6)

                Button(role: isBlocked ? nil : .destructive) {
                    if isBlocked {
                        privateConversationModel.toggleBlock(for: peerID, displayName: displayName)
                    } else {
                        showBlockConfirm = true
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: isBlocked ? "hand.raised.slash" : "hand.raised.fill")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 22)
                        Text(
                            isBlocked
                                ? String(localized: "contact.detail.unblock", defaultValue: "Unblock Contact", comment: "Action to unblock a blocked contact")
                                : String(localized: "contact.detail.block", defaultValue: "Block Contact", comment: "Action to block a contact")
                        )
                        .bitchatFont(size: 14, weight: .medium)
                        Spacer()
                    }
                    .foregroundColor(isBlocked ? palette.accent : .red)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private var reachabilityBadge: (icon: String, color: Color, label: String) {
        switch headerState?.availability {
        case .bluetoothConnected:
            return ("dot.radiowaves.left.and.right", palette.accentBlue, String(localized: "inbox.status.nearby_ble", defaultValue: "Nearby over Bluetooth", comment: "Reachability status"))
        case .meshReachable:
            return ("point.3.filled.connected.trianglepath.dotted", palette.accentBlue, String(localized: "inbox.status.mesh_relayed", defaultValue: "Reachable on mesh", comment: "Reachability status"))
        case .nostrAvailable:
            return ("globe", .purple, String(localized: "content.accessibility.available_nostr", defaultValue: "Available via Nostr", comment: "Reachability status"))
        case .offline, .none:
            return ("antenna.radiowaves.left.and.right.slash", palette.secondary, String(localized: "mesh_peers.state.offline", defaultValue: "Offline", comment: "Reachability status"))
        }
    }

    private func formattedFingerprint(_ fingerprint: String) -> String {
        let upper = fingerprint.uppercased()
        var formatted = ""
        for (index, char) in upper.enumerated() {
            if index > 0 && index % 4 == 0 {
                formatted += (index % 16 == 0) ? "\n" : " "
            }
            formatted.append(char)
        }
        return formatted
    }

    private func commitAlias() {
        let state = verificationModel.fingerprintPresentation(for: peerID)
        guard state.canEditLocalAlias, didLoadAlias else { return }
        let current = state.localPetname ?? ""
        let trimmed = aliasDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != current else { return }
        verificationModel.setLocalPetname(trimmed.isEmpty ? nil : trimmed, for: peerID)
    }
}

private struct ContactMediaThumbnail: View {
    let url: URL
    let onTap: () -> Void

    #if os(iOS)
    @State private var image: UIImage?
    #else
    @State private var image: NSImage?
    #endif

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                if let image {
                    #if os(iOS)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                    #else
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                    #endif
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 68, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onAppear {
            guard image == nil else { return }
            let targetURL = url
            if let cached = ImageDownsampler.cachedImage(for: targetURL, maxPixelSize: 200) {
                image = cached
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let loaded = ImageDownsampler.loadDownsampledImage(from: targetURL, maxPixelSize: 200) else { return }
                DispatchQueue.main.async {
                    image = loaded
                }
            }
        }
    }
}
