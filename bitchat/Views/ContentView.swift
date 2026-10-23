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
    var isVerificationSheetPresented = false
    var isVoiceAlertPresented = false
    var isScreenshotPrivacyAlertPresented = false
    var isMediaPickerPresented = false
    /// The legacy private-media dialog presents from the root whenever the
    /// people UI is inline rather than a sheet.
    var isLegacyMediaConsentPresented = false

    var hasPresentation: Bool {
        isPeopleSheetPresented
            || isAppInfoPresented
            || isFingerprintPresented
            || isLocationChannelsSheetPresented
            || isNoticesSheetPresented
            || isImagePreviewPresented
            || isVerificationSheetPresented
            || isVoiceAlertPresented
            || isScreenshotPrivacyAlertPresented
            || isMediaPickerPresented
            || isLegacyMediaConsentPresented
    }
}

extension ContentRootModalPresentationState {
    @MainActor
    init(
        appChromeModel: AppChromeModel,
        isPeopleSheetPresented: Bool = false,
        isImagePreviewPresented: Bool = false,
        isVerificationSheetPresented: Bool = false,
        isVoiceAlertPresented: Bool = false,
        isMediaPickerPresented: Bool = false,
        isLegacyMediaConsentPresented: Bool = false
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
            isVerificationSheetPresented: isVerificationSheetPresented,
            isVoiceAlertPresented: isVoiceAlertPresented,
            isScreenshotPrivacyAlertPresented:
                appChromeModel.showScreenshotPrivacyWarning,
            isMediaPickerPresented: isMediaPickerPresented,
            isLegacyMediaConsentPresented: isLegacyMediaConsentPresented
        )
    }
}

/// What a dismissal reported through the people sheet's binding asks for.
enum PeopleSheetDismissal: Equatable {
    /// Nothing: SwiftUI catching up with our own state.
    case ignore
    /// Close the people list but keep any open conversation selected.
    case closeList
    /// A person leaving: close the list and the conversation.
    case endConversation
}

/// Whether the people/DM UI is up as a modal sheet, and what a dismissal of
/// that sheet means. On a split layout the same UI is an inline column, so
/// the sheet's getter turns false while the conversation stays open.
enum PeopleSheetPresentationPolicy {
    static func isPresented(
        isSplitLayout: Bool,
        showSidebar: Bool,
        hasSelectedConversation: Bool
    ) -> Bool {
        !isSplitLayout && (showSidebar || hasSelectedConversation)
    }

    /// A getter that already reads false means SwiftUI is catching up with
    /// our own state (the split layout moved the DM into its column), not a
    /// person leaving: ending the conversation there would close the DM on
    /// every unfold. Scene/background and alert-presentation reconciliation
    /// (Bluetooth-off, recording errors) are not requests to leave the
    /// conversation either: keeping the DM selected lets the sheet come back
    /// when the app returns from Settings.
    static func dismissal(
        sheetStillPresented: Bool,
        sceneIsActive: Bool,
        alertPending: Bool
    ) -> PeopleSheetDismissal {
        guard sheetStillPresented else { return .ignore }
        return sceneIsActive && !alertPending ? .endConversation : .closeList
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
    @EnvironmentObject private var verificationModel: VerificationModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var sharedContentImportModel: SharedContentImportModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @EnvironmentObject private var publicChatModel: PublicChatModel
    @EnvironmentObject private var privateInboxModel: PrivateInboxModel

    @StateObject private var voiceRecordingVM = VoiceRecordingViewModel()
    @State private var messageText = ""
    /// Conversation the current `messageText` belongs to, so a channel switch
    /// can save under the previous key before loading the next draft.
    @State private var activeDraftKey: ComposerDraftStore.Key = .mesh
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
    @State private var autocompleteDebounceTimer: Timer?
    @State private var showVerifySheet = false
    @State private var imagePreviewURL: URL?
    #if os(iOS)
    @State private var showImagePicker = false
    @State private var imagePickerSourceType: UIImagePickerController.SourceType = .camera
    #else
    @State private var showMacImagePicker = false
    #endif
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Display corners are named by physical side, while the padding that
    /// clears them follows the layout direction (TopCornerClearance).
    @Environment(\.layoutDirection) private var layoutDirection
    /// The live layout mode. Presentation bindings read this, never the size
    /// class: SwiftUI runs a departing sheet's setter after the layout has
    /// flipped, and environment values captured in that closure are stale.
    @State private var isSplitLayout = false
    /// The people column's QR sheet presents through the root, so its state
    /// lives here where the root alerts can defer to it.
    @State private var showColumnVerifySheet = false
    /// Set when unfolding moves a focused DM composer out of the sheet; the
    /// sheet's dismissal hands focus to the column's composer.
    @State private var refocusComposerAfterLayoutChange = false
    /// Set when unfolding moves an open DM out of the sheet. The column's list
    /// lands on the latest message, but the departing sheet's list reports
    /// its last row leaving afterwards, which raised a stale jump-to-latest
    /// pill in the column.
    @State private var repinConversationAfterLayoutChange = false
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

    private var sharedContentDestination: SharedContentDestination {
        SharedContentDestination.resolve(
            selectedPrivatePeerID: selectedPrivatePeerID,
            privateDisplayName: privateConversationModel.selectedHeaderState?.displayName,
            activeChannel: locationChannelsModel.selectedChannel
        )
    }

    private var usesGlassLayout: Bool { appTheme.usesGlassChrome }

    /// People list or DM as a column beside the timeline instead of a sheet.
    private var isSplitLayoutActive: Bool {
        #if os(iOS)
        return isSplitLayout
        #else
        return false
        #endif
    }

    private var isPeopleSheetPresented: Bool {
        PeopleSheetPresentationPolicy.isPresented(
            isSplitLayout: isSplitLayoutActive,
            showSidebar: showSidebar,
            hasSelectedConversation: selectedPrivatePeerID != nil
        )
    }

    private func rootModalPresentationState(
        includingVoiceAlert: Bool
    ) -> ContentRootModalPresentationState {
        #if os(iOS)
        let isMediaPickerPresented = showImagePicker
        let isVerificationSheetPresented = showVerifySheet || showColumnVerifySheet
        #else
        let isMediaPickerPresented = showMacImagePicker
        let isVerificationSheetPresented = showVerifySheet
        #endif

        return ContentRootModalPresentationState(
            appChromeModel: appChromeModel,
            isPeopleSheetPresented: isPeopleSheetPresented,
            isImagePreviewPresented: imagePreviewURL != nil,
            isVerificationSheetPresented: isVerificationSheetPresented,
            isVoiceAlertPresented: includingVoiceAlert && voiceRecordingVM.showAlert,
            isMediaPickerPresented: isMediaPickerPresented,
            // Only the column presents the dialog in the root's tree. In
            // compact the people sheet hosts it and already defers the root
            // while up; a request left pending once it closed has no
            // presenter, and waiting on it would swallow the root alerts.
            isLegacyMediaConsentPresented: isSplitLayoutActive
                && conversationUIModel.legacyPrivateMediaConsentRequest != nil
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

    private var rootImagePreviewBinding: Binding<Bool> {
        Binding(
            get: { imagePreviewURL != nil && !isPeopleSheetPresented },
            set: { presenting in
                if !presenting {
                    imagePreviewURL = nil
                }
            }
        )
    }

    /// The header's people button. On the split layout the list is on screen
    /// unless a DM covers it, so the button leaves the DM instead of toggling
    /// a sheet that can't present there.
    private var headerPeopleBinding: Binding<Bool> {
        Binding(
            get: { showSidebar },
            set: { newValue in
                if isSplitLayoutActive {
                    if selectedPrivatePeerID != nil {
                        privateConversationModel.endConversation()
                    }
                } else {
                    showSidebar = newValue
                }
            }
        )
    }

    var body: some View {
        adaptiveContent
            .onAppear {
                conversationUIModel.setCurrentColorScheme(colorScheme)
                conversationUIModel.setCurrentTheme(appTheme)
                voiceRecordingVM.sessionProvider = { [weak conversationUIModel] in
                    conversationUIModel?.makeVoiceCaptureSession() ?? VoiceNoteCaptureSession()
                }
                appChromeModel.setPanicPreparation { [weak voiceRecordingVM] in
                    voiceRecordingVM?.panicWipe()
                    // Drop in-memory composer text before ChatViewModel resets
                    // persisted drafts — otherwise the next inactive/background
                    // transition would write the pre-wipe draft back.
                    messageText = ""
                    activeDraftKey = .mesh
                }
                #if os(macOS)
                DispatchQueue.main.async {
                    isNicknameFieldFocused = false
                    isTextFieldFocused = true
                }
                #endif
                sharedContentImportModel.updateDestination(sharedContentDestination)
                activeDraftKey = ComposerDraftStore.Key.from(
                    peerID: selectedPrivatePeerID,
                    fingerprint: selectedPrivatePeerID.flatMap { conversationUIModel.getFingerprint(for: $0) },
                    channel: locationChannelsModel.selectedChannel
                )
                messageText = ComposerDraftStore.load(activeDraftKey)
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
            let draftKey = ComposerDraftStore.Key.from(
                peerID: newValue,
                fingerprint: newValue.flatMap { conversationUIModel.getFingerprint(for: $0) },
                channel: locationChannelsModel.selectedChannel
            )
            // A hold records for the conversation it started in, but a voice
            // note is routed by the selection when the hold ends, and a live
            // push-to-talk stream keeps its original target; the composer
            // holding the press may also just have been removed. Compared like
            // drafts, so the same person's peer-ID handoff keeps the hold.
            if draftKey != activeDraftKey, voiceRecordingVM.isHoldInFlight {
                voiceRecordingVM.cancel()
            }
            // The split layout shows the DM in its column; a stale sidebar
            // flag would pop the people sheet after the next fold.
            if newValue != nil, !isSplitLayoutActive {
                showSidebar = true
            }
            #if os(iOS)
            // The column swaps its list, and the QR sheet the list presents,
            // for the DM without a dismissal reaching this flag. Left set, it
            // would hold back the root alerts and bring the QR sheet back
            // with the list.
            if newValue != nil {
                showColumnVerifySheet = false
            }
            #endif
            sharedContentImportModel.updateDestination(sharedContentDestination)
            switchComposerDraft(to: draftKey)
        }
        .onChange(of: locationChannelsModel.selectedChannel) { newChannel in
            sharedContentImportModel.updateDestination(sharedContentDestination)
            // Private drafts are keyed by peer; only public channel switches
            // need a draft swap while no DM is open.
            if selectedPrivatePeerID == nil {
                switchComposerDraft(to: ComposerDraftStore.Key.from(
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
                ComposerDraftStore.save(messageText, for: activeDraftKey)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { isPeopleSheetPresented },
                set: { isPresented in
                    guard !isPresented else { return }
                    switch PeopleSheetPresentationPolicy.dismissal(
                        sheetStillPresented: isPeopleSheetPresented,
                        sceneIsActive: scenePhase == .active,
                        alertPending: appChromeModel.showBluetoothAlert
                            || voiceRecordingVM.showAlert
                    ) {
                    case .ignore:
                        break
                    case .closeList:
                        showSidebar = false
                    case .endConversation:
                        showSidebar = false
                        privateConversationModel.endConversation()
                    }
                }
            ),
            onDismiss: {
                #if os(iOS)
                finishLayoutChangeAfterSheetDismissal()
                #endif
            }
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
                headerHeight: headerHeight,
                onSendMessage: sendMessage,
                showImagePicker: $showImagePicker,
                imagePickerSourceType: $imagePickerSourceType
            )
            // Sheets + NavigationStack can drop inherited EnvironmentObjects on
            // some iOS versions (#1558). Re-inject every model the sheet tree
            // reads so ContentPeopleListView / MessageListView never crash.
            .environmentObject(appChromeModel)
            .environmentObject(privateConversationModel)
            .environmentObject(verificationModel)
            .environmentObject(conversationUIModel)
            .environmentObject(locationChannelsModel)
            .environmentObject(peerListModel)
            .environmentObject(publicChatModel)
            .environmentObject(privateInboxModel)
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
                headerHeight: headerHeight,
                onSendMessage: sendMessage,
                showMacImagePicker: $showMacImagePicker
            )
            .environmentObject(appChromeModel)
            .environmentObject(privateConversationModel)
            .environmentObject(verificationModel)
            .environmentObject(conversationUIModel)
            .environmentObject(locationChannelsModel)
            .environmentObject(peerListModel)
            .environmentObject(publicChatModel)
            .environmentObject(privateInboxModel)
            #endif
        }
        .sheet(isPresented: $appChromeModel.isAppInfoPresented) {
            AppInfoView(
                topologyProvider: { appChromeModel.meshTopologyDisplayModel() },
                onPanicWipe: { appChromeModel.panicClearAllData() }
            )
            .environmentObject(locationChannelsModel)
        }
        .sheet(isPresented: Binding(
            get: { appChromeModel.showingFingerprintFor != nil && !isPeopleSheetPresented },
            set: { _ in appChromeModel.clearFingerprint() }
        )) {
            if let peerID = appChromeModel.showingFingerprintFor {
                FingerprintView(peerID: peerID)
                    .environmentObject(verificationModel)
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { showImagePicker && !isPeopleSheetPresented },
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
            get: { showMacImagePicker && !isPeopleSheetPresented },
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
        // Previews opened from a DM in the people sheet present from inside
        // it: a second root presentation would wait until the sheet closed.
        #if os(iOS)
        // The viewer is a black full-bleed canvas with its own close button;
        // as a sheet it was a card, and a small one on wide displays.
        .fullScreenCover(isPresented: rootImagePreviewBinding) {
            if let url = imagePreviewURL {
                ImagePreviewView(url: url)
            }
        }
        #else
        .sheet(isPresented: rootImagePreviewBinding) {
            if let url = imagePreviewURL {
                ImagePreviewView(url: url)
            }
        }
        #endif
        .alert(Text(String(localized: "voice.error.title", defaultValue: "recording error", comment: "Title of the voice recording error alert")), isPresented: rootVoiceAlertBinding, actions: {
            Button("common.ok", role: .cancel) {}
            if voiceRecordingVM.state == .permissionDenied {
                Button("location_channels.action.open_settings") {
                    SystemSettings.microphone.open()
                }
            }
        }, message: {
            Text(voiceRecordingVM.state.alertMessage)
        })
        .alert("content.alert.bluetooth_required.title", isPresented: rootBluetoothAlertBinding) {
            Button("content.alert.bluetooth_required.settings") {
                // Powered-off needs the radio controls, not the privacy pane.
                (appChromeModel.bluetoothState == .poweredOff
                    ? SystemSettings.bluetoothPower
                    : SystemSettings.bluetooth).open()
            }
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(appChromeModel.bluetoothAlertMessage)
        }
        .alert(
            String(localized: "share_import.review.title", comment: "Title for reviewing content received from the share extension"),
            isPresented: Binding(
                get: { sharedContentImportModel.offer != nil },
                set: { _ in }
            ),
            presenting: sharedContentImportModel.offer
        ) { _ in
            Button("common.cancel", role: .cancel) {
                sharedContentImportModel.cancel(destination: sharedContentDestination)
            }
            Button("share_import.review.use_in_composer") {
                guard let importedText = sharedContentImportModel.confirm(
                    destination: sharedContentDestination
                ) else { return }
                // Replacing is deliberate and called out in the prompt. It
                // avoids combining a stale draft from another conversation
                // with newly shared content.
                messageText = importedText
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
            autocompleteDebounceTimer?.invalidate()
            appChromeModel.setPanicPreparation(nil)
        }
    }

    /// iOS: where the width allows two columns (the iPhone Duo's inner
    /// display), the people list or open DM becomes a column beside the
    /// timeline, split at the hinge; everywhere else the single column stays,
    /// with people and DMs in the sheet. The column appears only once
    /// isSplitLayout has flipped as well, so the sheet and the column never
    /// both host the DM in one frame, and mainContent stays the first child
    /// in both modes so the public timeline keeps its identity and scroll
    /// position. macOS keeps mainContent alone: a GeometryReader at the root
    /// would change how the window sizes itself to its content.
    @ViewBuilder
    private var adaptiveContent: some View {
        #if os(iOS)
        GeometryReader { proxy in
            let layout = ContentSplitLayout.resolve(
                isRegularWidth: horizontalSizeClass == .regular,
                width: proxy.size.width,
                leadingInset: proxy.safeAreaInsets.leading,
                trailingInset: proxy.safeAreaInsets.trailing,
                division: ContentSplitLayout.division(in: proxy)
            )
            let split = isSplitLayout ? layout : nil
            let corners = topCornerClearance(in: proxy)
            HStack(spacing: 0) {
                // Split, the header ends at the fold and the column's top
                // rows meet the trailing corner instead.
                mainContent(
                    headerLeadingCornerReach: corners.leading,
                    headerTrailingCornerReach: split == nil ? corners.trailing : 0
                )
                .frame(width: split?.leadingWidth)
                if let split {
                    ContentColumnGap(width: split.gapWidth)
                    peopleColumn(trailingCornerReach: corners.trailing)
                        .frame(width: split.trailingWidth)
                }
            }
            .onAppear {
                isSplitLayout = layout != nil
                appChromeModel.isPublicTimelineBesideConversation = layout != nil
            }
            .onChange(of: layout != nil) { isSplit in
                handleLayoutModeChange(toSplit: isSplit)
            }
        }
        #else
        mainContent()
        #endif
    }

    /// Matrix: classic opaque bars with dividers. Glass: full-bleed message
    /// list scrolling underneath floating chrome panels (safe-area insets),
    /// so the translucency gains usable space instead of losing it.
    @ViewBuilder
    private func mainContent(
        headerLeadingCornerReach: CGFloat = 0,
        headerTrailingCornerReach: CGFloat = 0
    ) -> some View {
        if usesGlassLayout {
            publicMessageList
                .safeAreaInset(edge: .top, spacing: 0) {
                    headerView(
                        leadingCornerReach: headerLeadingCornerReach,
                        trailingCornerReach: headerTrailingCornerReach
                    )
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if selectedPrivatePeerID == nil {
                        composerView
                    }
                }
        } else {
            VStack(spacing: 0) {
                headerView(
                    leadingCornerReach: headerLeadingCornerReach,
                    trailingCornerReach: headerTrailingCornerReach
                )

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
                    composerView
                }
            }
        }
    }

    private func headerView(
        leadingCornerReach: CGFloat,
        trailingCornerReach: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            ContentHeaderView(
                showSidebar: headerPeopleBinding,
                showVerifySheet: $showVerifySheet,
                isNicknameFieldFocused: $isNicknameFieldFocused,
                headerHeight: headerHeight,
                headerPeerIconSize: headerPeerIconSize,
                headerPeerCountFontSize: headerPeerCountFontSize,
                leadingCornerReach: leadingCornerReach,
                trailingCornerReach: trailingCornerReach
            )

            // Failed-wipe outranks connectivity: "your data may still be
            // here" matters more than "the radio is off".
            if appChromeModel.panicWipeBlocked {
                PanicWipeBlockedBanner()
            }

            if let issue = ConnectivityIssue.resolve(
                bluetoothState: appChromeModel.bluetoothState,
                torBlocked: appChromeModel.torBlocked
            ) {
                ConnectivityStatusBanner(issue: issue)
            }
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
            Button("common.cancel", role: .cancel) {}
        }
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
            showSidebar: $showSidebar,
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

    #if os(iOS)
    private func peopleColumn(trailingCornerReach: CGFloat) -> some View {
        ContentPeopleColumnView(
            showSidebar: $showSidebar,
            showVerifySheet: $showColumnVerifySheet,
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
            showImagePicker: $showImagePicker,
            imagePickerSourceType: $imagePickerSourceType,
            headerHeight: headerHeight,
            trailingCornerReach: trailingCornerReach,
            onSendMessage: sendMessage
        )
    }

    /// How far display corners the safe area leaves uncovered reach into the
    /// top bars; each bar subtracts its own content inset. Zero below iOS
    /// 26, which can't report corners, and on iPhones whose status bar
    /// clears them.
    private func topCornerClearance(in proxy: GeometryProxy) -> TopCornerClearance {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let corners = proxy.containerCornerInsets
            // Named by physical side, right-to-left included.
            return TopCornerClearance(
                topLeft: corners.topLeading,
                topRight: corners.topTrailing,
                safeArea: proxy.safeAreaInsets,
                isRightToLeft: layoutDirection == .rightToLeft
            )
        }
        #endif
        return TopCornerClearance()
    }

    /// Folding, unfolding, rotating or resizing across the split threshold.
    /// The DM selection, the draft and the public scroll position are state
    /// here and survive by construction; what the old host was presenting
    /// cannot follow the DM to the new one, so it closes.
    private func handleLayoutModeChange(toSplit: Bool) {
        guard toSplit != isSplitLayout else { return }
        let conversationMoves = selectedPrivatePeerID != nil
        let sheetWasPresented = isPeopleSheetPresented
        let sheetWillBePresented = !toSplit && conversationMoves
        let composerWasFocused = conversationMoves && isTextFieldFocused

        // First, so the departing sheet's setter reads as our own change and
        // leaves the conversation open.
        isSplitLayout = toSplit
        appChromeModel.isPublicTimelineBesideConversation = toSplit
        // The DM composer changes hosts: the press on its mic is torn down
        // and would never finish the recording.
        if conversationMoves, voiceRecordingVM.isHoldInFlight {
            voiceRecordingVM.cancel()
        }
        // Folding brings an open DM back in the sheet, the list behind it;
        // an idle column must not pop the people sheet.
        showSidebar = sheetWillBePresented
        showColumnVerifySheet = false
        if sheetWasPresented != sheetWillBePresented {
            // Presented by the sheet, or by the root for the column: the
            // other host can't adopt them.
            showImagePicker = false
            imagePreviewURL = nil
            appChromeModel.clearFingerprint()
        }

        // Best effort: on unfolding, the departing sheet's dismissal hands
        // focus to the column's composer; on folding, the sheet's composer
        // mounts as it presents.
        refocusComposerAfterLayoutChange = toSplit && composerWasFocused
        repinConversationAfterLayoutChange = toSplit && conversationMoves
        if !toSplit, composerWasFocused {
            DispatchQueue.main.async {
                isTextFieldFocused = true
            }
        }
    }

    /// Only once the departing sheet is gone is the column's composer the one
    /// field bound to the focus state, and has the sheet's list stopped
    /// reporting where it is scrolled.
    private func finishLayoutChangeAfterSheetDismissal() {
        if repinConversationAfterLayoutChange {
            repinConversationAfterLayoutChange = false
            isAtBottomPrivate = true
        }
        if refocusComposerAfterLayoutChange {
            refocusComposerAfterLayoutChange = false
            isTextFieldFocused = true
        }
    }
    #endif

    private func sendMessage() {
        guard let trimmed = messageText.trimmedOrNilIfEmpty else { return }

        messageText = ""
        ComposerDraftStore.save("", for: activeDraftKey)

        DispatchQueue.main.async {
            self.conversationUIModel.sendMessage(trimmed)
        }
    }

    private func switchComposerDraft(to newKey: ComposerDraftStore.Key) {
        guard newKey != activeDraftKey else { return }
        ComposerDraftStore.save(messageText, for: activeDraftKey)
        activeDraftKey = newKey
        messageText = ComposerDraftStore.load(newKey)
    }
}
