//
// ContentView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
#if os(iOS)
import Combine
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
    /// The legacy private-media dialog presents from the root's tree
    /// whenever the people UI isn't a sheet.
    var isLegacyMediaConsentPresented = false
    /// A pane's people popover (the split layout). The root presents it, so
    /// nothing else can present from the root while it is up.
    var isPeoplePopoverPresented = false

    /// Only the split layout puts the legacy-consent dialog in the root's
    /// tree: its trailing pane hosts it whatever it shows, so a pending
    /// request always has a presenter there. In compact the people sheet
    /// hosts it and already defers the root while up; a request left
    /// pending once the sheet closed has no presenter, and waiting on it
    /// would swallow the root alerts.
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
    /// - Parameter isPeoplePopoverPresented: No default: every root alert
    ///   that defers through this state must also wait for the split
    ///   layout's people popover, so its caller says whether one is up.
    @MainActor
    init(
        appChromeModel: AppChromeModel,
        isPeopleSheetPresented: Bool = false,
        isImagePreviewPresented: Bool = false,
        isVerificationSheetPresented: Bool = false,
        isVoiceAlertPresented: Bool = false,
        isMediaPickerPresented: Bool = false,
        isLegacyMediaConsentPresented: Bool = false,
        isPeoplePopoverPresented: Bool
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
/// that sheet means. On the split layout the DM is the trailing pane and the
/// people lists are the panes' popovers, so the sheet's getter turns false
/// while the conversation stays open.
enum PeopleSheetPresentationPolicy {
    static func isPresented(
        isSplitLayout: Bool,
        showSidebar: Bool,
        hasSelectedConversation: Bool
    ) -> Bool {
        !isSplitLayout && (showSidebar || hasSelectedConversation)
    }

    /// A getter that already reads false means SwiftUI is catching up with
    /// our own state (the split layout moved the DM into its pane), not a
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

#if os(iOS)
/// A tap a test host makes on the split layout's people buttons. A SwiftUI
/// button has no control to send an action to, and no accessibility element
/// unless an assistive technology runs, so a test can't press one; it sends
/// the tap through `splitLayoutTestTaps`, and the button's own action runs.
/// The app never sets that.
enum SplitLayoutTestTap: Equatable {
    /// A pane bar's people button: the leading bar's, or the trailing
    /// geohash bar's while it shows.
    case peopleButton(ContentPane)
    /// The open people popover's close button.
    case popoverCloseButton
}

private struct SplitLayoutTestTapsKey: EnvironmentKey {
    static let defaultValue: PassthroughSubject<SplitLayoutTestTap, Never>? = nil
}

extension EnvironmentValues {
    /// Taps a test host sends the split layout; nil in the app.
    var splitLayoutTestTaps: PassthroughSubject<SplitLayoutTestTap, Never>? {
        get { self[SplitLayoutTestTapsKey.self] }
        set { self[SplitLayoutTestTapsKey.self] = newValue }
    }
}
#endif

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
    /// The channel the selection's timeline renders (the single column, and
    /// the split layout's trailing pane), mirrored from its model's
    /// `$channel` without observing its messages; nil until the first value
    /// lands. Composers and panes follow it, never the location selection,
    /// which runs a hop ahead of the timeline.
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
    /// The split layout's leading #mesh timeline, a plain reference: only
    /// the leading pane's list observes it. Without one (previews, test
    /// harnesses) the single column stays.
    @Environment(\.meshPaneTimeline) private var meshPaneTimeline
    /// A test host's taps on the people buttons; nil in the app.
    @Environment(\.splitLayoutTestTaps) private var testTaps
    /// The live layout mode. Presentation bindings read this, never the size
    /// class: SwiftUI runs a departing sheet's setter after the layout has
    /// flipped, and environment values captured in that closure are stale.
    @State private var isSplitLayout = false
    /// The split layout's own state: the last-touched pane, browsing, the
    /// people popover, and what a fold set aside.
    @State private var panes = SplitPaneState()
    /// The panes' frames in window coordinates, where the touch observer
    /// reports touches.
    @State private var leadingPaneFrame: CGRect = .zero
    @State private var trailingPaneFrame: CGRect = .zero
    /// The leading #mesh list's own scroll state: never the trailing list's.
    @State private var isAtBottomMeshPane = true
    @State private var windowCountMeshPane = TransportConfig.uiWindowInitialCountPublic
    /// Set when unfolding moves a focused DM composer out of the sheet: the
    /// conversation whose composer the sheet's dismissal hands focus to.
    @State private var refocusConversationAfterLayoutChange: ConversationID?
    /// Set when unfolding moves an open DM out of the sheet. The pane's list
    /// lands on the latest message, but the departing sheet's list reports
    /// its last row leaving afterwards, which raised a stale jump-to-latest
    /// pill in the pane.
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

    /// The channel the selection's timeline renders: the single column's,
    /// and the split layout's trailing pane's.
    private var timelineChannel: ChannelID {
        publicTimelineChannel
            ?? modelReferences?.publicChatModel.channel
            ?? locationChannelsModel.selectedChannel
    }

    /// Where each composer sends. Single column: the public channel the
    /// timeline shows, and the open DM in the sheet. Split: #mesh, and the
    /// trailing pane's geohash or the DM covering it.
    private var composerTargets: ComposerTargets {
        #if os(iOS)
        if isSplitLayout {
            return .split(
                trailingChannel: trailingContent.composerGeohash(timelineChannel: timelineChannel),
                privatePeer: selectedPrivatePeerID
            )
        }
        // A fold's selection names the channel the single column is about
        // to show; until it lands, the composer already sends there.
        return .single(activeChannel: panes.foldChannel ?? timelineChannel, privatePeer: selectedPrivatePeerID)
        #else
        return .single(activeChannel: timelineChannel, privatePeer: selectedPrivatePeerID)
        #endif
    }

    /// The composer shared content goes into (E11): in the single column the
    /// DM's while one is open, else the public timeline's; split, the
    /// last-touched pane's while it has a conversation, else #mesh's.
    private var shareImportSlot: ComposerSlot {
        #if os(iOS)
        if isSplitLayout {
            return composerTargets.shareImportSlot(preferring: panes.focus == .leading ? .primary : .secondary)
        }
        #endif
        return composerTargets.shareImportSlot(preferring: .secondary)
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

    /// The DM as the trailing pane and the people lists as popovers, instead
    /// of the sheet.
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

    /// A pane's people popover is up (the split layout).
    private var isPeoplePopoverPresented: Bool {
        #if os(iOS)
        return panes.popover != nil
        #else
        return false
        #endif
    }

    private func rootModalPresentationState(
        includingVoiceAlert: Bool
    ) -> ContentRootModalPresentationState {
        ContentRootModalPresentationState(
            appChromeModel: appChromeModel,
            isPeopleSheetPresented: isPeopleSheetPresented,
            isImagePreviewPresented: imagePreviewURL != nil,
            isVerificationSheetPresented: showVerifySheet,
            isVoiceAlertPresented: includingVoiceAlert && voiceRecordingVM.showAlert,
            isMediaPickerPresented: mediaPickRequest != nil,
            isLegacyMediaConsentPresented: ContentRootModalPresentationState.legacyConsentDefersRoot(
                isSplitLayout: isSplitLayoutActive,
                hasPendingRequest: conversationUIModel.legacyPrivateMediaConsentRequest != nil
            ),
            isPeoplePopoverPresented: isPeoplePopoverPresented
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
                    #if os(iOS)
                    // Nothing parked, focused, browsed or popped over outlives
                    // the wipe either (I4).
                    panes.panic(timelineChannel: timelineChannel)
                    #endif
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
        // The split layout's share goes to the last-touched pane's composer.
        .onChange(of: shareImportSlot) { _ in
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
            // The split layout shows the DM in its pane; a stale sidebar
            // flag would pop the people sheet after the next fold.
            if newValue != nil, !isSplitLayoutActive {
                showSidebar = true
            }
        }
        #if os(iOS)
        // As it happens, not at the next render: a touch or a fold right
        // after a DM opens must already see it, and the fold's own ending
        // of the DM must already have been recorded when its report comes.
        .onReceive(privateConversationModel.$selectedPeerID) { peer in
            panes.conversationChanged(to: peer, isSplit: isSplitLayout)
        }
        // A test host's taps on the people buttons (none in the app).
        .background {
            if let testTaps {
                Color.clear.onReceive(testTaps) { tap in
                    perform(tap)
                }
            }
        }
        .onChange(of: locationChannelsModel.selectedChannel) { _ in
            guard !isSplitLayout else { return }
            // The selection as it is now: a change reported a render late
            // must not count as a later one.
            panes.compactSelectionChanged(to: locationChannelsModel.selectedChannel)
        }
        // The previous render's content, through the capture list.
        .onChange(of: trailingContent) { [trailingContent] newContent in
            panes.trailingContentChanged(from: trailingContent, to: newContent)
            // Screenshot routing follows what the trailing pane shows,
            // asynchronous selections included (E10).
            appChromeModel.splitLayoutShowsLocation = SplitLayoutScreenshotPolicy.panesShowLocation(
                isSplit: isSplitLayout,
                trailing: newContent
            )
        }
        .onChange(of: focusedComposer) { slot in
            guard isSplitLayout, let slot else { return }
            panes.composerFocused(slot)
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
        // A popover's fingerprint is its own; while one is up the root
        // shows none (E13).
        .sheet(isPresented: Binding(
            get: {
                appChromeModel.showingFingerprintFor != nil
                    && !isPeopleSheetPresented
                    && !isPeoplePopoverPresented
            },
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
                // A popover the root presents holds the review back.
                get: { sharedContentImportModel.offer != nil && !isPeoplePopoverPresented },
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

    /// iOS: where the width allows two panes (the iPhone Duo's inner
    /// display), #mesh leads and the trailing pane shows the open DM, the
    /// selected geohash or the location-channel picker, split at the hinge;
    /// everywhere else the single column stays, with people and DMs in the
    /// sheet. The trailing pane appears only once isSplitLayout has flipped
    /// as well, so the sheet and the pane never both host the DM in one
    /// frame. macOS keeps the single column alone: a GeometryReader at the
    /// root would change how the window sizes itself to its content.
    @ViewBuilder
    private var adaptiveContent: some View {
        #if os(iOS)
        GeometryReader { proxy in
            // The leading pane needs the pinned #mesh timeline.
            let layout = meshPaneTimeline == nil ? nil : ContentSplitLayout.resolve(
                isRegularWidth: horizontalSizeClass == .regular,
                width: proxy.size.width,
                leadingInset: proxy.safeAreaInsets.leading,
                trailingInset: proxy.safeAreaInsets.trailing,
                division: ContentSplitLayout.division(in: proxy)
            )
            let split = isSplitLayout ? layout : nil
            let corners = topCornerClearance(in: proxy)
            HStack(spacing: 0) {
                // The first child in both modes, so its bar, and the
                // app-wide presentations the bar hosts, outlive a fold.
                appChromePane(split: split, corners: corners)
                    .frame(width: split?.leadingWidth)
                    .background(PaneFrameReader(frame: $leadingPaneFrame))
                if let split {
                    ContentColumnGap(width: split.gapWidth)
                    trailingPane(width: split.trailingWidth, trailingCornerReach: corners.trailing)
                        .frame(width: split.trailingWidth)
                        .background(PaneFrameReader(frame: $trailingPaneFrame))
                }
            }
            .background {
                // Which pane was touched last (E1), from the window: it
                // never competes with the panes' own gestures.
                if split != nil {
                    PaneTouchObserver { point in
                        paneTouched(at: point)
                    }
                }
            }
            .onAppear {
                let isSplit = layout != nil
                isSplitLayout = isSplit
                appChromeModel.setMeshPinnedOnScreen(isSplit)
                appChromeModel.splitLayoutShowsLocation = SplitLayoutScreenshotPolicy.panesShowLocation(
                    isSplit: isSplit,
                    trailing: trailingContent
                )
            }
            .onChange(of: layout != nil) { isSplit in
                handleLayoutModeChange(toSplit: isSplit)
            }
        }
        #else
        publicPane(
            bar: {
                appChromeBar(
                    ContentHeaderView(
                        showSidebar: $showSidebar,
                        showVerifySheet: $showVerifySheet,
                        isNicknameFieldFocused: $isNicknameFieldFocused,
                        headerHeight: headerHeight,
                        headerPeerIconSize: headerPeerIconSize,
                        headerPeerCountFontSize: headerPeerCountFontSize
                    )
                )
            },
            timeline: {
                followingTimelineList(composer: selectedPrivatePeerID == nil ? composers.primary : nil)
            },
            composer: {
                if selectedPrivatePeerID == nil {
                    composerView(for: .primary)
                }
            }
        )
        #endif
    }

    /// A public timeline between its bar and its composer. Matrix: classic
    /// opaque bars with dividers. Glass: the list full-bleed, scrolling
    /// underneath floating chrome panels (safe-area insets), so the
    /// translucency gains usable space instead of losing it.
    @ViewBuilder
    private func publicPane<Bar: View, Timeline: View, Composer: View>(
        @ViewBuilder bar: () -> Bar,
        @ViewBuilder timeline: () -> Timeline,
        @ViewBuilder composer: () -> Composer
    ) -> some View {
        let barContent = bar()
        let timelineContent = timeline()
        let composerContent = composer()
        if usesGlassLayout {
            timelineContent
                .safeAreaInset(edge: .top, spacing: 0) {
                    barContent
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    composerContent
                }
        } else {
            VStack(spacing: 0) {
                barContent

                Divider()

                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        timelineContent
                            .background(palette.background)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }

                Divider()

                composerContent
            }
        }
    }

    /// The bar that carries the app chrome, with the failed-wipe and
    /// connectivity banners and the panic dialog: the single column's, or
    /// the split layout's leading #mesh bar. Only this bar hosts them (E9,
    /// I5).
    private func appChromeBar<Header: View>(_ header: Header) -> some View {
        VStack(spacing: 0) {
            header

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

    /// The selection's timeline: the single column's, and the split
    /// layout's trailing geohash.
    /// - Parameter composer: The composer under it, which its mentions
    ///   type into; nil while that composer isn't on screen.
    private func followingTimelineList(composer: ComposerSession?) -> some View {
        MessageListView(
            privateTarget: nil,
            isAtBottom: $isAtBottomPublic,
            composer: composer,
            selectedMessageSender: $selectedMessageSender,
            selectedMessageSenderID: $selectedMessageSenderID,
            imagePreviewURL: $imagePreviewURL,
            windowCountPublic: $windowCountPublic,
            windowCountPrivate: $windowCountPrivate,
            showSidebar: $showSidebar,
            focusedComposer: $focusedComposer
        )
        #if os(iOS)
        .id(PaneRole.following)
        #endif
    }

    /// The composer of `slot`: that slot's session, conversation, send and
    /// photo button together, so no composer can type into one
    /// conversation and record or pick for another (I1).
    private func composerView(for slot: ComposerSlot) -> some View {
        ContentComposerView(
            session: composers[slot],
            target: composerTargets[slot],
            focus: $focusedComposer,
            voiceRecordingVM: voiceRecordingVM,
            onSend: { send(from: slot) },
            onPickMedia: mediaPicker(for: slot)
        )
    }

    #if os(iOS)
    /// What the split layout's trailing pane shows: the open DM, the
    /// selected geohash, or the picker (idle, or browsing from the
    /// trailing badge).
    private var trailingContent: TrailingPaneContent {
        .resolve(
            conversation: selectedPrivatePeerID,
            channel: timelineChannel,
            isBrowsing: panes.isBrowsing
        )
    }

    /// The single column, or the split layout's leading #mesh pane: its
    /// own bar (the app chrome, a static #mesh badge, mesh people), the
    /// pinned #mesh timeline and a composer that sends to #mesh.
    private func appChromePane(split: ContentSplitLayout?, corners: TopCornerClearance) -> some View {
        let isSplit = split != nil
        return publicPane(
            bar: {
                appChromeBar(
                    ContentHeaderView(
                        showSidebar: $showSidebar,
                        showVerifySheet: $showVerifySheet,
                        isNicknameFieldFocused: $isNicknameFieldFocused,
                        headerHeight: headerHeight,
                        headerPeerIconSize: headerPeerIconSize,
                        headerPeerCountFontSize: headerPeerCountFontSize,
                        leadingCornerReach: corners.leading,
                        // Split, the bar ends at the fold and the trailing
                        // pane's top row meets the trailing corner instead.
                        trailingCornerReach: isSplit ? 0 : corners.trailing,
                        paneChannel: isSplit ? .mesh : nil,
                        onPeopleTap: isSplit ? { peopleButtonTapped(.leading) } : nil,
                        isBadgeStatic: isSplit,
                        defersAlerts: isPeoplePopoverPresented
                    )
                    // Anchored to the whole bar, so it centres in the pane,
                    // off the hinge.
                    .contentPeoplePopover(
                        isPresented: peoplePopoverBinding(.leading),
                        channel: .mesh,
                        paneWidth: split?.leadingWidth ?? 0,
                        onClose: { popoverClosed(.leading) }
                    )
                )
            },
            timeline: {
                if isSplit, let meshPaneTimeline {
                    meshPaneList(meshPaneTimeline)
                } else {
                    // Its composer is hidden while a DM is open: no
                    // mention then.
                    followingTimelineList(composer: selectedPrivatePeerID == nil ? composers.primary : nil)
                }
            },
            composer: {
                // The single column hides it under the DM sheet; the #mesh
                // pane keeps it beside the trailing DM.
                if isSplit || selectedPrivatePeerID == nil {
                    composerView(for: .primary)
                }
            }
        )
    }

    /// The leading pane's #mesh timeline, whatever is selected.
    private func meshPaneList(_ timeline: PublicChatModel) -> some View {
        MessageListView(
            privateTarget: nil,
            isAtBottom: $isAtBottomMeshPane,
            composer: composers.primary,
            selectedMessageSender: $selectedMessageSender,
            selectedMessageSenderID: $selectedMessageSenderID,
            imagePreviewURL: $imagePreviewURL,
            windowCountPublic: $windowCountMeshPane,
            windowCountPrivate: $windowCountPrivate,
            showSidebar: $showSidebar,
            focusedComposer: $focusedComposer
        )
        .environmentObject(timeline)
        .id(PaneRole.mesh)
    }

    /// The trailing pane: the open DM covering the selected geohash, the
    /// geohash with its own bar, timeline and composer, or the picker. The
    /// picker keeps one identity between idle and browsing, so ending
    /// browsing by choosing #mesh neither remounts it nor asks for another
    /// location fix.
    private func trailingPane(width: CGFloat, trailingCornerReach: CGFloat) -> some View {
        Group {
            switch trailingContent {
            case .conversation:
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
            case .channel(let geohash):
                publicPane(
                    bar: {
                        trailingChannelBar(geohash, paneWidth: width, trailingCornerReach: trailingCornerReach)
                    },
                    timeline: {
                        followingTimelineList(composer: composers.secondary)
                    },
                    composer: {
                        composerView(for: .secondary)
                    }
                )
            case .picker(let returnTo):
                LocationChannelsPicker(
                    presentation: .pane(
                        headerHeight: headerHeight,
                        trailingCornerReach: trailingCornerReach,
                        panicEpoch: appChromeModel.panicEpoch
                    ),
                    onChoose: {
                        panes.choseChannel(
                            timelineShowsSelection: locationChannelsModel.selectedChannel == timelineChannel
                        )
                    },
                    onClose: returnTo == nil ? nil : { panes.endBrowsing() }
                )
            }
        }
        // Whatever the pane shows: a request can still be pending after its
        // DM closed, and the root waits on it in this layout.
        .modifier(LegacyPrivateMediaConsentDialog())
    }

    /// The trailing geohash's bar: its badge (back to the picker, to switch
    /// channels), bookmark, share and people. No app chrome: that is the
    /// leading bar's.
    private func trailingChannelBar(
        _ geohash: GeohashChannel,
        paneWidth: CGFloat,
        trailingCornerReach: CGFloat
    ) -> some View {
        ContentHeaderView(
            showSidebar: .constant(false),
            showVerifySheet: .constant(false),
            isNicknameFieldFocused: $isNicknameFieldFocused,
            headerHeight: headerHeight,
            headerPeerIconSize: headerPeerIconSize,
            headerPeerCountFontSize: headerPeerCountFontSize,
            leadingCornerReach: 0,
            trailingCornerReach: trailingCornerReach,
            paneChannel: .location(geohash),
            carriesAppChrome: false,
            onPeopleTap: { peopleButtonTapped(.trailing) },
            onBadgeTap: { panes.browse() }
        )
        .contentPeoplePopover(
            isPresented: peoplePopoverBinding(.trailing),
            channel: .location(geohash),
            paneWidth: paneWidth,
            onClose: { popoverClosed(.trailing) }
        )
    }

    /// A pane's people popover. SwiftUI writes false when it dismisses the
    /// popover itself (a tap outside).
    private func peoplePopoverBinding(_ pane: ContentPane) -> Binding<Bool> {
        Binding(
            get: { panes.popover == pane },
            set: { isPresented in
                if !isPresented {
                    popoverClosed(pane)
                }
            }
        )
    }

    /// A bar's people button: that pane's people, as a popover.
    private func peopleButtonTapped(_ pane: ContentPane) {
        panes.openPopover(pane)
    }

    /// A popover closed itself: its close button, a row's DM, a tap outside.
    private func popoverClosed(_ pane: ContentPane) {
        panes.popoverClosed(pane)
    }

    /// A test host's tap, run as the button it stands for would run it:
    /// only on a button that is on screen.
    private func perform(_ tap: SplitLayoutTestTap) {
        guard isSplitLayout else { return }
        switch tap {
        case .peopleButton(.leading):
            peopleButtonTapped(.leading)
        case .peopleButton(.trailing):
            guard case .channel = trailingContent else { return }
            peopleButtonTapped(.trailing)
        case .popoverCloseButton:
            if let pane = panes.popover {
                popoverClosed(pane)
            }
        }
    }

    /// A touch went down in the window. A touch on something presented
    /// over the panes, a popover included, touches neither pane.
    private func paneTouched(at point: CGPoint) {
        guard isSplitLayout,
              !hasRootModalPresentation,
              let pane = ContentPane.containing(point, leading: leadingPaneFrame, trailing: trailingPaneFrame),
              pane != panes.focus else { return }
        panes.touched(pane)
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
    /// Folding shows the last-touched pane and parks the other; unfolding
    /// restores it (`SplitPaneState`). The DM selection, the drafts and the
    /// scroll positions are state here and survive by construction; what
    /// the old host was presenting cannot follow the DM to the new one, so
    /// it closes.
    private func handleLayoutModeChange(toSplit: Bool) {
        guard toSplit != isSplitLayout else { return }
        let openPeer = selectedPrivatePeerID
        let trailing = trailingContent
        let sheetWasPresented = isPeopleSheetPresented
        // Focus follows the conversation whose composer had it, into
        // whichever slot shows that conversation once the layout changed.
        let focusedConversation = focusedComposer.flatMap { composerTargets[$0]?.conversationID }

        // First, so the departing sheet's setter reads as our own change and
        // leaves the conversation open, and the DM ends below only once its
        // pane has gone.
        isSplitLayout = toSplit
        // Every composer changes host or goes: a hold can't follow (E12).
        voiceRecordingVM.cancelAnyHold()
        appChromeModel.setMeshPinnedOnScreen(toSplit)
        let effects = toSplit
            ? panes.unfold(
                timelineChannel: timelineChannel,
                openPeer: openPeer,
                locationSheetIsUp: appChromeModel.isLocationChannelsSheetPresented,
                canReopen: { privateConversationModel.canReopenConversation(with: $0) }
            )
            : panes.fold(
                trailing: trailing,
                timelineChannel: timelineChannel,
                selection: locationChannelsModel.selectedChannel,
                openPeer: openPeer
            )
        apply(effects)
        // The DM as it now is, should a reopening not have opened.
        panes.conversationChanged(to: selectedPrivatePeerID, isSplit: toSplit)

        // Folding brings a kept DM back in the sheet, the list behind it;
        // anything else must not pop the people sheet.
        let sheetWillBePresented = !toSplit && selectedPrivatePeerID != nil
        showSidebar = sheetWillBePresented
        if sheetWasPresented != sheetWillBePresented {
            // Presented by the sheet, or by the root beside the panes: the
            // other host can't adopt them.
            mediaPickRequest = nil
            imagePreviewURL = nil
            appChromeModel.clearFingerprint()
        }
        appChromeModel.splitLayoutShowsLocation = SplitLayoutScreenshotPolicy.panesShowLocation(
            isSplit: toSplit,
            trailing: trailingContent
        )

        // Best effort: a DM leaving the sheet takes focus to its pane's
        // composer once the sheet has gone; anything else moves slots (a
        // geohash between the trailing pane and the single column, a DM
        // into the sheet as it presents) once the new layout is up.
        let conversationLeavesSheet = toSplit && sheetWasPresented && openPeer != nil
        refocusConversationAfterLayoutChange = conversationLeavesSheet ? focusedConversation : nil
        repinConversationAfterLayoutChange = conversationLeavesSheet
        if !conversationLeavesSheet, let focusedConversation {
            DispatchQueue.main.async {
                focusedComposer = composerTargets.slot(showing: focusedConversation)
            }
        }
    }

    /// Carries out what a fold or unfold asks for, beyond the panes' own
    /// state.
    private func apply(_ effects: SplitPaneState.Effects) {
        if let channel = effects.select {
            locationChannelsModel.select(channel)
        }
        if effects.endsConversation {
            privateConversationModel.endConversation()
        }
        if let peer = effects.reopensConversation {
            privateConversationModel.startConversation(with: peer)
        }
        if effects.closesLocationSheet {
            appChromeModel.isLocationChannelsSheetPresented = false
        }
    }

    /// Only once the departing sheet is gone is the pane's composer the one
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

    /// The selection's timeline moved to another channel.
    private func followTimeline(to channel: ChannelID) {
        guard publicTimelineChannel != channel else { return }
        #if os(iOS)
        let previous = timelineChannel
        publicTimelineChannel = channel
        panes.timelineChannelChanged(from: previous, to: channel)
        #else
        publicTimelineChannel = channel
        #endif
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

#if os(iOS)
/// Keeps `frame` at the view's frame in window coordinates, where the touch
/// observer reports touches (the root hosting view fills the window). It
/// changes only as the layout does.
private struct PaneFrameReader: View {
    @Binding var frame: CGRect

    var body: some View {
        GeometryReader { geometry in
            let global = geometry.frame(in: .global)
            Color.clear
                .onAppear { frame = global }
                .onChange(of: global) { newFrame in
                    frame = newFrame
                }
        }
    }
}
#endif
