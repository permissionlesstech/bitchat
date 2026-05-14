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
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var peerListModel: PeerListModel

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

    let backgroundColor: Color
    let textColor: Color
    let secondaryTextColor: Color
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
                        backgroundColor: backgroundColor,
                        textColor: textColor,
                        secondaryTextColor: secondaryTextColor,
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
                        backgroundColor: backgroundColor,
                        textColor: textColor,
                        secondaryTextColor: secondaryTextColor,
                        headerHeight: headerHeight,
                        onSendMessage: onSendMessage,
                        showMacImagePicker: $showMacImagePicker
                    )
                    #endif
                } else {
                    ContentPeopleListView(
                        showSidebar: $showSidebar,
                        backgroundColor: backgroundColor,
                        textColor: textColor,
                        secondaryTextColor: secondaryTextColor,
                        headerHeight: headerHeight
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
        .background(backgroundColor)
        .foregroundColor(textColor)
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
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @Environment(\.dismiss) private var dismiss

    @Binding var showSidebar: Bool

    let backgroundColor: Color
    let textColor: Color
    let secondaryTextColor: Color
    let headerHeight: CGFloat

    @State private var showVerifySheet = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(peopleSheetTitle)
                        .font(.bitchatSystem(size: 18, design: .monospaced))
                        .foregroundColor(textColor)
                    Spacer()
                    if case .mesh = locationChannelsModel.selectedChannel {
                        Button(action: { showVerifySheet = true }) {
                            Image(systemName: "qrcode")
                                .font(.bitchatSystem(size: 14))
                        }
                        .buttonStyle(.plain)
                        .help(
                            String(localized: "content.help.verification", comment: "Help text for verification button")
                        )
                    }
                    Button(action: {
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            dismiss()
                            showSidebar = false
                            showVerifySheet = false
                            privateConversationModel.endConversation()
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }

                let activeText = String.localizedStringWithFormat(
                    String(localized: "%@ active", comment: "Count of active users in the people sheet"),
                    "\(peopleSheetActiveCount)"
                )

                if let subtitle = peopleSheetSubtitle {
                    let subtitleColor: Color = {
                        switch locationChannelsModel.selectedChannel {
                        case .mesh:
                            return Color.blue
                        case .location:
                            return Color.green
                        }
                    }()

                    HStack(spacing: 6) {
                        Text(subtitle)
                            .foregroundColor(subtitleColor)
                        Text(activeText)
                            .foregroundColor(.secondary)
                    }
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                } else {
                    Text(activeText)
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .background(backgroundColor)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if case .location = locationChannelsModel.selectedChannel {
                        GeohashPeopleList(
                            textColor: textColor,
                            secondaryTextColor: secondaryTextColor,
                            onTapPerson: {
                                showSidebar = true
                            }
                        )
                    } else {
                        MeshPeerList(
                            textColor: textColor,
                            secondaryTextColor: secondaryTextColor,
                            onTapPeer: { peerID in
                                peerListModel.startConversation(with: peerID)
                                showSidebar = true
                            },
                            onToggleFavorite: { peerID in
                                peerListModel.toggleFavorite(peerID: peerID)
                            },
                            onShowFingerprint: { peerID in
                                appChromeModel.showFingerprint(for: peerID)
                            }
                        )
                    }
                }
                .padding(.top, 4)
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

    var peopleSheetSubtitle: String? {
        switch locationChannelsModel.selectedChannel {
        case .mesh:
            return "#mesh"
        case .location(let channel):
            return "#\(channel.geohash.lowercased())"
        }
    }

    var peopleSheetActiveCount: Int {
        switch locationChannelsModel.selectedChannel {
        case .mesh:
            return peerListModel.reachableMeshPeerCount
        case .location:
            return peerListModel.visibleGeohashPeerCount
        }
    }
}

private struct ContentPrivateChatSheetView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
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

    let backgroundColor: Color
    let textColor: Color
    let secondaryTextColor: Color
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
                            .foregroundColor(textColor)
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
                            headerHeight: headerHeight,
                            textColor: textColor
                        )

                        if headerState.supportsFavoriteToggle {
                            Button(action: {
                                privateConversationModel.toggleFavoriteForSelectedConversation()
                            }) {
                                Image(systemName: headerState.isFavorite ? "star.fill" : "star")
                                    .font(.bitchatSystem(size: 14))
                                    .foregroundColor(headerState.isFavorite ? Color.yellow : textColor)
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

                    Button(action: {
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            privateConversationModel.endConversation()
                            showSidebar = true
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .frame(height: headerHeight)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(backgroundColor)
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
            .background(backgroundColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            #if os(iOS)
            ContentComposerView(
                messageText: $messageText,
                isTextFieldFocused: isTextFieldFocused,
                voiceRecordingVM: voiceRecordingVM,
                autocompleteDebounceTimer: $autocompleteDebounceTimer,
                backgroundColor: backgroundColor,
                textColor: textColor,
                secondaryTextColor: secondaryTextColor,
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
                backgroundColor: backgroundColor,
                textColor: textColor,
                secondaryTextColor: secondaryTextColor,
                onSendMessage: onSendMessage,
                showMacImagePicker: $showMacImagePicker
            )
            #endif
        }
        .background(backgroundColor)
        .foregroundColor(textColor)
        .highPriorityGesture(
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
        )
    }
}

private struct ContentPrivateHeaderInfoButton: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel

    let headerState: PrivateConversationHeaderState
    let headerHeight: CGFloat
    let textColor: Color

    var body: some View {
        Button(action: {
            appChromeModel.showFingerprint(for: headerState.headerPeerID)
        }) {
            HStack(spacing: 6) {
                switch headerState.availability {
                case .bluetoothConnected:
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.bitchatSystem(size: 14))
                        .foregroundColor(textColor)
                        .accessibilityLabel(String(localized: "content.accessibility.connected_mesh", comment: "Accessibility label for mesh-connected peer indicator"))
                case .meshReachable:
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.bitchatSystem(size: 14))
                        .foregroundColor(textColor)
                        .accessibilityLabel(String(localized: "content.accessibility.reachable_mesh", comment: "Accessibility label for mesh-reachable peer indicator"))
                case .nostrAvailable:
                    Image(systemName: "globe")
                        .font(.bitchatSystem(size: 14))
                        .foregroundColor(.purple)
                        .accessibilityLabel(String(localized: "content.accessibility.available_nostr", comment: "Accessibility label for Nostr-available peer indicator"))
                case .offline:
                    EmptyView()
                }

                Text(headerState.displayName)
                    .font(.bitchatSystem(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(textColor)

                if let encryptionStatus = headerState.encryptionStatus,
                   let icon = encryptionStatus.icon {
                    Image(systemName: icon)
                        .font(.bitchatSystem(size: 14))
                        .foregroundColor(
                            encryptionStatus == .noiseVerified || encryptionStatus == .noiseSecured
                            ? textColor
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
            String(localized: "content.accessibility.view_fingerprint_hint", comment: "Accessibility hint for viewing encryption fingerprint")
        )
        .frame(height: headerHeight)
    }
}
