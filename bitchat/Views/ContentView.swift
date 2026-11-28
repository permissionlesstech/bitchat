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

struct ContentRootModalPresentationState {
    var isPeopleSheetPresented = false
    var isAppInfoPresented = false
    var isFingerprintPresented = false
    var isLocationChannelsSheetPresented = false
    var isNoticesSheetPresented = false
    var isImagePreviewPresented = false
    var isVoiceAlertPresented = false
    var isScreenshotPrivacyAlertPresented = false
    var isMediaPickerPresented = false

    var hasPresentation: Bool {
        isPeopleSheetPresented
            || isAppInfoPresented
            || isFingerprintPresented
            || isLocationChannelsSheetPresented
            || isNoticesSheetPresented
            || isImagePreviewPresented
            || isVoiceAlertPresented
            || isScreenshotPrivacyAlertPresented
            || isMediaPickerPresented
    }
}

extension ContentRootModalPresentationState {
    @MainActor
    init(
        appChromeModel: AppChromeModel,
        isPeopleSheetPresented: Bool = false,
        isImagePreviewPresented: Bool = false,
        isVoiceAlertPresented: Bool = false,
        isMediaPickerPresented: Bool = false
    ) {
        self.init(
            isPeopleSheetPresented: isPeopleSheetPresented,
            isAppInfoPresented: appChromeModel.isAppInfoPresented,
            isFingerprintPresented:
                appChromeModel.showingFingerprintFor != nil,
            isLocationChannelsSheetPresented:
                appChromeModel.isLocationChannelsSheetPresented,
            isNoticesSheetPresented:
                appChromeModel.isNoticesSheetPresented,
            isImagePreviewPresented: isImagePreviewPresented,
            isVoiceAlertPresented: isVoiceAlertPresented,
            isScreenshotPrivacyAlertPresented:
                appChromeModel.showScreenshotPrivacyWarning,
            isMediaPickerPresented: isMediaPickerPresented
        )
    }
}

enum MediaPickerMode: Equatable {
    case photoLibrary
    #if os(iOS)
    case camera
    #endif
}

extension View {
    func mediaPickerPresentation(
        mode: Binding<MediaPickerMode?>,
        isActive: Bool,
        conversationUIModel: ConversationUIModel?
    ) -> some View {
        let isPresented = Binding<Bool>(
            get: { mode.wrappedValue != nil && isActive },
            set: { newValue in
                if !newValue {
                    mode.wrappedValue = nil
                }
            }
        )
        #if os(iOS)
        let requestedSourceType: UIImagePickerController.SourceType =
            mode.wrappedValue == .camera ? .camera : .photoLibrary
        let sourceType = ImagePickerView.resolvedSourceType(for: requestedSourceType)
        return fullScreenCover(isPresented: isPresented) {
            ImagePickerView(sourceType: sourceType) { image in
                mode.wrappedValue = nil
                conversationUIModel?.processSelectedImage(image)
            }
            .ignoresSafeArea()
        }
        #else
        return sheet(isPresented: isPresented) {
            MacImagePickerView { url in
                mode.wrappedValue = nil
                conversationUIModel?.processSelectedImage(from: url)
            }
        }
        #endif
    }

    func voiceAndBluetoothAlerts(
        voiceRecordingVM: VoiceRecordingViewModel,
        appChromeModel: AppChromeModel,
        isVoiceAlertPresented: Binding<Bool>,
        isBluetoothAlertPresented: Binding<Bool>
    ) -> some View {
        self
            .alert(
                Text(String(localized: "voice.error.title", defaultValue: "recording error", comment: "Title of the voice recording error alert")),
                isPresented: isVoiceAlertPresented,
                actions: {
                    Button(String(localized: "common.ok"), role: .cancel) {}
                    if voiceRecordingVM.state == .permissionDenied {
                        Button(String(localized: "location_channels.action.open_settings")) {
                            SystemSettings.microphone.open()
                        }
                    }
                },
                message: {
                    Text(voiceRecordingVM.state.alertMessage)
                }
            )
            .alert(String(localized: "content.alert.bluetooth_required.title"), isPresented: isBluetoothAlertPresented) {
                Button(String(localized: "content.alert.bluetooth_required.settings")) {
                    // Powered-off needs the radio controls, not the privacy pane.
                    (appChromeModel.bluetoothState == .poweredOff
                        ? SystemSettings.bluetoothPower
                        : SystemSettings.bluetooth).open()
                }
                Button(String(localized: "common.ok"), role: .cancel) {}
            } message: {
                Text(appChromeModel.bluetoothAlertMessage)
            }
    }
}

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
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var sharedContentImportModel: SharedContentImportModel
    @Environment(\.appEnvironmentModels) private var appEnvironmentModels

    @StateObject private var voiceRecordingVM = VoiceRecordingViewModel()
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appTheme) private var appTheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSidebar = false
    @State private var selectedMessageSender: String?
    @State private var selectedMessageSenderID: PeerID?
    @FocusState private var isNicknameFieldFocused: Bool
    @State private var isAtBottomPublic = true
    @State private var isAtBottomPrivate = true
    @State private var imagePreviewURL: URL?
    @State private var mediaPickerMode: MediaPickerMode?
    @ScaledMetric(relativeTo: .body) private var headerHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var headerPeerIconSize: CGFloat = 11
    @ScaledMetric(relativeTo: .subheadline) private var headerPeerCountFontSize: CGFloat = 12
    @State private var windowCountPublic: Int = TransportConfig.uiWindowInitialCountPublic
    @State private var windowCountPrivate: [PeerID: Int] = [:]
    @State private var topChromeHeight: CGFloat = 0
    @State private var bottomChromeHeight: CGFloat = 0

    @ThemedPalette private var palette

    private var selectedPrivatePeerID: PeerID? {
        privateConversationModel.selectedPeerID
    }

    private var sharedContentDestination: SharedContentDestination {
        SharedContentDestination.resolve(
            selectedPrivatePeerID: selectedPrivatePeerID,
            privateDisplayName: privateConversationModel.selectedHeaderState?.displayName,
            activeChannel: locationChannelsModel.selectedChannel
        )
    }

    private var usesGlassLayout: Bool { appTheme.usesGlassChrome }

    private var isPeopleSheetPresented: Bool {
        showSidebar || selectedPrivatePeerID != nil
    }

    private func rootModalPresentationState(
        includingVoiceAlert: Bool
    ) -> ContentRootModalPresentationState {
        ContentRootModalPresentationState(
            appChromeModel: appChromeModel,
            isPeopleSheetPresented: isPeopleSheetPresented,
            isImagePreviewPresented: imagePreviewURL != nil,
            isVoiceAlertPresented: includingVoiceAlert && voiceRecordingVM.showAlert,
            isMediaPickerPresented: mediaPickerMode != nil
        )
    }

    private var hasRootModalPresentation: Bool {
        rootModalPresentationState(includingVoiceAlert: true).hasPresentation
    }

    /// The voice alert cannot defer to itself: its own binding must keep
    /// reporting `true` while it is the presented modal.
    private var hasRootModalPresentationBesidesVoiceAlert: Bool {
        rootModalPresentationState(includingVoiceAlert: false).hasPresentation
    }

    private var rootBluetoothAlertBinding: Binding<Bool> {
        Binding(
            get: {
                scenePhase == .active
                    && appChromeModel.showBluetoothAlert
                    && !hasRootModalPresentation
            },
            set: { isPresented in
                guard !isPresented,
                      scenePhase == .active,
                      !hasRootModalPresentation else {
                    return
                }
                // SwiftUI can invoke this setter inside a view update (the
                // alert dismisses when a scenePhase change re-evaluates the
                // `get`); publishing synchronously there is undefined
                // behavior, so defer the write one hop.
                Task { @MainActor in
                    appChromeModel.showBluetoothAlert = false
                }
            }
        )
    }

    /// Voice recording errors can surface while the people/DM sheet is up
    /// (recording happens inside the sheet). Presenting the root alert then
    /// would force-dismiss the sheet, so the root copy defers to any other
    /// root modal; the sheet presents its own copy. Mirrors the Bluetooth
    /// alert treatment above.
    private var rootVoiceAlertBinding: Binding<Bool> {
        Binding(
            get: {
                scenePhase == .active
                    && voiceRecordingVM.showAlert
                    && !hasRootModalPresentationBesidesVoiceAlert
            },
            set: { isPresented in
                guard !isPresented,
                      scenePhase == .active,
                      !hasRootModalPresentationBesidesVoiceAlert else {
                    return
                }
                // Same deferral as the Bluetooth alert above: the setter can
                // run inside a view update when the sheet state changes.
                Task { @MainActor in
                    voiceRecordingVM.showAlert = false
                }
            }
        )
    }

    var body: some View {
        mainContent
            .onAppear { [appEnvironmentModels, voiceRecordingVM] in
                let uiModel = appEnvironmentModels?.conversationUIModel
                let draftModel = appEnvironmentModels?.composerDraftModel
                uiModel?.setCurrentColorScheme(colorScheme)
                uiModel?.setCurrentTheme(appTheme)
                voiceRecordingVM.sessionProvider = { [weak uiModel] in
                    uiModel?.makeVoiceCaptureSession() ?? VoiceNoteCaptureSession()
                }
                appChromeModel.setPanicPreparation { [weak voiceRecordingVM, weak draftModel] in
                    voiceRecordingVM?.panicWipe()
                    // Drop in-memory composer text before ChatViewModel resets
                    // persisted drafts — otherwise the next inactive/background
                    // transition would write the pre-wipe draft back.
                    draftModel?.resetForPanic()
                }
                #if os(macOS)
                DispatchQueue.main.async {
                    isNicknameFieldFocused = false
                    isTextFieldFocused = true
                }
                #endif
                sharedContentImportModel.updateDestination(sharedContentDestination)
                let initialKey = ComposerDraftStore.Key.from(
                    peerID: selectedPrivatePeerID,
                    fingerprint: selectedPrivatePeerID.flatMap { uiModel?.getFingerprint(for: $0) },
                    channel: locationChannelsModel.selectedChannel
                )
                draftModel?.loadInitialDraft(for: initialKey)
            }
            .onChange(of: colorScheme) { newValue in
                appEnvironmentModels?.conversationUIModel.setCurrentColorScheme(newValue)
            }
            .onChange(of: appTheme) { newValue in
                appEnvironmentModels?.conversationUIModel.setCurrentTheme(newValue)
            }
        .background(ThemedRootBackground())
        .foregroundColor(palette.primary)
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        #endif
        .onChange(of: selectedPrivatePeerID) { newValue in
            if newValue != nil {
                showSidebar = true
            }
            sharedContentImportModel.updateDestination(sharedContentDestination)
            let uiModel = appEnvironmentModels?.conversationUIModel
            appEnvironmentModels?.composerDraftModel.switchDraft(to: ComposerDraftStore.Key.from(
                peerID: newValue,
                fingerprint: newValue.flatMap { uiModel?.getFingerprint(for: $0) },
                channel: locationChannelsModel.selectedChannel
            ))
        }
        .onChange(of: locationChannelsModel.selectedChannel) { newChannel in
            sharedContentImportModel.updateDestination(sharedContentDestination)
            // Private drafts are keyed by peer; only public channel switches
            // need a draft swap while no DM is open.
            if selectedPrivatePeerID == nil {
                appEnvironmentModels?.composerDraftModel.switchDraft(to: ComposerDraftStore.Key.from(
                    peerID: nil,
                    fingerprint: nil,
                    channel: newChannel
                ))
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background || phase == .inactive {
                // Always save, including empty — clearing the composer must
                // remove the in-memory draft so it does not resurrect on the
                // next switch back into this conversation.
                appEnvironmentModels?.composerDraftModel.saveCurrentDraft()
            }
        }
        .sheet(
            isPresented: Binding(
                get: { isPeopleSheetPresented },
                set: { isPresented in
                    if !isPresented {
                        showSidebar = false
                        // Scene/background and alert-presentation
                        // reconciliation (Bluetooth-off, recording errors)
                        // are not user requests to leave the conversation.
                        // Keep the selected DM so the sheet remains live
                        // when the app returns from Settings.
                        if scenePhase == .active,
                           !appChromeModel.showBluetoothAlert,
                           !voiceRecordingVM.showAlert {
                            privateConversationModel.endConversation()
                        }
                    }
                }
            )
        ) {
            if let models = appEnvironmentModels {
                ContentPeopleSheetView(
                    showSidebar: $showSidebar,
                    draftModel: models.composerDraftModel,
                    selectedMessageSender: $selectedMessageSender,
                    selectedMessageSenderID: $selectedMessageSenderID,
                    imagePreviewURL: $imagePreviewURL,
                    windowCountPrivate: $windowCountPrivate,
                    isAtBottomPrivate: $isAtBottomPrivate,
                    isTextFieldFocused: $isTextFieldFocused,
                    voiceRecordingVM: voiceRecordingVM,
                    headerHeight: headerHeight,
                    onSendMessage: sendMessage,
                    mediaPickerMode: $mediaPickerMode
                )
                // Sheets + NavigationStack can drop inherited EnvironmentObjects on
                // some iOS versions (#1558). Re-inject every model the sheet tree
                // reads so ContentPeopleListView / PrivateMessageListView never crash.
                .installAppEnvironment(models)
            }
        }
        .sheet(isPresented: $appChromeModel.isAppInfoPresented) {
            AppInfoView(
                topologyProvider: { appChromeModel.meshTopologyDisplayModel() },
                onPanicWipe: { appChromeModel.panicClearAllData() }
            )
            .environmentObject(locationChannelsModel)
        }
        .sheet(isPresented: Binding(
            get: { appChromeModel.showingFingerprintFor != nil && !showSidebar && selectedPrivatePeerID == nil },
            set: { _ in appChromeModel.clearFingerprint() }
        )) {
            if let peerID = appChromeModel.showingFingerprintFor,
               let verificationModel = appEnvironmentModels?.verificationModel {
                FingerprintView(peerID: peerID)
                    .environmentObject(verificationModel)
            }
        }
        .mediaPickerPresentation(
            mode: $mediaPickerMode,
            isActive: !showSidebar && selectedPrivatePeerID == nil,
            conversationUIModel: appEnvironmentModels?.conversationUIModel
        )
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
        .voiceAndBluetoothAlerts(
            voiceRecordingVM: voiceRecordingVM,
            appChromeModel: appChromeModel,
            isVoiceAlertPresented: rootVoiceAlertBinding,
            isBluetoothAlertPresented: rootBluetoothAlertBinding
        )
        .alert(
            String(localized: "share_import.review.title", comment: "Title for reviewing content received from the share extension"),
            isPresented: Binding(
                get: { sharedContentImportModel.offer != nil },
                set: { _ in }
            ),
            presenting: sharedContentImportModel.offer
        ) { _ in
            Button(String(localized: "common.cancel"), role: .cancel) {
                sharedContentImportModel.cancel(destination: sharedContentDestination)
            }
            Button(String(localized: "share_import.review.use_in_composer")) {
                guard let importedText = sharedContentImportModel.confirm(
                    destination: sharedContentDestination
                ) else { return }
                // Replacing is deliberate and called out in the prompt. It
                // avoids combining a stale draft from another conversation
                // with newly shared content.
                appEnvironmentModels?.composerDraftModel.replaceText(importedText)
                isTextFieldFocused = true
            }
        } message: { offer in
            let format = String(
                localized: "share_import.review.message",
                comment: "Explains that shared content will replace the named destination's composer and will not be sent automatically"
            )
            Text(String(format: format, offer.destination.displayName) + "\n\n" + offer.payload.preview)
        }
        .onDisappear {
            appEnvironmentModels?.composerDraftModel.cancelAutocompleteDebounce()
            appChromeModel.setPanicPreparation(nil)
        }
    }

    /// Matrix: classic opaque bars with dividers. Glass on iOS 17+/macOS 14+:
    /// full-bleed message list scrolling underneath floating chrome overlays
    /// with explicit scroll content margins, avoiding SwiftUI `.safeAreaInset`
    /// double top-insetting on iOS while preserving full-bleed translucency.
    /// Older OS versions without `.contentMargins` keep single-level
    /// `.safeAreaInset` so programmatic `scrollTo` targets still clear the bar.
    @ViewBuilder
    private var mainContent: some View {
        if usesGlassLayout {
            if #available(iOS 17.0, macOS 14.0, *) {
                publicMessageList
                    .overlay(alignment: .top) {
                        headerView
                            .background(ChromeHeightReader(edge: .top))
                    }
                    .overlay(alignment: .bottom) {
                        if selectedPrivatePeerID == nil {
                            composerView
                                .background(ChromeHeightReader(edge: .bottom))
                        }
                    }
                    .onPreferenceChange(TopChromeHeightKey.self) { height in
                        if abs(topChromeHeight - height) > 0.5 {
                            topChromeHeight = height
                        }
                    }
                    .onPreferenceChange(BottomChromeHeightKey.self) { height in
                        if abs(bottomChromeHeight - height) > 0.5 {
                            bottomChromeHeight = height
                        }
                    }
            } else {
                publicMessageList
                    .safeAreaInset(edge: .top, spacing: 0) {
                        headerView
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if selectedPrivatePeerID == nil {
                            composerView
                        }
                    }
            }
        } else {
            VStack(spacing: 0) {
                headerView

                Divider()

                publicMessageList
                    .background(palette.background)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                if selectedPrivatePeerID == nil {
                    composerView
                }
            }
        }
    }

    private var headerView: some View {
        VStack(spacing: 0) {
            ContentHeaderView(
                showSidebar: $showSidebar,
                isNicknameFieldFocused: $isNicknameFieldFocused,
                headerHeight: headerHeight,
                headerPeerIconSize: headerPeerIconSize,
                headerPeerCountFontSize: headerPeerCountFontSize
            )

            // Failed-wipe outranks connectivity: "your data may still be
            // here" matters more than "the radio is off".
            if appChromeModel.panicWipeBlocked {
                ConnectivityStatusBanner(issue: .panicWipeBlocked)
            }

            if let issue = ConnectivityIssue.resolve(
                bluetoothState: appChromeModel.bluetoothState,
                torBlocked: appChromeModel.torBlocked
            ) {
                ConnectivityStatusBanner(issue: issue)
            }

            NearbyNotesStripView()
        }
        // Hosted here rather than on the logo Text so the pending dialog
        // survives whatever happens to the header chrome.
        .confirmationDialog(
            Text(
                String(localized: "app_info.settings.danger.panic_confirm_title", defaultValue: "wipe all data?", comment: "Title of the confirmation dialog before a panic wipe")
            ),
            isPresented: $appChromeModel.showPanicConfirmation,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                appChromeModel.panicClearAllData()
            } label: {
                Text(
                    String(localized: "app_info.settings.danger.panic_confirm_action", defaultValue: "wipe everything", comment: "Destructive confirmation button that performs the panic wipe")
                )
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        }
    }

    private var usesOverlayChrome: Bool {
        guard usesGlassLayout else { return false }
        if #available(iOS 17.0, macOS 14.0, *) {
            return true
        }
        return false
    }

    private var glassTopContentInset: CGFloat {
        guard usesOverlayChrome else { return 0 }
        return topChromeHeight > 0 ? topChromeHeight : headerHeight + 4
    }

    private var glassBottomContentInset: CGFloat {
        guard usesOverlayChrome, selectedPrivatePeerID == nil else { return 0 }
        return bottomChromeHeight > 0 ? bottomChromeHeight : 58
    }

    private var publicMessageList: some View {
        PublicMessageListView(
            isAtBottom: $isAtBottomPublic,
            selectedMessageSender: $selectedMessageSender,
            selectedMessageSenderID: $selectedMessageSenderID,
            imagePreviewURL: $imagePreviewURL,
            windowCountPublic: $windowCountPublic,
            showSidebar: $showSidebar,
            isTextFieldFocused: $isTextFieldFocused,
            topContentInset: glassTopContentInset,
            bottomContentInset: glassBottomContentInset
        )
    }

    @ViewBuilder
    private var composerView: some View {
        if let draftModel = appEnvironmentModels?.composerDraftModel {
            ContentComposerView(
                draftModel: draftModel,
                isTextFieldFocused: $isTextFieldFocused,
                voiceRecordingVM: voiceRecordingVM,
                onSendMessage: sendMessage,
                mediaPickerMode: $mediaPickerMode
            )
        }
    }

    private func sendMessage() {
        guard let trimmed = appEnvironmentModels?.composerDraftModel.takeMessageToSend() else { return }
        let uiModel = appEnvironmentModels?.conversationUIModel

        DispatchQueue.main.async {
            uiModel?.sendMessage(trimmed)
        }
    }
}

private struct TopChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct BottomChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ChromeHeightReader: View {
    let edge: VerticalEdge

    var body: some View {
        GeometryReader { proxy in
            switch edge {
            case .top:
                Color.clear.preference(key: TopChromeHeightKey.self, value: proxy.size.height)
            case .bottom:
                Color.clear.preference(key: BottomChromeHeightKey.self, value: proxy.size.height)
            }
        }
    }
}
