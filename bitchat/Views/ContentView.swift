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
    /// The legacy private-media dialog presents from the root's tree (the
    /// split layout) and is showing, or about to: nothing else is.
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
    ///
    /// One precedence rule (I5): every other root presentation goes before
    /// the dialog, and whatever is on screen first keeps it. The dialog
    /// takes the screen only while nothing else is presented from the root
    /// (`legacyConsentMayTakeScreen`), and only once it has does it hold
    /// the root back. A request arriving under a sheet or an alert waits its
    /// turn instead of taking it down; a presentation flagged while the
    /// dialog shows (a screenshot's warning, a Bluetooth alert) waits for
    /// its answer, since presenting over it fails and loses its flag. The
    /// two never wait on each other.
    /// - Parameter isOnScreen: The pending request is the one the dialog
    ///   has put on screen.
    static func legacyConsentDefersRoot(
        isSplitLayout: Bool,
        hasPendingRequest: Bool,
        isOnScreen: Bool
    ) -> Bool {
        isSplitLayout && hasPendingRequest && isOnScreen
    }

    /// Whether the split layout's consent dialog may take the screen: a
    /// request is pending and nothing else is presented from the root, or
    /// flagged to be.
    static func legacyConsentMayTakeScreen(
        isSplitLayout: Bool,
        hasPendingRequest: Bool,
        hasOtherPresentation: Bool
    ) -> Bool {
        isSplitLayout && hasPendingRequest && !hasOtherPresentation
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
    #if os(iOS)
    /// The split layout's leading #mesh timeline (`AppRuntime
    /// .meshPaneTimeline`): only the leading pane's list observes it.
    /// Without one (previews, most test harnesses) the single column
    /// stays. No presentation renders it, so it is never reinjected.
    var meshPaneTimeline: PublicChatModel?
    #endif

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

extension ContentModelReferences {
    /// The app scene's: the runtime's models.
    @MainActor
    init(runtime: AppRuntime) {
        self.init(
            publicChatModel: runtime.publicChatModel,
            privateInboxModel: runtime.privateInboxModel,
            peerListModel: runtime.peerListModel
        )
        #if os(iOS)
        meshPaneTimeline = runtime.meshPaneTimeline
        #endif
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
/// unless an assistive technology runs, so a test can't press one. It sends
/// the tap through `splitLayoutTestTaps` instead, and ContentView runs the
/// very action it hands that button (or the popover's close button): a
/// wiring mistake on ContentView's side fails the test, though the press
/// itself is left to the device. The app never sets that.
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
    private var meshPaneTimeline: PublicChatModel? { modelReferences?.meshPaneTimeline }
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
    /// The consent request the split layout's dialog has put on screen.
    /// Whatever is up first keeps the screen (I5): a presentation flagged
    /// while the dialog shows waits for its answer, as the dialog waits for
    /// one already up. Compared with the pending request, so it lapses once
    /// that is answered.
    @State private var legacyConsentOnScreen: UUID?
    /// Whether the window presents anything, one on its way out included.
    @State private var windowPresentation = WindowPresentationProbe()
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
        composerTargets(openPeer: selectedPrivatePeerID)
    }

    /// `composerTargets` with `openPeer` as the open DM: a `$selectedPeerID`
    /// report brings the new one before the model holds it.
    private func composerTargets(openPeer: PeerID?) -> ComposerTargets {
        #if os(iOS)
        if isSplitLayout {
            // A geohash DM keeps the scope it opened with, never the
            // timeline under it.
            return panes.composerTargets(trailing: trailingContent(openPeer: openPeer), openPeer: openPeer)
        }
        // A fold's selection names the channel the single column is about
        // to show; until it lands, the composer already sends there.
        return .single(activeChannel: panes.foldChannel ?? timelineChannel, privatePeer: openPeer)
        #else
        return .single(activeChannel: timelineChannel, privatePeer: openPeer)
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

    /// The split layout's legacy-media consent dialog is on screen: the
    /// pending request is the one it put there (`legacyConsentOnScreen`).
    /// The trailing pane presents it from the root's tree, so only then do
    /// the root's alerts, the touch observer and the leading bar's
    /// screenshot warning wait for it (`legacyConsentDefersRoot`).
    private var isLegacyConsentShowingAtRoot: Bool {
        #if os(iOS)
        let request = conversationUIModel.legacyPrivateMediaConsentRequest
        return ContentRootModalPresentationState.legacyConsentDefersRoot(
            isSplitLayout: isSplitLayout,
            hasPendingRequest: request != nil,
            isOnScreen: request != nil && request?.id == legacyConsentOnScreen
        )
        #else
        return false
        #endif
    }

    #if os(iOS)
    /// Something other than the split layout's consent dialog is presented
    /// from the root, or flagged to be: a root sheet or alert, the share
    /// review, the Bluetooth alert, the panic dialog, a people popover.
    /// Each goes before the dialog.
    private var hasRootPresentationBesidesConsent: Bool {
        rootModalPresentationState(includingVoiceAlert: true, includingLegacyConsent: false).hasPresentation
            || sharedContentImportModel.offer != nil
            || (scenePhase == .active && appChromeModel.showBluetoothAlert)
            || appChromeModel.showPanicConfirmation
    }

    /// The pending request while the split layout's dialog may take the
    /// screen (`legacyConsentMayTakeScreen`).
    private var legacyConsentRequestMayTakeScreen: UUID? {
        let request = conversationUIModel.legacyPrivateMediaConsentRequest
        guard ContentRootModalPresentationState.legacyConsentMayTakeScreen(
            isSplitLayout: isSplitLayout,
            hasPendingRequest: request != nil,
            hasOtherPresentation: hasRootPresentationBesidesConsent
        ) else { return nil }
        return request?.id
    }

    /// Puts `requestID` on screen once the window has finished taking down
    /// whatever it presented. SwiftUI says nothing when a presentation it
    /// took down has left, and a dialog presented before then fails ("an
    /// alert is already presented") and can leave one on screen that it no
    /// longer tracks. Looked at again every tenth of a second while the
    /// request may still take the screen.
    private func takeScreenForLegacyConsent(_ requestID: UUID?) {
        guard let requestID, requestID != legacyConsentOnScreen else { return }
        guard !windowPresentation.isPresenting else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard legacyConsentRequestMayTakeScreen == requestID else { return }
                takeScreenForLegacyConsent(requestID)
            }
            return
        }
        legacyConsentOnScreen = requestID
    }
    #endif

    private func rootModalPresentationState(
        includingVoiceAlert: Bool,
        includingLegacyConsent: Bool = true
    ) -> ContentRootModalPresentationState {
        ContentRootModalPresentationState(
            appChromeModel: appChromeModel,
            isPeopleSheetPresented: isPeopleSheetPresented,
            isImagePreviewPresented: imagePreviewURL != nil,
            isVerificationSheetPresented: showVerifySheet,
            isVoiceAlertPresented: includingVoiceAlert && voiceRecordingVM.showAlert,
            isMediaPickerPresented: mediaPickRequest != nil,
            isLegacyMediaConsentPresented: includingLegacyConsent && isLegacyConsentShowingAtRoot,
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
                #if os(iOS)
                // Screenshot routing asks the panes as they are (E10): #mesh
                // leads and shows no place, so the trailing pane decides.
                // Nil for the single column, where the selection and the DM
                // sheet decide.
                appChromeModel.setSplitLayoutScreenshotProbe {
                    isSplitLayout ? trailingContent.showsLocation : nil
                }
                #endif
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
        // person's peer-ID handoff keeps the hold. The handlers that change
        // what the panes show retarget at once (`panesChanged`); this is
        // the backstop, as SwiftUI skips an onChange past two changes in
        // one frame.
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
        // Every refresh republishes the selection, and a peer-ID handoff
        // reports the same person under another ID: neither opens a DM.
        .onReceive(privateConversationModel.$selectedPeerID) { peer in
            conversationReported(peer)
        }
        // A DM chosen from a list is a DM opening (E1) even when it is the
        // one open already, which the selection doesn't report again.
        .onReceive(privateConversationModel.conversationChosen) { _ in
            guard isSplitLayout else { return }
            changePanes { panes.conversationChosen() }
        }
        // Typing counts as a touch in its composer's pane (E1): keystrokes
        // land in the keyboard's window, which the touch observer never
        // sees. Received in a leaf, so the root observes no session.
        .background {
            Color.clear
                .onReceive(composers.primary.edits) { _ in
                    composerEdited(.primary)
                }
                .onReceive(composers.secondary.edits) { _ in
                    composerEdited(.secondary)
                }
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
            // The selection as it is now: a change reported a render late
            // must not count as a later one.
            let selection = locationChannelsModel.selectedChannel
            if isSplitLayout {
                changePanes { panes.splitSelectionChanged(to: selection) }
            } else {
                panes.compactSelectionChanged(to: selection)
            }
        }
        // The previous render's content, through the capture list. The
        // backstop to `panesChanged`, as for the composers' targets.
        .onChange(of: trailingContent) { [trailingContent] newContent in
            panes.trailingContentChanged(from: trailingContent, to: newContent)
        }
        .onChange(of: focusedComposer) { slot in
            guard isSplitLayout, let slot else { return }
            panes.composerFocused(slot)
        }
        // The split layout's consent dialog takes the screen once nothing
        // else holds it, and keeps it until it is answered.
        .onChange(of: legacyConsentRequestMayTakeScreen) { requestID in
            takeScreenForLegacyConsent(requestID)
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
        // shows none (E13). Nor over the split layout's consent dialog.
        .sheet(isPresented: Binding(
            get: {
                appChromeModel.showingFingerprintFor != nil
                    && !isPeopleSheetPresented
                    && !isPeoplePopoverPresented
                    && !isLegacyConsentShowingAtRoot
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
                // A popover the root presents holds the review back, as
                // does the split layout's consent dialog once it shows: the
                // review would fail over it.
                get: {
                    sharedContentImportModel.offer != nil
                        && !isPeoplePopoverPresented
                        && !isLegacyConsentShowingAtRoot
                },
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
            #if os(iOS)
            appChromeModel.setSplitLayoutScreenshotProbe(nil)
            #endif
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
                appChromePane(isSplit: split != nil, leadingWidth: split?.leadingWidth, corners: corners)
                    // One container per pane, so VoiceOver reads one
                    // conversation at a time instead of across the hinge
                    // row by row. Unconditional: this pane keeps one
                    // identity across folds, and as the single column it
                    // is the only container.
                    .accessibilityElement(children: .contain)
                    .frame(width: split?.leadingWidth)
                    .background(PaneFrameReader(frame: $leadingPaneFrame))
                if let split {
                    ContentColumnGap(width: split.gapWidth)
                    trailingPane(width: split.trailingWidth, trailingCornerReach: corners.trailing)
                        .accessibilityElement(children: .contain)
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
            .background(WindowPresentationProbeView(probe: windowPresentation))
            .onAppear {
                let isSplit = layout != nil
                changePanes { isSplitLayout = isSplit }
                appChromeModel.setMeshPinnedOnScreen(isSplit)
            }
            .onChange(of: layout != nil) { isSplit in
                handleLayoutModeChange(toSplit: isSplit)
            }
        }
        #else
        appChromePane(isSplit: false, leadingWidth: nil, corners: TopCornerClearance())
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

    /// The composer of `slot`: that slot's session (its text and
    /// conversation), send and photo button together, so no composer can
    /// type into one conversation and record or pick for another (I1).
    private func composerView(for slot: ComposerSlot) -> some View {
        ContentComposerView(
            session: composers[slot],
            focus: $focusedComposer,
            voiceRecordingVM: voiceRecordingVM,
            onSend: { send(from: slot) },
            onPickMedia: mediaPicker(for: slot)
        )
    }

    /// The single column, or the split layout's leading #mesh pane: its
    /// own bar (the app chrome, a static #mesh badge, mesh people), the
    /// pinned #mesh timeline and a composer that sends to #mesh. macOS has
    /// only the single column.
    /// - Parameter leadingWidth: Split, the pane's width, which its people
    ///   popover stays within.
    private func appChromePane(isSplit: Bool, leadingWidth: CGFloat?, corners: TopCornerClearance) -> some View {
        publicPane(
            bar: {
                #if os(iOS)
                let onPeopleTap = peopleTap(.leading)
                #else
                let onPeopleTap: (() -> Void)? = nil
                #endif
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
                        onPeopleTap: onPeopleTap,
                        defersAlerts: { isPeoplePopoverPresented || isLegacyConsentShowingAtRoot }
                    )
                    #if os(iOS)
                    // Anchored to the whole bar, so it centres in the pane,
                    // off the hinge.
                    .contentPeoplePopover(
                        isPresented: peoplePopoverBinding(.leading),
                        channel: .mesh,
                        paneWidth: leadingWidth ?? 0,
                        onClose: popoverClose(.leading)
                    )
                    #endif
                )
            },
            timeline: {
                #if os(iOS)
                if isSplit, let meshPaneTimeline {
                    meshPaneList(meshPaneTimeline)
                } else {
                    // Its composer is hidden while a DM is open: no
                    // mention then.
                    followingTimelineList(composer: selectedPrivatePeerID == nil ? composers.primary : nil)
                }
                #else
                followingTimelineList(composer: selectedPrivatePeerID == nil ? composers.primary : nil)
                #endif
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

    #if os(iOS)
    /// What the split layout's trailing pane shows: the open DM, the
    /// selected geohash, or the picker (idle, or browsing from the
    /// trailing badge).
    private var trailingContent: TrailingPaneContent {
        trailingContent(openPeer: selectedPrivatePeerID)
    }

    /// `trailingContent` with `openPeer` as the open DM, as for
    /// `composerTargets(openPeer:)`.
    private func trailingContent(openPeer: PeerID?) -> TrailingPaneContent {
        panes.trailingContent(
            openPeer: openPeer,
            timelineChannel: timelineChannel,
            selection: locationChannelsModel.selectedChannel
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
    /// geohash with its own bar, timeline and composer, the picker, or a
    /// placeholder while a selected geohash lands. The picker keeps one
    /// identity between idle and browsing, so ending browsing by choosing
    /// #mesh neither remounts it nor asks for another location fix.
    private func trailingPane(width: CGFloat, trailingCornerReach: CGFloat) -> some View {
        Group {
            switch trailingContent {
            case .conversation:
                ContentPrivateChatSheetView(
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
                    isInline: true,
                    trailingCornerReach: trailingCornerReach
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
            case .landing:
                // A geohash on its way: the pane's own background and
                // nothing to read, rather than a picker mounting (and
                // asking for a location fix) for a pane about to show it.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .themedSurface()
                    .accessibilityHidden(true)
            case .picker(let returnTo):
                LocationChannelsPicker(
                    presentation: .pane(
                        headerHeight: headerHeight,
                        trailingCornerReach: trailingCornerReach,
                        panicEpoch: appChromeModel.panicEpoch
                    ),
                    onChoose: { selects in
                        changePanes { panes.choseChannel(selects: selects) }
                    },
                    onClose: returnTo == nil ? nil : { changePanes { panes.endBrowsing() } }
                )
            }
        }
        // Whatever the pane shows: a request can still be pending after its
        // DM closed. Held back while anything else up first is presented
        // from the root (a sheet, an alert, a popover): it shows once that
        // closes, still pending.
        .modifier(LegacyPrivateMediaConsentDialog(isDeferred: { !isLegacyConsentShowingAtRoot }))
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
            onPeopleTap: peopleTap(.trailing),
            onBadgeTap: { changePanes { panes.browse() } }
        )
        .contentPeoplePopover(
            isPresented: peoplePopoverBinding(.trailing),
            channel: .location(geohash),
            paneWidth: paneWidth,
            onClose: popoverClose(.trailing)
        )
    }

    /// A pane's people popover. SwiftUI writes false when it dismisses the
    /// popover itself (a tap outside).
    private func peoplePopoverBinding(_ pane: ContentPane) -> Binding<Bool> {
        Binding(
            get: { panes.popover == pane },
            set: { isPresented in
                if !isPresented {
                    popoverClose(pane)()
                }
            }
        )
    }

    /// The action ContentView hands `pane`'s people button: that pane's
    /// people, as a popover. Nil where the bar has no such button: the
    /// single column, whose button toggles the people sheet, and a
    /// trailing pane without its geohash bar.
    private func peopleTap(_ pane: ContentPane) -> (() -> Void)? {
        guard isSplitLayout else { return nil }
        if pane == .trailing {
            guard case .channel = trailingContent else { return nil }
        }
        return { panes.openPopover(pane) }
    }

    /// The action ContentView hands `pane`'s popover close button (and its
    /// rows, once they have opened a DM): the popover state follows the
    /// popover closing itself. Also the binding's, for a tap outside.
    private func popoverClose(_ pane: ContentPane) -> () -> Void {
        { panes.popoverClosed(pane) }
    }

    /// A test host's tap: runs the action ContentView hands the button it
    /// stands for, which exists only where that button is on screen.
    private func perform(_ tap: SplitLayoutTestTap) {
        switch tap {
        case .peopleButton(let pane):
            peopleTap(pane)?()
        case .popoverCloseButton:
            if let pane = panes.popover {
                popoverClose(pane)()
            }
        }
    }

    /// A touch went down in the window. A touch on something presented
    /// over the panes, a popover included, touches neither pane. VoiceOver
    /// navigation delivers no touches (`PaneTouchObserver`'s known
    /// limitation): only its activations move the focus, through E1's
    /// semantic overrides.
    private func paneTouched(at point: CGPoint) {
        guard isSplitLayout,
              !hasRootModalPresentation,
              let pane = ContentPane.containing(point, leading: leadingPaneFrame, trailing: trailingPaneFrame),
              pane != panes.focus else { return }
        panes.touched(pane)
    }

    /// The person edited `slot`'s text: typing makes its pane the last
    /// touched (E1), however the other pane was touched since. Written only
    /// when the pane changes, so a keystroke doesn't re-render the root.
    private func composerEdited(_ slot: ComposerSlot) {
        guard isSplitLayout, ContentPane(composer: slot) != panes.focus else { return }
        panes.composerFocused(slot)
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
        // The consent dialog's host changes: it takes the screen afresh.
        legacyConsentOnScreen = nil
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
                timelineChannel: timelineChannel,
                selection: locationChannelsModel.selectedChannel,
                openPeer: openPeer
            )
        apply(effects)
        // The DM as it now is, should a reopening not have opened.
        panes.conversationChanged(
            to: selectedPrivatePeerID,
            isSplit: toSplit,
            timelineChannel: timelineChannel,
            selection: locationChannelsModel.selectedChannel,
            isSameConversation: privateConversationModel.isSameConversation
        )

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
        // Every composer to its slot in the new layout, at once.
        panesChanged(openPeer: selectedPrivatePeerID, trailingBefore: trailing)

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
        if effects.closesNoticesSheet {
            appChromeModel.isNoticesSheetPresented = false
        }
    }

    /// The open DM is now `peer`, reported as the model publishes it, before
    /// it holds it: the panes hear of it first (a touch or a fold right
    /// after must already see it), then everything that follows them.
    private func conversationReported(_ peer: PeerID?) {
        let before = trailingContent
        panes.conversationChanged(
            to: peer,
            isSplit: isSplitLayout,
            timelineChannel: timelineChannel,
            selection: locationChannelsModel.selectedChannel,
            isSameConversation: privateConversationModel.isSameConversation
        )
        panesChanged(openPeer: peer, trailingBefore: before)
    }

    /// Runs `change` on what the panes show, then `panesChanged`.
    private func changePanes(_ change: () -> Void) {
        let before = trailingContent
        change()
        panesChanged(openPeer: selectedPrivatePeerID, trailingBefore: before)
    }

    /// Brings what follows the panes up to date at once: each composer's
    /// target, cancelling a hold whose composer changed conversation (I1,
    /// E12), and the trailing people popover, which closes when its bar goes
    /// (E13). Every handler that changes what the panes show calls this, so
    /// none of it rests on `onChange`, which SwiftUI skips past two changes
    /// in one frame and never delivers later; the `onChange` handlers stay
    /// as backstops. Idempotent.
    /// - Parameters:
    ///   - openPeer: The open DM after the change.
    ///   - trailingBefore: What the trailing pane showed before it.
    private func panesChanged(openPeer: PeerID?, trailingBefore: TrailingPaneContent) {
        retargetComposers(to: composerTargets(openPeer: openPeer))
        panes.trailingContentChanged(from: trailingBefore, to: trailingContent(openPeer: openPeer))
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
        changePanes {
            let previous = timelineChannel
            publicTimelineChannel = channel
            // A geohash DM whose geohash this leaves ends.
            apply(panes.timelineChannelChanged(from: previous, to: channel))
        }
        #else
        publicTimelineChannel = channel
        retargetComposers(to: composerTargets)
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
        assertComposerIsCurrent(slot)
        composers.send(from: slot, through: conversationUIModel)
    }

    /// A composer's photo button: records the composer's conversation with
    /// the source and puts the picker up.
    #if os(iOS)
    private func mediaPicker(for slot: ComposerSlot) -> MediaPickAction {
        { [composers] source in
            assertComposerIsCurrent(slot)
            guard let request = composers.mediaPickRequest(from: slot, source: source) else { return }
            mediaPickRequest = request
        }
    }
    #else
    private func mediaPicker(for slot: ComposerSlot) -> MediaPickAction {
        { [composers] in
            assertComposerIsCurrent(slot)
            guard let request = composers.mediaPickRequest(from: slot) else { return }
            mediaPickRequest = request
        }
    }
    #endif

    /// A send or a pick goes where `slot`'s session points: that must be the
    /// conversation its composer shows now. Checked in debug builds, where a
    /// missed retarget stops right here instead of sending into another
    /// conversation than the one on screen (I1).
    private func assertComposerIsCurrent(_ slot: ComposerSlot) {
        assert(
            composers.points(slot, at: composerTargets[slot]),
            "the \(slot) composer sends to \(String(describing: composers[slot].target)), its pane shows \(String(describing: composerTargets[slot]))"
        )
    }
}

#if os(iOS)
/// Tells whether the window a view is in presents anything over its
/// content: a sheet, an alert, a dialog or a popover, one on its way out
/// included. Read on demand; it publishes nothing.
@MainActor
private final class WindowPresentationProbe {
    fileprivate weak var view: UIView?

    var isPresenting: Bool {
        view?.window?.rootViewController?.presentedViewController != nil
    }
}

/// Puts `probe` in the view's window.
private struct WindowPresentationProbeView: UIViewRepresentable {
    let probe: WindowPresentationProbe

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        probe.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        probe.view = view
    }
}

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
