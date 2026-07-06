//
// ContentView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import BitFoundation

/// On macOS 14+, disables the default system focus ring on TextFields.
/// On earlier macOS versions and on iOS this is a no-op.
struct FocusEffectDisabledModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct ContentView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var verificationModel: VerificationModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel

    @StateObject private var voiceRecordingVM = VoiceRecordingViewModel()
    @State private var messageText = ""
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appTheme) private var appTheme
    // `showSidebar` (the people/conversation-list sheet latch) lives on
    // `AppChromeModel` so non-view launch code can raise it; see that property.
    @State private var selectedMessageSender: String?
    @State private var selectedMessageSenderID: PeerID?
    @FocusState private var isNicknameFieldFocused: Bool
    @State private var isAtBottomPublic = true
    @State private var isAtBottomPrivate = true
    @State private var autocompleteDebounceTimer: Timer?
    @State private var showVerifySheet = false
    @State private var showLocationNotes = false
    @State private var notesGeohash: String?
    @State private var imagePreviewURL: URL?
    #if os(iOS)
    @State private var showImagePicker = false
    @State private var imagePickerSourceType: UIImagePickerController.SourceType = .camera
    #else
    @State private var showMacImagePicker = false
    #endif
    @ScaledMetric(relativeTo: .body) private var headerHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var headerPeerIconSize: CGFloat = 11
    @ScaledMetric(relativeTo: .subheadline) private var headerPeerCountFontSize: CGFloat = 12
    @State private var windowCountPublic: Int = 300
    @State private var windowCountPrivate: [PeerID: Int] = [:]

    @ThemedPalette private var palette

    private var selectedPrivatePeerID: PeerID? {
        privateConversationModel.selectedPeerID
    }

    private var usesGlassLayout: Bool { appTheme.usesGlassChrome }

    var body: some View {
        mainContent
            .onAppear {
                conversationUIModel.setCurrentColorScheme(colorScheme)
                conversationUIModel.setCurrentTheme(appTheme)
                #if os(macOS)
                DispatchQueue.main.async {
                    isNicknameFieldFocused = false
                    isTextFieldFocused = true
                }
                #endif
            }
            .onChange(of: colorScheme) { newValue in
                conversationUIModel.setCurrentColorScheme(newValue)
            }
            .onChange(of: appTheme) { newValue in
                conversationUIModel.setCurrentTheme(newValue)
            }
        .background(ThemedRootBackground())
        .foregroundColor(palette.primary)
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        #endif
        .onChange(of: selectedPrivatePeerID) { newValue in
            if newValue != nil {
                appChromeModel.showSidebar = true
            }
        }
        .sheet(
            isPresented: Binding(
                get: { appChromeModel.showSidebar || selectedPrivatePeerID != nil },
                set: { isPresented in
                    if !isPresented {
                        appChromeModel.showSidebar = false
                        privateConversationModel.endConversation()
                    }
                }
            )
        ) {
            #if os(iOS)
            ContentPeopleSheetView(
                showSidebar: $appChromeModel.showSidebar,
                messageText: $messageText,
                selectedMessageSender: $selectedMessageSender,
                selectedMessageSenderID: $selectedMessageSenderID,
                imagePreviewURL: $imagePreviewURL,
                windowCountPublic: $windowCountPublic,
                windowCountPrivate: $windowCountPrivate,
                isAtBottomPrivate: $isAtBottomPrivate,
                isTextFieldFocused: $isTextFieldFocused,
                voiceRecordingVM: voiceRecordingVM,
                autocompleteDebounceTimer: $autocompleteDebounceTimer,
                headerHeight: headerHeight,
                onSendMessage: sendMessage,
                showImagePicker: $showImagePicker,
                imagePickerSourceType: $imagePickerSourceType
            )
            #else
            ContentPeopleSheetView(
                showSidebar: $appChromeModel.showSidebar,
                messageText: $messageText,
                selectedMessageSender: $selectedMessageSender,
                selectedMessageSenderID: $selectedMessageSenderID,
                imagePreviewURL: $imagePreviewURL,
                windowCountPublic: $windowCountPublic,
                windowCountPrivate: $windowCountPrivate,
                isAtBottomPrivate: $isAtBottomPrivate,
                isTextFieldFocused: $isTextFieldFocused,
                voiceRecordingVM: voiceRecordingVM,
                autocompleteDebounceTimer: $autocompleteDebounceTimer,
                headerHeight: headerHeight,
                onSendMessage: sendMessage,
                showMacImagePicker: $showMacImagePicker
            )
            #endif
        }
        .sheet(isPresented: $appChromeModel.isAppInfoPresented) {
            AppInfoView()
        }
        .sheet(isPresented: Binding(
            get: { appChromeModel.showingFingerprintFor != nil && !appChromeModel.showSidebar && selectedPrivatePeerID == nil },
            set: { _ in appChromeModel.clearFingerprint() }
        )) {
            if let peerID = appChromeModel.showingFingerprintFor {
                FingerprintView(peerID: peerID)
                    .environmentObject(verificationModel)
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { showImagePicker && !appChromeModel.showSidebar && selectedPrivatePeerID == nil },
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
        .sheet(isPresented: Binding(
            get: { showMacImagePicker && !appChromeModel.showSidebar && selectedPrivatePeerID == nil },
            set: { newValue in
                if !newValue {
                    showMacImagePicker = false
                }
            }
        )) {
            MacImagePickerView { url in
                showMacImagePicker = false
                conversationUIModel.processSelectedImage(from: url)
            }
        }
        #endif
        .sheet(isPresented: Binding(
            get: { imagePreviewURL != nil },
            set: { presenting in
                if !presenting {
                    imagePreviewURL = nil
                }
            }
        )) {
            if let url = imagePreviewURL {
                ImagePreviewView(url: url)
            }
        }
        .alert("Recording Error", isPresented: $voiceRecordingVM.showAlert, actions: {
            Button("common.ok", role: .cancel) {}
            if voiceRecordingVM.state == .permissionDenied {
                Button("location_channels.action.open_settings") {
                    SystemSettings.microphone.open()
                }
            }
        }, message: {
            Text(voiceRecordingVM.state.alertMessage)
        })
        .alert("content.alert.bluetooth_required.title", isPresented: $appChromeModel.showBluetoothAlert) {
            Button("content.alert.bluetooth_required.settings") {
                SystemSettings.bluetooth.open()
            }
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(appChromeModel.bluetoothAlertMessage)
        }
        .onDisappear {
            autocompleteDebounceTimer?.invalidate()
        }
    }

    /// Matrix: classic opaque bars with dividers. Glass: full-bleed message
    /// list scrolling underneath floating chrome panels (safe-area insets),
    /// so the translucency gains usable space instead of losing it.
    @ViewBuilder
    private var mainContent: some View {
        if usesGlassLayout {
            publicMessageList
                .safeAreaInset(edge: .top, spacing: 0) {
                    headerView
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if selectedPrivatePeerID == nil {
                        VStack(spacing: 0) {
                            meshPrivacyCaption
                            composerView
                        }
                    }
                }
        } else {
            VStack(spacing: 0) {
                headerView

                Divider()

                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        publicMessageList
                            .background(palette.background)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }

                Divider()

                if selectedPrivatePeerID == nil {
                    meshPrivacyCaption
                    composerView
                }
            }
        }
    }

    /// Persistent trust caption under the PUBLIC mesh timeline — the parity
    /// twin of the DM sheet's `privacyCaption` (#1366). Moved here out of the
    /// header's non-compressible trailing cluster, where its `.fixedSize` text
    /// overflowed narrow (SE-width) headers. Mesh-only: geohash/location
    /// channels carry no such caption. Muted rather than orange — orange is the
    /// DM privacy signal; this surface is deliberately public.
    @ViewBuilder
    private var meshPrivacyCaption: some View {
        if case .mesh = locationChannelsModel.selectedChannel {
            Text("content.header.public_caption")
                .bitchatFont(size: 11, weight: .medium)
                .foregroundColor(palette.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .themedSurface()
                .accessibilityLabel(Text("content.header.public_caption.a11y"))
        }
    }

    private var headerView: some View {
        ContentHeaderView(
            showSidebar: $appChromeModel.showSidebar,
            showVerifySheet: $showVerifySheet,
            showLocationNotes: $showLocationNotes,
            notesGeohash: $notesGeohash,
            isNicknameFieldFocused: $isNicknameFieldFocused,
            headerHeight: headerHeight,
            headerPeerIconSize: headerPeerIconSize,
            headerPeerCountFontSize: headerPeerCountFontSize
        )
    }

    private var publicMessageList: some View {
        MessageListView(
            privatePeer: nil,
            isAtBottom: $isAtBottomPublic,
            messageText: $messageText,
            selectedMessageSender: $selectedMessageSender,
            selectedMessageSenderID: $selectedMessageSenderID,
            imagePreviewURL: $imagePreviewURL,
            windowCountPublic: $windowCountPublic,
            windowCountPrivate: $windowCountPrivate,
            showSidebar: $appChromeModel.showSidebar,
            isTextFieldFocused: $isTextFieldFocused
        )
    }

    private var composerView: some View {
        #if os(iOS)
        ContentComposerView(
            messageText: $messageText,
            isTextFieldFocused: $isTextFieldFocused,
            voiceRecordingVM: voiceRecordingVM,
            autocompleteDebounceTimer: $autocompleteDebounceTimer,
            onSendMessage: sendMessage,
            showImagePicker: $showImagePicker,
            imagePickerSourceType: $imagePickerSourceType
        )
        #else
        ContentComposerView(
            messageText: $messageText,
            isTextFieldFocused: $isTextFieldFocused,
            voiceRecordingVM: voiceRecordingVM,
            autocompleteDebounceTimer: $autocompleteDebounceTimer,
            onSendMessage: sendMessage,
            showMacImagePicker: $showMacImagePicker
        )
        #endif
    }

    private func sendMessage() {
        guard let trimmed = messageText.trimmedOrNilIfEmpty else { return }

        messageText = ""

        DispatchQueue.main.async {
            self.conversationUIModel.sendMessage(trimmed)
        }
    }
}
