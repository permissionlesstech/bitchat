import BitFoundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ContentPeopleSheetView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var verificationModel: VerificationModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel

    @Binding var showSidebar: Bool
    @Binding var messageText: String
    @Binding var selectedMessageSender: String?
    @Binding var selectedMessageSenderID: PeerID?
    @Binding var imagePreviewURL: URL?
    @Binding var windowCountPublic: Int
    @Binding var windowCountPrivate: [PeerID: Int]
    @Binding var isAtBottomPrivate: Bool
    var isTextFieldFocused: FocusState<Bool>.Binding
    @ObservedObject var voiceRecordingVM: VoiceRecordingViewModel
    @Binding var autocompleteDebounceTimer: Timer?
    @ThemedPalette private var palette

    let headerHeight: CGFloat
    let onSendMessage: () -> Void

    #if os(iOS)
    @Binding var showImagePicker: Bool
    @Binding var imagePickerSourceType: UIImagePickerController.SourceType
    #else
    @Binding var showMacImagePicker: Bool
    #endif

    var body: some View {
        NavigationStack {
            Group {
                if privateConversationModel.selectedPeerID != nil {
                    #if os(iOS)
                    ContentPrivateChatSheetView(
                        showSidebar: $showSidebar,
                        messageText: $messageText,
                        selectedMessageSender: $selectedMessageSender,
                        selectedMessageSenderID: $selectedMessageSenderID,
                        imagePreviewURL: $imagePreviewURL,
                        windowCountPublic: $windowCountPublic,
                        windowCountPrivate: $windowCountPrivate,
                        isAtBottomPrivate: $isAtBottomPrivate,
                        isTextFieldFocused: isTextFieldFocused,
                        voiceRecordingVM: voiceRecordingVM,
                        autocompleteDebounceTimer: $autocompleteDebounceTimer,
                        headerHeight: headerHeight,
                        onSendMessage: onSendMessage,
                        showImagePicker: $showImagePicker,
                        imagePickerSourceType: $imagePickerSourceType
                    )
                    #else
                    ContentPrivateChatSheetView(
                        showSidebar: $showSidebar,
                        messageText: $messageText,
                        selectedMessageSender: $selectedMessageSender,
                        selectedMessageSenderID: $selectedMessageSenderID,
                        imagePreviewURL: $imagePreviewURL,
                        windowCountPublic: $windowCountPublic,
                        windowCountPrivate: $windowCountPrivate,
                        isAtBottomPrivate: $isAtBottomPrivate,
                        isTextFieldFocused: isTextFieldFocused,
                        voiceRecordingVM: voiceRecordingVM,
                        autocompleteDebounceTimer: $autocompleteDebounceTimer,
                        headerHeight: headerHeight,
                        onSendMessage: onSendMessage,
                        showMacImagePicker: $showMacImagePicker
                    )
                    #endif
                } else {
                    ContentPeopleListView(
                        showSidebar: $showSidebar
                    )
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { appChromeModel.showingFingerprintFor != nil && (showSidebar || privateConversationModel.selectedPeerID != nil) },
                set: { isPresented in
                    if !isPresented {
                        appChromeModel.clearFingerprint()
                    }
                }
            )) {
                if let peerID = appChromeModel.showingFingerprintFor {
                    FingerprintView(peerID: peerID)
                        .environmentObject(verificationModel)
                }
            }
        }
        .themedSheetBackground()
        .foregroundColor(palette.primary)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { showImagePicker && (showSidebar || privateConversationModel.selectedPeerID != nil) },
            set: { newValue in
                if !newValue {
                    showImagePicker = false
                }
            }
        )) {
            ImagePickerView(sourceType: imagePickerSourceType) { image in
                showImagePicker = false
                conversationUIModel.processSelectedImage(image)
            }
            .ignoresSafeArea()
        }
        #endif
        #if os(macOS)
        .sheet(isPresented: $showMacImagePicker) {
            MacImagePickerView { url in
                showMacImagePicker = false
                conversationUIModel.processSelectedImage(from: url)
            }
        }
        #endif
    }
}

private struct ContentPeopleListView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var verificationModel: VerificationModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @Environment(\.dismiss) private var dismiss
    @ThemedPalette private var palette

    @Binding var showSidebar: Bool

    @State private var showVerifySheet = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(peopleSheetTitle)
                        .bitchatFont(size: 18)
                        .foregroundColor(palette.primary)
                    Spacer()
                    if case .mesh = locationChannelsModel.selectedChannel {
                        Button(action: { showVerifySheet = true }) {
                            Image(systemName: "qrcode")
                                .font(.bitchatSystem(size: 14))
                        }
                        .buttonStyle(.plain)
                        // .help maps to the accessibility *hint* on iOS, so the
                        // button still needs a spoken name.
                        .accessibilityLabel(
                            String(localized: "content.accessibility.verification", comment: "Accessibility label for the verification QR button")
                        )
                        .help(
                            String(localized: "content.help.verification", comment: "Help text for verification button")
                        )
                    }
                    SheetCloseButton {
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            dismiss()
                            showSidebar = false
                            showVerifySheet = false
                            privateConversationModel.endConversation()
                        }
                    }
                }

                // The mesh sheet titles its sections inline (#mesh / across
                // the bridge / groups) — no subtitle or count up here.
                // Location channels keep their geohash subtitle.
                if case .location(let channel) = locationChannelsModel.selectedChannel {
                    Text(verbatim: "#\(channel.geohash.lowercased())")
                        .bitchatFont(size: 12)
                        .foregroundColor(palette.locationAccent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .themedSurface()

            ScrollView {
                // spacing 0: every section supplies its own rhythm (header
                // top 12 / bottom 4, rows vertical 4), so inter-child spacing
                // here would make the first section's gap read differently.
                VStack(alignment: .leading, spacing: 0) {
                    if case .location = locationChannelsModel.selectedChannel {
                        GeohashPeopleList(
                            onTapPerson: {
                                showSidebar = true
                            }
                        )
                    } else {
                        PeopleSectionHeader(
                            icon: "antenna.radiowaves.left.and.right",
                            iconColor: palette.accentBlue,
                            title: "#mesh"
                        )
                        MeshPeerList(
                            onTapPeer: { peerID in
                                peerListModel.startConversation(with: peerID)
                                showSidebar = true
                            },
                            onToggleFavorite: { peerID in
                                peerListModel.toggleFavorite(peerID: peerID)
                            },
                            onShowFingerprint: { peerID in
                                appChromeModel.showFingerprint(for: peerID)
                            },
                            onToggleBlock: { peer in
                                if peer.isBlocked {
                                    conversationUIModel.unblock(peerID: peer.peerID, displayName: peer.displayName)
                                } else {
                                    conversationUIModel.block(peerID: peer.peerID, displayName: peer.displayName)
                                }
                            }
                        )
                        // People in this area but beyond radio range, and
                        // private groups: one sheet for the whole room.
                        BridgePeopleList()
                        GroupChatList(
                            groups: peerListModel.groupRows,
                            onTapGroup: { peerID in
                                peerListModel.startConversation(with: peerID)
                                showSidebar = true
                            }
                        )
                    }
                }
                .padding(.top, 4)
                // Full width even when every row is narrow (empty mesh, no
                // groups): without this the VStack hugs its widest child and
                // the ScrollView centers it — headers and empty states
                // floated mid-screen on iPhone.
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(peerListModel.renderID)
            }
        }
        .sheet(isPresented: $showVerifySheet) {
            VerificationSheetView(isPresented: $showVerifySheet)
                .environmentObject(verificationModel)
        }
    }
}

private extension ContentPeopleListView {
    var peopleSheetTitle: String {
        String(localized: "content.header.people", comment: "Title for the people list sheet").lowercased()
    }

}

private struct ContentPrivateChatSheetView: View {
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel

    @Binding var showSidebar: Bool
    @Binding var messageText: String
    @Binding var selectedMessageSender: String?
    @Binding var selectedMessageSenderID: PeerID?
    @Binding var imagePreviewURL: URL?
    @Binding var windowCountPublic: Int
    @Binding var windowCountPrivate: [PeerID: Int]
    @Binding var isAtBottomPrivate: Bool
    var isTextFieldFocused: FocusState<Bool>.Binding
    @ObservedObject var voiceRecordingVM: VoiceRecordingViewModel
    @Binding var autocompleteDebounceTimer: Timer?
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette

    let headerHeight: CGFloat
    let onSendMessage: () -> Void

    #if os(iOS)
    @Binding var showImagePicker: Bool
    @Binding var imagePickerSourceType: UIImagePickerController.SourceType
    #else
    @Binding var showMacImagePicker: Bool
    #endif

    var body: some View {
        VStack(spacing: 0) {
            if let headerState = privateConversationModel.selectedHeaderState {
                HStack(spacing: 12) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            privateConversationModel.endConversation()
                        }
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.bitchatSystem(size: 12))
                            .foregroundColor(palette.primary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(localized: "content.accessibility.back_to_main_chat", comment: "Accessibility label for returning to main chat")
                    )

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        ContentPrivateHeaderInfoButton(
                            headerState: headerState,
                            headerHeight: headerHeight
                        )

                        if headerState.supportsFavoriteToggle {
                            Button(action: {
                                privateConversationModel.toggleFavoriteForSelectedConversation()
                            }) {
                                Image(systemName: headerState.isFavorite ? "star.fill" : "star")
                                    .font(.bitchatSystem(size: 14))
                                    .foregroundColor(headerState.isFavorite ? Color.yellow : palette.primary)
                                    // Same visual box + 44pt hit target as SheetCloseButton.
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle().inset(by: -6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                headerState.isFavorite
                                ? String(localized: "content.accessibility.remove_favorite", comment: "Accessibility label to remove a favorite")
                                : String(localized: "content.accessibility.add_favorite", comment: "Accessibility label to add a favorite")
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Spacer(minLength: 0)

                    SheetCloseButton {
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            privateConversationModel.endConversation()
                            showSidebar = true
                        }
                    }
                }
                // minHeight so scaled text at accessibility sizes grows the
                // bar instead of clipping inside it.
                .frame(minHeight: headerHeight)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .modifier(PrivateHeaderChrome())
            }

            MessageListView(
                privatePeer: privateConversationModel.selectedPeerID,
                isAtBottom: $isAtBottomPrivate,
                messageText: $messageText,
                selectedMessageSender: $selectedMessageSender,
                selectedMessageSenderID: $selectedMessageSenderID,
                imagePreviewURL: $imagePreviewURL,
                windowCountPublic: $windowCountPublic,
                windowCountPrivate: $windowCountPrivate,
                showSidebar: $showSidebar,
                isTextFieldFocused: isTextFieldFocused
            )
            .themedSurface()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Swipe-right-to-leave lives on the message list only. On the
            // whole sheet it preempted the composer's press-and-hold mic
            // gesture (a high-priority ancestor drag cancels child gestures
            // within milliseconds — same starvation as the image-reveal bug).
            .highPriorityGesture(swipeToLeaveGesture)

            if !theme.usesGlassChrome {
                Divider()
            }

            privacyCaption

            #if os(iOS)
            ContentComposerView(
                messageText: $messageText,
                isTextFieldFocused: isTextFieldFocused,
                voiceRecordingVM: voiceRecordingVM,
                autocompleteDebounceTimer: $autocompleteDebounceTimer,
                onSendMessage: onSendMessage,
                showImagePicker: $showImagePicker,
                imagePickerSourceType: $imagePickerSourceType
            )
            #else
            ContentComposerView(
                messageText: $messageText,
                isTextFieldFocused: isTextFieldFocused,
                voiceRecordingVM: voiceRecordingVM,
                autocompleteDebounceTimer: $autocompleteDebounceTimer,
                onSendMessage: onSendMessage,
                showMacImagePicker: $showMacImagePicker
            )
            #endif
        }
        .themedSheetBackground()
        .foregroundColor(palette.primary)
    }

    private var swipeToLeaveGesture: some Gesture {
        DragGesture(minimumDistance: 25, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = abs(value.translation.height)
                guard horizontal > 80, vertical < 60 else { return }
                withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                    showSidebar = true
                    privateConversationModel.endConversation()
                }
            }
    }

    /// Persistent one-line reminder that this composer feeds a private
    /// conversation — the DM sheet otherwise renders identically to the
    /// public timeline. Claims end-to-end encryption only once the session
    /// is actually secured.
    private var privacyCaption: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.fill")
                .font(.bitchatSystem(size: 9))
                // Optical centering: lock.fill's ink is bottom-heavy, so
                // geometric centering reads low next to the caption text.
                .offset(y: -1)
            Text(verbatim: privacyCaptionText)
                .bitchatFont(size: 11, weight: .medium)
        }
        .foregroundColor(Color.orange)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        // The orange text is signature enough; a tinted band here reads as a
        // stray strip against the untinted composer chrome below it, so the
        // caption sits on the same surface as the rest of the bottom chrome.
        .themedSurface()
        .accessibilityElement(children: .combine)
    }

    private var privacyCaptionText: String {
        // Group chats are ChaCha20-Poly1305 sealed to the roster's shared key.
        if privateConversationModel.selectedPeerID?.isGroup == true {
            return String(localized: "content.private.caption_group", comment: "Caption above the group chat composer noting messages are encrypted to group members")
        }
        // Geohash DMs are NIP-17 gift-wrapped — always end-to-end encrypted,
        // even though they carry no Noise session status. Mesh DMs earn the
        // "encrypted" claim only once the Noise handshake has secured.
        let isGeoDM = privateConversationModel.selectedPeerID?.isGeoDM == true
        let noiseSecured: Bool = {
            switch privateConversationModel.selectedHeaderState?.encryptionStatus {
            case .noiseSecured, .noiseVerified: return true
            default: return false
            }
        }()
        if isGeoDM || noiseSecured {
            return String(localized: "content.private.caption_encrypted", comment: "Caption above the private chat composer once the session is end-to-end encrypted")
        }
        return String(localized: "content.private.caption", comment: "Caption above the private chat composer before encryption is established")
    }
}

/// Chrome for the private-chat header. Matrix keeps its orange privacy wash
/// over an opaque themed surface. Glass gets the same floating panel as the
/// main header instead: an orange wash over the backdrop gradient reads as a
/// muddy gray-beige band, and the DM signature is already carried by the
/// orange lock, caption, and composer accents.
private struct PrivateHeaderChrome: ViewModifier {
    @Environment(\.appTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme.usesGlassChrome {
            content.themedChromePanel(edge: .top)
        } else {
            // Orange tint before themedSurface so it layers in front of the
            // opaque themed background rather than behind it.
            content
                .background(Color.orange.opacity(0.06))
                .themedSurface()
        }
    }
}

private struct ContentPrivateHeaderInfoButton: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @ThemedPalette private var palette

    let headerState: PrivateConversationHeaderState
    let headerHeight: CGFloat

    var body: some View {
        Button(action: {
            // A group has no single fingerprint to show.
            guard !headerState.isGroupConversation else { return }
            appChromeModel.showFingerprint(for: headerState.headerPeerID)
        }) {
            HStack(spacing: 6) {
                if headerState.isGroupConversation {
                    Image(systemName: "person.3.fill")
                        .font(.bitchatSystem(size: 14))
                        .foregroundColor(palette.primary)
                        .accessibilityLabel(String(localized: "content.accessibility.group_chat", comment: "Accessibility label for the group chat indicator"))
                } else {
                    switch headerState.availability {
                    case .bluetoothConnected:
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(palette.primary)
                            .accessibilityLabel(String(localized: "content.accessibility.connected_mesh", comment: "Accessibility label for mesh-connected peer indicator"))
                    case .meshReachable:
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(palette.primary)
                            .accessibilityLabel(String(localized: "content.accessibility.reachable_mesh", comment: "Accessibility label for mesh-reachable peer indicator"))
                    case .nostrAvailable:
                        Image(systemName: "globe")
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(.purple)
                            .accessibilityLabel(String(localized: "content.accessibility.available_nostr", comment: "Accessibility label for Nostr-available peer indicator"))
                    case .offline:
                        // Slashed variant of the connected glyph — offline as
                        // the negation of connected, no text label (a leading
                        // one read as part of the name: "sin conexión bob").
                        // VoiceOver still says it.
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(palette.secondary)
                            .accessibilityLabel(String(localized: "mesh_peers.state.offline", comment: "State label for a peer that is not currently reachable"))
                    }
                }

                Text(headerState.displayName)
                    .bitchatFont(size: 16, weight: .medium)
                    .foregroundColor(palette.primary)
                    // Middle truncation keeps the identity suffix visible on
                    // long nicknames instead of wrapping into the fixed-height
                    // header.
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let encryptionStatus = headerState.encryptionStatus,
                   let icon = encryptionStatus.icon {
                    Image(systemName: icon)
                        .font(.bitchatSystem(size: 14))
                        // Optical centering: the lock glyphs' ink is bottom-heavy
                        // (solid body, thin shackle), so geometric centering reads
                        // ~1pt low next to the name. The seal badge is symmetric
                        // and needs no lift.
                        .offset(y: icon.hasPrefix("lock") ? -1 : 0)
                        .foregroundColor(
                            encryptionStatus == .noiseVerified || encryptionStatus == .noiseSecured
                            ? palette.primary
                            : Color.red
                        )
                        .accessibilityLabel(
                            String(
                                format: String(localized: "content.accessibility.encryption_status", comment: "Accessibility label announcing encryption status"),
                                locale: .current,
                                encryptionStatus.accessibilityDescription
                            )
                        )
                }

            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                format: String(localized: "content.accessibility.private_chat_header", comment: "Accessibility label describing the private chat header"),
                locale: .current,
                headerState.displayName
            )
        )
        .accessibilityHint(
            headerState.isGroupConversation
            ? ""
            : String(localized: "content.accessibility.view_fingerprint_hint", comment: "Accessibility hint for viewing encryption fingerprint")
        )
        .frame(minHeight: headerHeight)
    }
}
