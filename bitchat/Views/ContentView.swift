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

    @StateObject private var voiceRecordingVM = VoiceRecordingViewModel()
    @State private var messageText = ""
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.colorScheme) var colorScheme
    @State private var showSidebar = false
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

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }

    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }

    private var selectedPrivatePeerID: PeerID? {
        privateConversationModel.selectedPeerID
    }

    var body: some View {
        VStack(spacing: 0) {
            ContentHeaderView(
                showSidebar: $showSidebar,
                showVerifySheet: $showVerifySheet,
                showLocationNotes: $showLocationNotes,
                notesGeohash: $notesGeohash,
                isNicknameFieldFocused: $isNicknameFieldFocused,
                headerHeight: headerHeight,
                headerPeerIconSize: headerPeerIconSize,
                headerPeerCountFontSize: headerPeerCountFontSize,
                backgroundColor: backgroundColor,
                textColor: textColor,
                secondaryTextColor: secondaryTextColor
            )
            .onAppear {
                conversationUIModel.setCurrentColorScheme(colorScheme)
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

            Divider()

            GeometryReader { geometry in
                VStack(spacing: 0) {
                    MessageListView(
                        privatePeer: nil,
                        isAtBottom: $isAtBottomPublic,
                        messageText: $messageText,
                        selectedMessageSender: $selectedMessageSender,
                        selectedMessageSenderID: $selectedMessageSenderID,
                        imagePreviewURL: $imagePreviewURL,
                        windowCountPublic: $windowCountPublic,
                        windowCountPrivate: $windowCountPrivate,
                        showSidebar: $showSidebar,
                        isTextFieldFocused: $isTextFieldFocused
                    )
                    .background(backgroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }

            Divider()

            if selectedPrivatePeerID == nil {
                #if os(iOS)
                ContentComposerView(
                    messageText: $messageText,
                    isTextFieldFocused: $isTextFieldFocused,
                    voiceRecordingVM: voiceRecordingVM,
                    autocompleteDebounceTimer: $autocompleteDebounceTimer,
                    backgroundColor: backgroundColor,
                    textColor: textColor,
                    secondaryTextColor: secondaryTextColor,
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
                    backgroundColor: backgroundColor,
                    textColor: textColor,
                    secondaryTextColor: secondaryTextColor,
                    onSendMessage: sendMessage,
                    showMacImagePicker: $showMacImagePicker
                )
                #endif
            }
        }
        .background(backgroundColor)
        .foregroundColor(textColor)
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        #endif
        .onChange(of: selectedPrivatePeerID) { newValue in
            if newValue != nil {
                showSidebar = true
            }
        }
        .sheet(
            isPresented: Binding(
                get: { showSidebar || selectedPrivatePeerID != nil },
                set: { isPresented in
                    if !isPresented {
                        showSidebar = false
                        privateConversationModel.endConversation()
                    }
                }
            )
        ) {
            #if os(iOS)
            ContentPeopleSheetView(
                showSidebar: $showSidebar,
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
                backgroundColor: backgroundColor,
                textColor: textColor,
                secondaryTextColor: secondaryTextColor,
                headerHeight: headerHeight,
                onSendMessage: sendMessage,
                showImagePicker: $showImagePicker,
                imagePickerSourceType: $imagePickerSourceType
            )
            #else
            ContentPeopleSheetView(
                showSidebar: $showSidebar,
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
                backgroundColor: backgroundColor,
                textColor: textColor,
                secondaryTextColor: secondaryTextColor,
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
            get: { appChromeModel.showingFingerprintFor != nil && !showSidebar && selectedPrivatePeerID == nil },
            set: { _ in appChromeModel.clearFingerprint() }
        )) {
            if let peerID = appChromeModel.showingFingerprintFor {
                FingerprintView(peerID: peerID)
                    .environmentObject(verificationModel)
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { showImagePicker && !showSidebar && selectedPrivatePeerID == nil },
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
            get: { showMacImagePicker && !showSidebar && selectedPrivatePeerID == nil },
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

    private func sendMessage() {
        guard let trimmed = messageText.trimmedOrNilIfEmpty else { return }

        messageText = ""

        DispatchQueue.main.async {
            self.conversationUIModel.sendMessage(trimmed)
        }
    }
}
