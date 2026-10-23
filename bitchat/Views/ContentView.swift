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
    /// A pane's people popover (the split layout). The root presents it, so
    /// nothing else can present from the root while it is up.
    var isPeoplePopoverPresented = false

    /// Only the people column puts the legacy-consent dialog in the root's
    /// tree. In compact the people sheet hosts it and already defers the
    /// root while up; a request left pending once the sheet closed has no
    /// presenter, and waiting on it would swallow the root alerts.
    static func legacyConsentDefersRoot(isSplitLayout: Bool, hasPendingRequest: Bool) -> Bool {
        isSplitLayout && hasPendingRequest
    }

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
            || isPeoplePopoverPresented
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
        isLegacyMediaConsentPresented: Bool = false,
        isPeoplePopoverPresented: Bool = false
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
            isLegacyMediaConsentPresented: isLegacyMediaConsentPresented,
            isPeoplePopoverPresented: isPeoplePopoverPresented
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

/// The models the root hands on to its sheets without observing them (I6):
/// each publishes on every message or roster change, and a root observing
/// them would re-render itself, and with it both panes of the split layout,
/// on every one. The views that render them observe them. Set by the app
/// scene; nil where nobody sets it (previews, most test harnesses), and the
/// sheets then inherit the models instead.
struct ContentModelReferences {
    /// The selection's public timeline: the single column's, and the split
    /// layout's trailing pane's.
    let publicChatModel: PublicChatModel
    let privateInboxModel: PrivateInboxModel
    let peerListModel: PeerListModel

    /// Hands the models to a presentation, which can drop inherited
    /// environment objects on some iOS versions (#1558).
    struct Reinjection: ViewModifier {
        let references: ContentModelReferences?

        func body(content: Content) -> some View {
            if let references {
                content
                    .environmentObject(references.publicChatModel)
                    .environmentObject(references.privateInboxModel)
                    .environmentObject(references.peerListModel)
            } else {
                content
            }
        }
    }
}

private struct ContentModelReferencesKey: EnvironmentKey {
    static let defaultValue: ContentModelReferences? = nil
}

extension EnvironmentValues {
    /// The models `ContentView` passes on without observing them.
    var contentModelReferences: ContentModelReferences? {
        get { self[ContentModelReferencesKey.self] }
        set { self[ContentModelReferencesKey.self] = newValue }
    }
}

struct ContentView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var verificationModel: VerificationModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var sharedContentImportModel: SharedContentImportModel
    /// The selection's timeline, the private inbox and the people lists:
    /// plain references, never observed here (I6).
    @Environment(\.contentModelReferences) private var modelReferences

    @StateObject private var voiceRecordingVM = VoiceRecordingViewModel()
    /// Every composer's text, suggestions and target, one session per slot.
    /// Not observed here: each composer observes its own session.
    @StateObject private var composers = ComposerSessions()
    /// The composer with the keyboard.
    @FocusState private var focusedComposer: ComposerSlot?
    /// The channel the public timeline renders, mirrored from its model's
    /// `$channel` without observing its messages; nil until the first value
    /// lands. The primary composer sends there: a composer's target comes
    /// from what its timeline shows, never from the location selection,
    /// which runs ahead of the timeline.
    @State private var publicTimelineChannel: ChannelID?
    /// A composer's camera or library press, with the conversation the pick
    /// goes to. The picker is up while it is set.
    @State private var mediaPickRequest: MediaPickRequest?
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appTheme) private var appTheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSidebar = false
    @State private var selectedMessageSender: String?
    @State private var selectedMessageSenderID: PeerID?
    @FocusState private var isNicknameFieldFocused: Bool
    @State private var isAtBottomPublic = true
    @State private var isAtBottomPrivate = true
    @State private var showVerifySheet = false
    @State private var imagePreviewURL: URL?
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
    /// Set when unfolding moves a focused DM composer out of the sheet: the
    /// conversation whose composer the sheet's dismissal hands focus to.
    @State private var refocusConversationAfterLayoutChange: ConversationID?
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

    /// The channel the public timeline renders.
    private var timelineChannel: ChannelID {
        publicTimelineChannel
            ?? modelReferences?.publicChatModel.channel
            ?? locationChannelsModel.selectedChannel
    }

    /// Where each composer sends: the public channel the timeline shows,
    /// and the open DM in the sheet (or #1792's column).
    private var composerTargets: ComposerTargets {
        .single(
            activeChannel: timelineChannel,
            privatePeer: selectedPrivatePeerID
        )
    }

    /// The composer shared content goes into (E11): the DM's while one is
    /// open, else the public timeline's.
    private var shareImportSlot: ComposerSlot {
        composerTargets.shareImportSlot(preferring: .secondary)
    }

    /// The share review names the conversation of the composer it fills.
    private var sharedContentDestination: SharedContentDestination {
        let target = composerTargets[shareImportSlot] ?? composerTargets.primary
        return SharedContentDestination.resolve(
            selectedPrivatePeerID: target.privatePeer,
            privateDisplayName: privateConversationModel.selectedHeaderState?.displayName,
            activeChannel: target.channel
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
        let isVerificationSheetPresented = showVerifySheet || showColumnVerifySheet
        #else
        let isVerificationSheetPresented = showVerifySheet
        #endif

        return ContentRootModalPresentationState(
            appChromeModel: appChromeModel,
            isPeopleSheetPresented: isPeopleSheetPresented,
            isImagePreviewPresented: imagePreviewURL != nil,
            isVerificationSheetPresented: isVerificationSheetPresented,
            isVoiceAlertPresented: includingVoiceAlert && voiceRecordingVM.showAlert,
            isMediaPickerPresented: mediaPickRequest != nil,
            isLegacyMediaConsentPresented: ContentRootModalPresentationState.legacyConsentDefersRoot(
                isSplitLayout: isSplitLayoutActive,
                hasPendingRequest: conversationUIModel.legacyPrivateMediaConsentRequest != nil
            )
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
                appChromeModel.setPanicPreparation { [weak voiceRecordingVM] in
                    voiceRecordingVM?.panicWipe()
                    // Drop every composer's text, suggestions and keys before
                    // ChatViewModel resets the parked drafts — otherwise the
                    // next inactive/background save would write a pre-wipe
                    // draft back — and point them at what is on screen once
                    // that wipe has landed. A pick still to come names a
                    // pre-wipe conversation.
                    composers.resetForPanic(
                        thenRetargetTo: { composerTargets },
                        fingerprint: { conversationUIModel.getFingerprint(for: $0) }
                    )
                    mediaPickRequest = nil
                }
                #if os(macOS)
                DispatchQueue.main.async {
                    isNicknameFieldFocused = false
                    focusedComposer = .primary
                }
                #endif
                retargetComposers(to: composerTargets)
                sharedContentImportModel.updateDestination(sharedContentDestination)
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
        // The timeline's channel, not its messages: one update per switch.
        // Received in a leaf, so nothing of the timeline is observed here.
        .background {
            if let timeline = modelReferences?.publicChatModel {
                Color.clear.onReceive(timeline.$channel) { channel in
                    followTimeline(to: channel)
                }
            }
        }
        // Every composer follows its conversation in one step (the draft
        // swap and any hand-over), and a hold whose composer changed
        // conversation is cancelled: a live push-to-talk stream keeps the
        // target it started with. Compared like drafts, so the same
        // person's peer-ID handoff keeps the hold.
        .onChange(of: composerTargets) { targets in
            retargetComposers(to: targets)
            sharedContentImportModel.updateDestination(sharedContentDestination)
        }
        // A share names the composer it would fill: when it arrives, and
        // whenever the runtime looks again (the share link, becoming
        // active) and relabels the same share from the selection, which
        // need not be where that composer sends. A label that already
        // matches is left alone, so this settles after one pass.
        .onChange(of: sharedContentImportModel.offer) { _ in
            sharedContentImportModel.updateDestination(sharedContentDestination)
        }
        .onChange(of: selectedPrivatePeerID) { newValue in
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
        }
        #if os(iOS)
        .onChange(of: locationChannelsModel.selectedChannel) { newChannel in
            appChromeModel.splitLayoutShowsLocation = SplitLayoutScreenshotPolicy.columnsShowLocation(
                isSplit: isSplitLayout,
                selectedChannel: newChannel
            )
        }
        #endif
        .onChange(of: scenePhase) { phase in
            if phase == .background || phase == .inactive {
                composers.saveAll()
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
            ContentPeopleSheetView(
                showSidebar: $showSidebar,
                selectedMessageSender: $selectedMessageSender,
                selectedMessageSenderID: $selectedMessageSenderID,
                imagePreviewURL: $imagePreviewURL,
                windowCountPublic: $windowCountPublic,
                windowCountPrivate: $windowCountPrivate,
                isAtBottomPrivate: $isAtBottomPrivate,
                composer: composers.secondary,
                target: composerTargets.secondary,
                focusedComposer: $focusedComposer,
                voiceRecordingVM: voiceRecordingVM,
                headerHeight: headerHeight,
                onSendMessage: { send(from: .secondary) },
                onPickMedia: mediaPicker(for: .secondary),
                mediaPickRequest: $mediaPickRequest
            )
            // Sheets + NavigationStack can drop inherited EnvironmentObjects on
            // some iOS versions (#1558). Re-inject every model the sheet tree
            // reads so ContentPeopleListView / MessageListView never crash.
            .environmentObject(appChromeModel)
            .environmentObject(privateConversationModel)
            .environmentObject(verificationModel)
            .environmentObject(conversationUIModel)
            .environmentObject(locationChannelsModel)
            .modifier(ContentModelReferences.Reinjection(references: modelReferences))
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
        // A pick goes to the conversation recorded at the press, whatever
        // the screen shows by the time it completes.
        #if os(iOS)
        .fullScreenCover(item: rootMediaPickBinding) { request in
            ImagePickerView(sourceType: request.source) { image in
                mediaPickRequest = nil
                conversationUIModel.processSelectedImage(image, to: request.target)
            }
            .ignoresSafeArea()
        }
        #endif
        #if os(macOS)
        .sheet(item: rootMediaPickBinding) { request in
            MacImagePickerView { url in
                mediaPickRequest = nil
                conversationUIModel.processSelectedImage(from: url, to: request.target)
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
                let slot = shareImportSlot
                guard let importedText = sharedContentImportModel.confirm(
                    destination: sharedContentDestination
                ) else { return }
                // Replacing is deliberate and called out in the prompt. It
                // avoids combining a stale draft from another conversation
                // with newly shared content.
                composers[slot].text = importedText
                focusedComposer = slot
            }
        } message: { offer in
            let format = String(
                localized: "share_import.review.message",
                comment: "Explains that shared content will replace the named destination's composer and will not be sent automatically"
            )
            Text(String(format: format, offer.destination.displayName) + "\n\n" + offer.payload.preview)
        }
        .onDisappear {
            appChromeModel.setPanicPreparation(nil)
        }
    }

    /// The root's media picker. While the people sheet is up the sheet
    /// presents it instead: the root can't present over the sheet.
    private var rootMediaPickBinding: Binding<MediaPickRequest?> {
        Binding(
            get: { isPeopleSheetPresented ? nil : mediaPickRequest },
            set: { newValue in
                if newValue == nil {
                    mediaPickRequest = nil
                }
            }
        )
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
                appChromeModel.splitLayoutShowsLocation = SplitLayoutScreenshotPolicy.columnsShowLocation(
                    isSplit: layout != nil,
                    selectedChannel: locationChannelsModel.selectedChannel
                )
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
            privateTarget: nil,
            isAtBottom: $isAtBottomPublic,
            // Its composer is hidden while a DM is open: no mention then.
            composer: selectedPrivatePeerID == nil ? composers.primary : nil,
            selectedMessageSender: $selectedMessageSender,
            selectedMessageSenderID: $selectedMessageSenderID,
            imagePreviewURL: $imagePreviewURL,
            windowCountPublic: $windowCountPublic,
            windowCountPrivate: $windowCountPrivate,
            showSidebar: $showSidebar,
            focusedComposer: $focusedComposer
        )
    }

    private var composerView: some View {
        ContentComposerView(
            session: composers.primary,
            target: composerTargets.primary,
            focus: $focusedComposer,
            voiceRecordingVM: voiceRecordingVM,
            onSend: { send(from: .primary) },
            onPickMedia: mediaPicker(for: .primary)
        )
    }

    #if os(iOS)
    /// The open DM or, without one, the people list.
    @ViewBuilder
    private func peopleColumn(trailingCornerReach: CGFloat) -> some View {
        if selectedPrivatePeerID != nil {
            ContentConversationColumnView(
                showSidebar: $showSidebar,
                selectedMessageSender: $selectedMessageSender,
                selectedMessageSenderID: $selectedMessageSenderID,
                imagePreviewURL: $imagePreviewURL,
                windowCountPublic: $windowCountPublic,
                windowCountPrivate: $windowCountPrivate,
                isAtBottomPrivate: $isAtBottomPrivate,
                composer: composers.secondary,
                target: composerTargets.secondary,
                focusedComposer: $focusedComposer,
                voiceRecordingVM: voiceRecordingVM,
                onPickMedia: mediaPicker(for: .secondary),
                headerHeight: headerHeight,
                trailingCornerReach: trailingCornerReach,
                onSendMessage: { send(from: .secondary) }
            )
        } else {
            // Keeps hosting its own QR sheet, as in the people sheet, and
            // the consent dialog the column always had.
            ContentPeopleListView(
                showSidebar: $showSidebar,
                showVerifySheet: $showColumnVerifySheet,
                presentation: .column(
                    headerHeight: headerHeight,
                    trailingCornerReach: trailingCornerReach
                )
            )
            .modifier(LegacyPrivateMediaConsentDialog())
        }
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
        // Focus follows the conversation whose composer had it, into
        // whichever slot shows that conversation once the layout changed.
        let focusedConversation: ConversationID? = conversationMoves
            ? focusedComposer.flatMap { composerTargets[$0]?.conversationID }
            : nil

        // First, so the departing sheet's setter reads as our own change and
        // leaves the conversation open.
        isSplitLayout = toSplit
        appChromeModel.splitLayoutShowsLocation = SplitLayoutScreenshotPolicy.columnsShowLocation(
            isSplit: toSplit,
            selectedChannel: locationChannelsModel.selectedChannel
        )
        // The DM composer changes hosts: the press on its mic is torn down
        // and would never finish the recording.
        if conversationMoves {
            voiceRecordingVM.cancel(owner: .secondary)
        }
        // Folding brings an open DM back in the sheet, the list behind it;
        // an idle column must not pop the people sheet.
        showSidebar = sheetWillBePresented
        showColumnVerifySheet = false
        if sheetWasPresented != sheetWillBePresented {
            // Presented by the sheet, or by the root for the column: the
            // other host can't adopt them.
            mediaPickRequest = nil
            imagePreviewURL = nil
            appChromeModel.clearFingerprint()
        }

        // Best effort: on unfolding, the departing sheet's dismissal hands
        // focus to the column's composer; on folding, the sheet's composer
        // mounts as it presents.
        refocusConversationAfterLayoutChange = toSplit ? focusedConversation : nil
        repinConversationAfterLayoutChange = toSplit && conversationMoves
        if !toSplit, let focusedConversation {
            DispatchQueue.main.async {
                focusedComposer = composerTargets.slot(showing: focusedConversation)
            }
        }
    }

    /// Only once the departing sheet is gone is the column's composer the one
    /// field bound to its slot's focus, and has the sheet's list stopped
    /// reporting where it is scrolled.
    private func finishLayoutChangeAfterSheetDismissal() {
        if repinConversationAfterLayoutChange {
            repinConversationAfterLayoutChange = false
            isAtBottomPrivate = true
        }
        if let conversation = refocusConversationAfterLayoutChange {
            refocusConversationAfterLayoutChange = nil
            focusedComposer = composerTargets.slot(showing: conversation)
        }
    }
    #endif

    /// The public timeline moved to another channel.
    private func followTimeline(to channel: ChannelID) {
        guard publicTimelineChannel != channel else { return }
        publicTimelineChannel = channel
    }

    /// Points every composer at its conversation, and cancels a mic hold
    /// whose composer now shows another one.
    private func retargetComposers(to targets: ComposerTargets) {
        composers.retarget(
            targets,
            fingerprint: { conversationUIModel.getFingerprint(for: $0) },
            cancellingHoldsOn: voiceRecordingVM
        )
    }

    /// Sends `slot`'s text to that composer's conversation, both taken now:
    /// a selection change before it goes out can't redirect it.
    private func send(from slot: ComposerSlot) {
        composers.send(from: slot, through: conversationUIModel)
    }

    /// A composer's photo button: records the composer's conversation with
    /// the source and puts the picker up.
    #if os(iOS)
    private func mediaPicker(for slot: ComposerSlot) -> (UIImagePickerController.SourceType) -> Void {
        { [composers] source in
            guard let request = composers.mediaPickRequest(from: slot, source: source) else { return }
            mediaPickRequest = request
        }
    }
    #else
    private func mediaPicker(for slot: ComposerSlot) -> () -> Void {
        { [composers] in
            guard let request = composers.mediaPickRequest(from: slot) else { return }
            mediaPickRequest = request
        }
    }
    #endif
}
