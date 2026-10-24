import BitFoundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ContentPeopleSheetModalPresentationState {
    var isImagePreviewPresented = false
    var isVerificationSheetPresented = false
    var legacyPrivateMediaConsentRequest: LegacyPrivateMediaConsentRequest? = nil
    var isVoiceAlertPresented = false
    var isMediaPickerPresented = false

    var hasPresentation: Bool {
        isImagePreviewPresented
            || isVerificationSheetPresented
            || legacyPrivateMediaConsentRequest != nil
            || isVoiceAlertPresented
            || isMediaPickerPresented
    }
}

struct ContentPeopleSheetView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var verificationModel: VerificationModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @Environment(\.scenePhase) private var scenePhase

    @Binding var showSidebar: Bool
    @Binding var selectedMessageSender: String?
    @Binding var selectedMessageSenderID: PeerID?
    @Binding var imagePreviewURL: URL?
    @Binding var windowCountPublic: Int
    @Binding var windowCountPrivate: [PeerID: Int]
    @Binding var isAtBottomPrivate: Bool
    /// The DM composer's session (the secondary slot's).
    let composer: ComposerSession
    /// The open DM, scoped as its composer sends: the secondary slot's
    /// target. Nil while no DM is open.
    let target: ConversationTarget?
    var focusedComposer: FocusState<ComposerSlot?>.Binding
    @ObservedObject var voiceRecordingVM: VoiceRecordingViewModel
    @State private var showVerifySheet = false
    @ThemedPalette private var palette

    let headerHeight: CGFloat
    let onSendMessage: () -> Void
    #if os(iOS)
    let onPickMedia: (UIImagePickerController.SourceType) -> Void
    #else
    let onPickMedia: () -> Void
    #endif
    /// A pick from the DM composer presents from this sheet, which the root
    /// can't present over.
    @Binding var mediaPickRequest: MediaPickRequest?

    private func modalPresentationState(
        includingVoiceAlert: Bool
    ) -> ContentPeopleSheetModalPresentationState {
        ContentPeopleSheetModalPresentationState(
            isImagePreviewPresented: imagePreviewURL != nil,
            isVerificationSheetPresented: showVerifySheet,
            legacyPrivateMediaConsentRequest:
                conversationUIModel.legacyPrivateMediaConsentRequest,
            isVoiceAlertPresented: includingVoiceAlert && voiceRecordingVM.showAlert,
            isMediaPickerPresented: mediaPickRequest != nil
        )
    }

    private var hasModalPresentation: Bool {
        modalPresentationState(includingVoiceAlert: true).hasPresentation
    }

    /// The voice alert cannot defer to itself: its own binding must keep
    /// reporting `true` while it is the presented modal.
    private var hasModalPresentationBesidesVoiceAlert: Bool {
        modalPresentationState(includingVoiceAlert: false).hasPresentation
    }

    private var bluetoothAlertBinding: Binding<Bool> {
        Binding(
            get: {
                scenePhase == .active
                    && appChromeModel.showBluetoothAlert
                    && !hasModalPresentation
            },
            set: { isPresented in
                guard !isPresented,
                      scenePhase == .active,
                      !hasModalPresentation else {
                    return
                }
                appChromeModel.showBluetoothAlert = false
            }
        )
    }

    private var imagePreviewBinding: Binding<Bool> {
        Binding(
            get: {
                imagePreviewURL != nil
                    && (showSidebar || privateConversationModel.selectedPeerID != nil)
            },
            set: { isPresented in
                if !isPresented {
                    imagePreviewURL = nil
                }
            }
        )
    }

    /// Voice recording happens inside this sheet, so its error alert must
    /// present from here as well: the root copy defers whenever this sheet
    /// is up, exactly like the Bluetooth alert above. Presenting from the
    /// root instead would force-dismiss the sheet and end the conversation.
    private var voiceAlertBinding: Binding<Bool> {
        Binding(
            get: {
                scenePhase == .active
                    && voiceRecordingVM.showAlert
                    && !hasModalPresentationBesidesVoiceAlert
            },
            set: { isPresented in
                guard !isPresented,
                      scenePhase == .active,
                      !hasModalPresentationBesidesVoiceAlert else {
                    return
                }
                voiceRecordingVM.showAlert = false
            }
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if privateConversationModel.selectedPeerID != nil {
                    ContentPrivateChatSheetView(
                        showSidebar: $showSidebar,
                        selectedMessageSender: $selectedMessageSender,
                        selectedMessageSenderID: $selectedMessageSenderID,
                        imagePreviewURL: $imagePreviewURL,
                        windowCountPublic: $windowCountPublic,
                        windowCountPrivate: $windowCountPrivate,
                        isAtBottomPrivate: $isAtBottomPrivate,
                        composer: composer,
                        target: target,
                        focusedComposer: focusedComposer,
                        voiceRecordingVM: voiceRecordingVM,
                        headerHeight: headerHeight,
                        onSendMessage: onSendMessage,
                        onPickMedia: onPickMedia
                    )
                } else {
                    ContentPeopleListView(
                        showSidebar: $showSidebar,
                        showVerifySheet: $showVerifySheet
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
            // This sheet covers the root header where the connectivity
            // banner lives; a person sitting in the people list or a DM
            // would otherwise get no persistent signal that the radio is
            // off or tor is stalled. Mirror it here.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let issue = ConnectivityIssue.resolve(
                    bluetoothState: appChromeModel.bluetoothState,
                    torBlocked: appChromeModel.torBlocked
                ) {
                    ConnectivityStatusBanner(issue: issue)
                }
            }
        }
        .themedSheetBackground()
        .foregroundColor(palette.primary)
        // The sheet presents it from its own tree, over whatever it shows.
        .modifier(LegacyPrivateMediaConsentDialog(isDeferred: false))
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
        #if os(iOS)
        .fullScreenCover(item: Binding(
            get: { (showSidebar || privateConversationModel.selectedPeerID != nil) ? mediaPickRequest : nil },
            set: { newValue in
                if newValue == nil {
                    mediaPickRequest = nil
                }
            }
        )) { request in
            ImagePickerView(sourceType: request.source) { image in
                mediaPickRequest = nil
                conversationUIModel.processSelectedImage(image, to: request.target)
            }
            .ignoresSafeArea()
        }
        #endif
        #if os(macOS)
        .sheet(item: $mediaPickRequest) { request in
            MacImagePickerView { url in
                mediaPickRequest = nil
                conversationUIModel.processSelectedImage(from: url, to: request.target)
            }
        }
        #endif
        // Image taps in the DM: the root presenter defers to this sheet, which
        // it cannot present over.
        #if os(iOS)
        .fullScreenCover(isPresented: imagePreviewBinding) {
            if let url = imagePreviewURL {
                ImagePreviewView(url: url)
            }
        }
        #else
        .sheet(isPresented: imagePreviewBinding) {
            if let url = imagePreviewURL {
                ImagePreviewView(url: url)
            }
        }
        #endif
        .alert(Text(String(localized: "voice.error.title", defaultValue: "recording error", comment: "Title of the voice recording error alert")), isPresented: voiceAlertBinding, actions: {
            Button("common.ok", role: .cancel) {}
            if voiceRecordingVM.state == .permissionDenied {
                Button("location_channels.action.open_settings") {
                    SystemSettings.microphone.open()
                }
            }
        }, message: {
            Text(voiceRecordingVM.state.alertMessage)
        })
        .alert(
            "content.alert.bluetooth_required.title",
            isPresented: bluetoothAlertBinding
        ) {
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
    }
}

#if os(iOS)
/// The open DM as the split layout's trailing pane (regular width, e.g. the
/// iPhone Duo's inner display). It lives in ContentView's own tree, so it
/// inherits every environment object and presents through the root: none of
/// the sheet's NavigationStack, close buttons, banner mirror, alert copies or
/// backdrop come along. The pane around it hosts the legacy-media consent
/// dialog, whatever the pane shows.
struct ContentConversationColumnView: View {
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel

    @Binding var showSidebar: Bool
    @Binding var selectedMessageSender: String?
    @Binding var selectedMessageSenderID: PeerID?
    @Binding var imagePreviewURL: URL?
    @Binding var windowCountPublic: Int
    @Binding var windowCountPrivate: [PeerID: Int]
    @Binding var isAtBottomPrivate: Bool
    /// The DM composer's session (the secondary slot's).
    let composer: ComposerSession
    /// The open DM, scoped as its composer sends (the secondary slot's
    /// target).
    let target: ConversationTarget?
    var focusedComposer: FocusState<ComposerSlot?>.Binding
    @ObservedObject var voiceRecordingVM: VoiceRecordingViewModel
    /// The photo button; the root presents the picker for the pane.
    let onPickMedia: (UIImagePickerController.SourceType) -> Void

    let headerHeight: CGFloat
    /// How far a rounded display corner reaches into the top rows from the
    /// trailing edge (TopCornerClearance); each row pads by what its own
    /// content inset leaves uncovered.
    let trailingCornerReach: CGFloat
    let onSendMessage: () -> Void

    var body: some View {
        Group {
            // Without a conversation the DM's list would show the public
            // timeline; the pane only outlives its DM for a frame.
            if privateConversationModel.selectedPeerID != nil {
                ContentPrivateChatSheetView(
                    showSidebar: $showSidebar,
                    selectedMessageSender: $selectedMessageSender,
                    selectedMessageSenderID: $selectedMessageSenderID,
                    imagePreviewURL: $imagePreviewURL,
                    windowCountPublic: $windowCountPublic,
                    windowCountPrivate: $windowCountPrivate,
                    isAtBottomPrivate: $isAtBottomPrivate,
                    composer: composer,
                    target: target,
                    focusedComposer: focusedComposer,
                    voiceRecordingVM: voiceRecordingVM,
                    headerHeight: headerHeight,
                    onSendMessage: onSendMessage,
                    onPickMedia: onPickMedia,
                    isInline: true,
                    trailingCornerReach: trailingCornerReach
                )
            }
        }
    }
}

/// A pane's people in the split layout, as a popover from the pane's bar:
/// the people sheet's list for that pane's channel, with its own navigation
/// for the fingerprint. Present it with `contentPeoplePopover(...)`.
struct ContentPeoplePopoverView: View {
    @EnvironmentObject private var verificationModel: VerificationModel

    /// The pane's channel: #mesh, or the live geohash.
    let channel: ChannelID
    /// The width of the pane it opens over.
    let paneWidth: CGFloat
    /// Closes the popover (a row tap has opened a DM, or the close button).
    let onClose: () -> Void

    @State private var showVerifySheet = false
    /// The fingerprint pushed here. It is the popover's own, never the
    /// root's (`AppChromeModel.showingFingerprintFor`), so it goes with the
    /// popover however that closes (a fold, a panic, a DM opening) and can't
    /// come back as the root's fingerprint sheet while the popover is still
    /// on its way out (E13).
    @State private var fingerprintPeerID: PeerID?

    /// As wide as the people sheet on a phone, but 16pt clear of the pane's
    /// edges on either side, so it never reaches across the hinge.
    static func idealWidth(forPaneWidth paneWidth: CGFloat) -> CGFloat {
        max(0, min(360, paneWidth - 32))
    }

    var body: some View {
        NavigationStack {
            ContentPeopleListView(
                showSidebar: .constant(false),
                showVerifySheet: $showVerifySheet,
                presentation: .popover(
                    onClose: onClose,
                    onShowFingerprint: { fingerprintPeerID = $0 }
                ),
                channel: channel
            )
            .navigationDestination(isPresented: Binding(
                get: { fingerprintPeerID != nil },
                set: { isPresented in
                    if !isPresented {
                        fingerprintPeerID = nil
                    }
                }
            )) {
                if let fingerprintPeerID {
                    FingerprintView(peerID: fingerprintPeerID)
                        .environmentObject(verificationModel)
                }
            }
        }
        .frame(idealWidth: Self.idealWidth(forPaneWidth: paneWidth), idealHeight: 480)
        .modifier(PeoplePopoverPresentationStyle())
    }
}

/// Keeps the popover a popover where iOS would turn it into a sheet (a
/// compact size class), on the themed backdrop.
private struct PeoplePopoverPresentationStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content
                .presentationCompactAdaptation(.popover)
                .presentationBackground {
                    ThemedRootBackground()
                }
        } else {
            content
                .background(ThemedRootBackground())
        }
    }
}

/// Presents `ContentPeoplePopoverView` from the view it modifies (a pane's
/// whole bar, so the popover centres in its pane, off the hinge). The models
/// the people tree reads are handed over explicitly, as the root does for
/// its sheets: presentations can drop inherited environment objects (#1558).
private struct ContentPeoplePopoverPresenter: ViewModifier {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var verificationModel: VerificationModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var peerListModel: PeerListModel

    @Binding var isPresented: Bool
    let channel: ChannelID
    let paneWidth: CGFloat
    let onClose: () -> Void

    func body(content: Content) -> some View {
        content.popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds)) {
            ContentPeoplePopoverView(channel: channel, paneWidth: paneWidth, onClose: onClose)
                .environmentObject(appChromeModel)
                .environmentObject(privateConversationModel)
                .environmentObject(verificationModel)
                .environmentObject(conversationUIModel)
                .environmentObject(locationChannelsModel)
                .environmentObject(peerListModel)
        }
    }
}

extension View {
    /// Presents a pane's people popover, anchored to this view's bounds.
    /// - Parameters:
    ///   - channel: The pane's channel: #mesh, or the live geohash.
    ///   - paneWidth: The pane's width, to keep the popover inside it.
    ///   - onClose: Clears the popover state (`isPresented` reads false).
    func contentPeoplePopover(
        isPresented: Binding<Bool>,
        channel: ChannelID,
        paneWidth: CGFloat,
        onClose: @escaping () -> Void
    ) -> some View {
        modifier(ContentPeoplePopoverPresenter(
            isPresented: isPresented,
            channel: channel,
            paneWidth: paneWidth,
            onClose: onClose
        ))
    }
}
#endif

/// Consent before one private-media send to a legacy client goes out in a
/// clear signed envelope. Applied by the people sheet and by the split
/// layout's trailing pane, whatever either shows, so a pending request
/// always has a presenter; dismissing it denies the send.
struct LegacyPrivateMediaConsentDialog: ViewModifier {
    @EnvironmentObject private var conversationUIModel: ConversationUIModel

    /// Holds a pending request back while something else is presented over
    /// the dialog's host (the split layout's people popover, which the root
    /// presents): presenting it then would fail and leave the request,
    /// which the root's alerts wait on, pending for good. It shows once that
    /// closes. Held back is not dismissed: the request stays pending.
    let isDeferred: Bool

    func body(content: Content) -> some View {
        let legacyConsentRequest = conversationUIModel.legacyPrivateMediaConsentRequest
        content
            .confirmationDialog(
                String(
                    localized: "content.private_media.legacy_warning.title",
                    defaultValue: "Send without end-to-end encryption?",
                    comment: "Title warning before sending private media to an older client in a clear signed envelope"
                ),
                isPresented: Binding(
                    get: { legacyConsentRequest != nil && !isDeferred },
                    set: { isPresented in
                        if !isPresented, !isDeferred, let requestID = legacyConsentRequest?.id {
                            conversationUIModel.resolveLegacyPrivateMediaConsent(
                                requestID: requestID,
                                approved: false
                            )
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button(
                    String(
                        localized: "content.private_media.legacy_warning.send",
                        defaultValue: "send visible file",
                        comment: "Destructive confirmation action for one legacy clear private-media send"
                    ),
                    role: .destructive
                ) {
                    if let requestID = legacyConsentRequest?.id {
                        conversationUIModel.resolveLegacyPrivateMediaConsent(
                            requestID: requestID,
                            approved: true
                        )
                    }
                }
                Button("common.cancel", role: .cancel) {
                    if let requestID = legacyConsentRequest?.id {
                        conversationUIModel.resolveLegacyPrivateMediaConsent(
                            requestID: requestID,
                            approved: false
                        )
                    }
                }
            } message: {
                if let request = legacyConsentRequest {
                    Text(
                        String(
                            format: String(
                                localized: "content.private_media.legacy_warning.message",
                                defaultValue: "%@'s client does not advertise encrypted private media. This file will be signed but not end-to-end encrypted, so mesh relays can see it. Send this file anyway?",
                                comment: "Warning explaining the confidentiality loss for one legacy private-media send; parameter is the peer name"
                            ),
                            locale: .current,
                            request.peerName
                        )
                    )
                }
            }
    }
}

/// Everyone on a channel: #mesh's peers, the bridge, groups and recent
/// chats, or a geohash's participants and recent chats. A row tap opens
/// the DM.
struct ContentPeopleListView: View {
    enum Presentation {
        /// The people sheet (compact iOS, macOS): its close button also
        /// leaves an open conversation.
        case sheet
        #if os(iOS)
        /// A pane's people popover in the split layout. Closing it never
        /// ends a conversation; a row tap opens the DM and closes the
        /// popover once the DM is open, and a fingerprint shows in the
        /// popover's own navigation.
        case popover(onClose: () -> Void, onShowFingerprint: (PeerID) -> Void)
        #endif
    }

    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var verificationModel: VerificationModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @Environment(\.dismiss) private var dismiss
    @ThemedPalette private var palette

    @Binding var showSidebar: Bool
    @Binding var showVerifySheet: Bool
    var presentation: Presentation = .sheet
    /// The channel whose people to list; nil follows the selection. #mesh
    /// lists the mesh whatever is selected. A geohash's participants are
    /// the live geohash's: only pass the selected one.
    var channel: ChannelID? = nil

    private var listChannel: ChannelID {
        channel ?? locationChannelsModel.selectedChannel
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(peopleSheetTitle)
                        .bitchatFont(size: 18)
                        .foregroundColor(palette.primary)
                    Spacer()
                    if case .mesh = listChannel {
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
                    closeButton
                }

                // The mesh sheet titles its sections inline (#mesh / across
                // the bridge / groups) — no subtitle or count up here.
                // Location channels keep their geohash subtitle.
                if case .location(let channel) = listChannel {
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
                    if case .location = listChannel {
                        GeohashPeopleList(
                            onTapPerson: {
                                didOpenGeohashConversation()
                            }
                        )
                        // Skip re-rendering the roster when this view
                        // refreshes for models the list doesn't read.
                        .equatable()
                        // Direct conversations survive channel switches; the
                        // geoDM someone opened from another cell must stay
                        // reachable here too.
                        RecentChatList(
                            chats: peerListModel.recentChatRows,
                            onTapChat: { peerID in
                                openConversation(with: peerID)
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
                                openConversation(with: peerID)
                            },
                            onToggleFavorite: { peerID in
                                peerListModel.toggleFavorite(peerID: peerID)
                            },
                            onShowFingerprint: { peerID in
                                Self.showFingerprint(
                                    for: peerID,
                                    presentation: presentation,
                                    appChromeModel: appChromeModel
                                )
                            },
                            onToggleBlock: { peer in
                                // The confirmation lands in #mesh, whose
                                // people these are: the selection can be the
                                // other pane's conversation.
                                if peer.isBlocked {
                                    conversationUIModel.unblock(peerID: peer.peerID, displayName: peer.displayName, from: .mesh)
                                } else {
                                    conversationUIModel.block(peerID: peer.peerID, displayName: peer.displayName, from: .mesh)
                                }
                            }
                        )
                        // People in this area but beyond radio range, and
                        // private groups: one sheet for the whole room.
                        BridgePeopleList()
                        GroupChatList(
                            groups: peerListModel.groupRows,
                            onTapGroup: { peerID in
                                openConversation(with: peerID)
                            }
                        )
                        // Conversations with people no roster above lists
                        // anymore — without this, a read DM from an offline
                        // non-favorite had no row anywhere in the UI.
                        RecentChatList(
                            chats: peerListModel.recentChatRows,
                            onTapChat: { peerID in
                                openConversation(with: peerID)
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
                // Keyed by the listed channel only. Rows are keyed by
                // person, so roster updates diff in place; a key derived
                // from the rows rebuilds the whole list on every heartbeat
                // and resets its stable ordering. A mesh popover's list
                // stays put while the selected geohash changes.
                .id(ConversationID(channelID: listChannel))
            }
        }
        .sheet(isPresented: $showVerifySheet) {
            VerificationSheetView(isPresented: $showVerifySheet)
                .environmentObject(verificationModel)
        }
    }

    @ViewBuilder
    private var closeButton: some View {
        switch presentation {
        case .sheet:
            SheetCloseButton {
                withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                    dismiss()
                    showSidebar = false
                    showVerifySheet = false
                    privateConversationModel.endConversation()
                }
            }
        #if os(iOS)
        case .popover(let onClose, _):
            // A DM open beside the popover stays open.
            SheetCloseButton(action: onClose)
        #endif
        }
    }

    private func openConversation(with peerID: PeerID) {
        switch presentation {
        case .sheet:
            peerListModel.startConversation(with: peerID)
            showSidebar = true
        #if os(iOS)
        case .popover(let onClose, _):
            // The popover stays when no DM opened (a blocked peer's): it
            // would otherwise close on nothing.
            if Self.openConversationFromPopover(with: peerID, in: privateConversationModel) {
                onClose()
            }
        #endif
        }
    }

    /// A geohash row has opened its DM (GeohashPeopleList opens it itself).
    private func didOpenGeohashConversation() {
        switch presentation {
        case .sheet:
            showSidebar = true
        #if os(iOS)
        case .popover(let onClose, _):
            onClose()
        #endif
        }
    }

    /// Where a fingerprint asked for from the list shows: the people sheet
    /// pushes the app-wide one; a popover pushes its own, which can't
    /// outlive it (E13).
    static func showFingerprint(
        for peerID: PeerID,
        presentation: Presentation,
        appChromeModel: AppChromeModel
    ) {
        switch presentation {
        case .sheet:
            appChromeModel.showFingerprint(for: peerID)
        #if os(iOS)
        case .popover(_, let onShowFingerprint):
            onShowFingerprint(peerID)
        #endif
        }
    }

    #if os(iOS)
    /// Opens the DM with `peerID` from a popover row and says whether it
    /// opened: a blocked peer's doesn't. Through the conversation model,
    /// which takes the selection at once, so the answer is known before the
    /// tap returns.
    static func openConversationFromPopover(
        with peerID: PeerID,
        in model: PrivateConversationModel
    ) -> Bool {
        model.startConversation(with: peerID)
        return model.selectedPeerID == peerID
    }
    #endif

}

private extension ContentPeopleListView {
    var peopleSheetTitle: String {
        String(localized: "content.header.people", comment: "Title for the people list sheet").lowercased()
    }

}

private struct ContentPrivateChatSheetView: View {
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel

    @Binding var showSidebar: Bool
    @Binding var selectedMessageSender: String?
    @Binding var selectedMessageSenderID: PeerID?
    @Binding var imagePreviewURL: URL?
    @Binding var windowCountPublic: Int
    @Binding var windowCountPrivate: [PeerID: Int]
    @Binding var isAtBottomPrivate: Bool
    /// The DM composer's session; its list's mentions type into it too.
    let composer: ComposerSession
    /// The DM, scoped as it sends: what its list acts in and its composer
    /// sends to.
    let target: ConversationTarget?
    var focusedComposer: FocusState<ComposerSlot?>.Binding
    @ObservedObject var voiceRecordingVM: VoiceRecordingViewModel
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette

    let headerHeight: CGFloat
    let onSendMessage: () -> Void
    #if os(iOS)
    let onPickMedia: (UIImagePickerController.SourceType) -> Void
    #else
    let onPickMedia: () -> Void
    #endif

    /// Shown in the split layout's trailing pane rather than the sheet: the
    /// back chevron and swipe-to-leave bring the pane's channel or picker
    /// back, so there is no close button, and the header lines up with the
    /// #mesh bar beside it.
    var isInline = false
    var trailingCornerReach: CGFloat = 0

    /// Inline, the bar is as tall as the main header beside it, which
    /// Dynamic Type below Large makes shorter than 44pt.
    private var backButtonHeight: CGFloat {
        isInline ? min(44, headerHeight) : 44
    }

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
                            .frame(width: 44, height: backButtonHeight)
                            // Still a 44pt target where the bar is shorter.
                            .contentShape(Rectangle().inset(by: (backButtonHeight - 44) / 2))
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

                    if isInline {
                        // Holds the close button's place so the name stays
                        // centred as in the sheet.
                        Color.clear
                            .frame(width: 32, height: 32)
                            .accessibilityHidden(true)
                    } else {
                        SheetCloseButton {
                            withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                                privateConversationModel.endConversation()
                                showSidebar = true
                            }
                        }
                    }
                }
                // minHeight so scaled text at accessibility sizes grows the
                // bar instead of clipping inside it.
                .frame(minHeight: headerHeight)
                .padding(.horizontal, 16)
                .padding(.top, isInline ? 0 : 10)
                .padding(.bottom, isInline ? 0 : 12)
                // The content sits 16pt in, and glass floats the bar as a
                // panel another 8pt in (PrivateHeaderChrome).
                .padding(.trailing, TopCornerClearance.padding(
                    forReach: trailingCornerReach,
                    contentInset: theme.usesGlassChrome ? 24 : 16
                ))
                .modifier(PrivateHeaderChrome())
            }

            MessageListView(
                privateTarget: target,
                isAtBottom: $isAtBottomPrivate,
                composer: composer,
                selectedMessageSender: $selectedMessageSender,
                selectedMessageSenderID: $selectedMessageSenderID,
                imagePreviewURL: $imagePreviewURL,
                windowCountPublic: $windowCountPublic,
                windowCountPrivate: $windowCountPrivate,
                showSidebar: $showSidebar,
                focusedComposer: focusedComposer
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

            ContentComposerView(
                session: composer,
                target: target,
                focus: focusedComposer,
                voiceRecordingVM: voiceRecordingVM,
                onSend: onSendMessage,
                onPickMedia: onPickMedia
            )
        }
        .background {
            // Inline, the root backdrop already spans both panes; a second
            // glass gradient would restart its glows at the pane's edge.
            if !isInline {
                ThemedRootBackground()
            }
        }
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
        // Geohash DMs use BitChat's private-envelope encryption over Nostr —
        // always end-to-end encrypted,
        // even though they carry no Noise session status. Mesh DMs earn the
        // "encrypted" claim only once the Noise handshake has secured — or
        // when the peer is reachable only over Nostr, where delivery is
        // gift-wrapped end-to-end without a Noise session.
        let isGeoDM = privateConversationModel.selectedPeerID?.isGeoDM == true
        let noiseSecured: Bool = {
            switch privateConversationModel.selectedHeaderState?.encryptionStatus {
            case .noiseSecured, .noiseVerified: return true
            default: return false
            }
        }()
        let nostrTransport = privateConversationModel.selectedHeaderState?.availability == .nostrAvailable
        if isGeoDM || noiseSecured || nostrTransport {
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
