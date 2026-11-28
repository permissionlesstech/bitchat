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
    var isWalkieTalkiePresented = false

    var hasPresentation: Bool {
        isImagePreviewPresented
            || isVerificationSheetPresented
            || legacyPrivateMediaConsentRequest != nil
            || isVoiceAlertPresented
            || isMediaPickerPresented
            || isWalkieTalkiePresented
    }
}

struct ContentPeopleSheetView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @Environment(\.appEnvironmentModels) private var appEnvironmentModels
    @Environment(\.scenePhase) private var scenePhase

    @Binding var showSidebar: Bool
    let draftModel: ComposerDraftModel
    @Binding var selectedMessageSender: String?
    @Binding var selectedMessageSenderID: PeerID?
    @Binding var imagePreviewURL: URL?
    @Binding var windowCountPrivate: [PeerID: Int]
    @Binding var isAtBottomPrivate: Bool
    var isTextFieldFocused: FocusState<Bool>.Binding
    @ObservedObject var voiceRecordingVM: VoiceRecordingViewModel
    @State private var showVerifySheet = false
    @State private var showWalkieTalkieSheet = false
    @ThemedPalette private var palette

    let headerHeight: CGFloat
    let onSendMessage: () -> Void
    @Binding var mediaPickerMode: MediaPickerMode?

    private func modalPresentationState(
        includingVoiceAlert: Bool
    ) -> ContentPeopleSheetModalPresentationState {
        ContentPeopleSheetModalPresentationState(
            isImagePreviewPresented: imagePreviewURL != nil,
            isVerificationSheetPresented: showVerifySheet,
            legacyPrivateMediaConsentRequest:
                conversationUIModel.legacyPrivateMediaConsentRequest,
            isVoiceAlertPresented: includingVoiceAlert && voiceRecordingVM.showAlert,
            isMediaPickerPresented: mediaPickerMode != nil,
            isWalkieTalkiePresented: showWalkieTalkieSheet
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
        let legacyConsentRequest = conversationUIModel.legacyPrivateMediaConsentRequest
        NavigationStack {
            Group {
                if privateConversationModel.selectedPeerID != nil {
                    ContentPrivateChatSheetView(
                        showSidebar: $showSidebar,
                        draftModel: draftModel,
                        selectedMessageSender: $selectedMessageSender,
                        selectedMessageSenderID: $selectedMessageSenderID,
                        imagePreviewURL: $imagePreviewURL,
                        windowCountPrivate: $windowCountPrivate,
                        isAtBottomPrivate: $isAtBottomPrivate,
                        isTextFieldFocused: isTextFieldFocused,
                        voiceRecordingVM: voiceRecordingVM,
                        showWalkieTalkieSheet: $showWalkieTalkieSheet,
                        headerHeight: headerHeight,
                        onSendMessage: onSendMessage,
                        mediaPickerMode: $mediaPickerMode
                    )
                    #if os(iOS)
                    .toolbar(.hidden, for: .navigationBar)
                    #endif
                } else {
                    ContentPeopleListView(
                        showSidebar: $showSidebar,
                        showVerifySheet: $showVerifySheet
                    )
                    #if os(iOS)
                    .toolbar(.hidden, for: .navigationBar)
                    #endif
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
                if let peerID = appChromeModel.showingFingerprintFor,
                   let models = appEnvironmentModels {
                    ContactDetailSheet(
                        peerID: peerID,
                        conversationPeerID: privateConversationModel.selectedPeerID ?? peerID,
                        imagePreviewURL: $imagePreviewURL
                    )
                    .installAppEnvironment(models)
                    #if os(iOS)
                    .toolbar(.hidden, for: .navigationBar)
                    #endif
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
        .foregroundColor(palette.primary)
        .confirmationDialog(
            String(
                localized: "content.private_media.legacy_warning.title",
                defaultValue: "Send without end-to-end encryption?",
                comment: "Title warning before sending private media to an older client in a clear signed envelope"
            ),
            isPresented: Binding(
                get: { legacyConsentRequest != nil },
                set: { isPresented in
                    if !isPresented, let requestID = legacyConsentRequest?.id {
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
            Button(String(localized: "common.cancel"), role: .cancel) {
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
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
        .mediaPickerPresentation(
            mode: $mediaPickerMode,
            isActive: showSidebar || privateConversationModel.selectedPeerID != nil,
            conversationUIModel: conversationUIModel
        )
        .voiceAndBluetoothAlerts(
            voiceRecordingVM: voiceRecordingVM,
            appChromeModel: appChromeModel,
            isVoiceAlertPresented: voiceAlertBinding,
            isBluetoothAlertPresented: bluetoothAlertBinding
        )
    }
}

private struct ContentPeopleListView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @Environment(\.appEnvironmentModels) private var appEnvironmentModels
    @Environment(\.dismiss) private var dismiss
    @ThemedPalette private var palette

    @Binding var showSidebar: Bool
    @Binding var showVerifySheet: Bool

    var body: some View {
        VStack(spacing: 0) {
            ThemedSheetHeader(
                title: peopleSheetTitle,
                subtitle: peopleSheetSubtitle,
                trailing: {
                    if case .mesh = locationChannelsModel.selectedChannel {
                        TopBarIconButton(
                            systemImage: "qrcode",
                            accessibilityLabel: String(localized: "content.accessibility.verification", comment: "Accessibility label for the verification QR button"),
                            action: { showVerifySheet = true }
                        )
                        .help(String(localized: "content.help.verification", comment: "Help text for verification button"))
                    }
                },
                onClose: {
                    withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                        dismiss()
                        showSidebar = false
                        showVerifySheet = false
                        privateConversationModel.endConversation()
                    }
                }
            )

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
                        // Skip re-rendering the roster when this view
                        // refreshes for models the list doesn't read.
                        .equatable()
                        // Direct conversations survive channel switches; the
                        // geoDM someone opened from another cell must stay
                        // reachable here too.
                        RecentChatList(
                            chats: peerListModel.recentChatRows,
                            onTapChat: { peerID in
                                peerListModel.startConversation(with: peerID)
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
                                    appEnvironmentModels?.conversationUIModel.unblock(peerID: peer.peerID, displayName: peer.displayName)
                                } else {
                                    appEnvironmentModels?.conversationUIModel.block(peerID: peer.peerID, displayName: peer.displayName)
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
                        // Conversations with people no roster above lists
                        // anymore — without this, a read DM from an offline
                        // non-favorite had no row anywhere in the UI.
                        RecentChatList(
                            chats: peerListModel.recentChatRows,
                            onTapChat: { peerID in
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
                // Keyed by channel only. Rows are keyed by person, so roster
                // updates diff in place; a key derived from the rows rebuilds
                // the whole list on every heartbeat and resets its stable
                // ordering.
                .id(ConversationID(channelID: locationChannelsModel.selectedChannel))
            }
        }
        .themedSheetBackground()
        .sheet(isPresented: $showVerifySheet) {
            if let verificationModel = appEnvironmentModels?.verificationModel {
                VerificationSheetView(isPresented: $showVerifySheet)
                    .environmentObject(verificationModel)
            }
        }
    }
}

private extension ContentPeopleListView {
    var peopleSheetTitle: String {
        String(localized: "content.header.people", comment: "Title for the people list sheet")
    }

    var peopleSheetSubtitle: String? {
        if case .location(let channel) = locationChannelsModel.selectedChannel {
            return "#\(channel.geohash.lowercased())"
        }
        return nil
    }
}

private struct ContentPrivateChatSheetView: View {
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var privateInboxModel: PrivateInboxModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @Environment(\.appEnvironmentModels) private var appEnvironmentModels
    @ObservedObject private var pttPreferences = PTTPreferences.shared

    @Binding var showSidebar: Bool
    let draftModel: ComposerDraftModel
    @Binding var selectedMessageSender: String?
    @Binding var selectedMessageSenderID: PeerID?
    @Binding var imagePreviewURL: URL?
    @Binding var windowCountPrivate: [PeerID: Int]
    @Binding var isAtBottomPrivate: Bool
    var isTextFieldFocused: FocusState<Bool>.Binding
    @ObservedObject var voiceRecordingVM: VoiceRecordingViewModel
    @Binding var showWalkieTalkieSheet: Bool
    @ThemedPalette private var palette
    @State private var showGroupInfoSheet = false
    @State private var isSearchPresented = false
    @State private var searchQuery = ""
    @State private var searchMatchIndex: Int? = nil
    @State private var searchJumpNonce = 0

    let headerHeight: CGFloat
    let onSendMessage: () -> Void
    @Binding var mediaPickerMode: MediaPickerMode?

    private var privateSearchMatches: [String] {
        guard isSearchPresented, let peer = privateConversationModel.selectedPeerID else { return [] }
        return MessageInteractionCodec.matchingMessageIDs(
            in: privateInboxModel.messages(for: peer),
            query: searchQuery
        )
    }

    private var activePrivateSearchMessageID: String? {
        let matches = privateSearchMatches
        guard let idx = searchMatchIndex, matches.indices.contains(idx) else { return nil }
        return matches[idx]
    }

    var body: some View {
        VStack(spacing: 0) {
            if let headerState = privateConversationModel.selectedHeaderState {
                AppTopBar(style: .sheet) {
                    HStack(spacing: 6) {
                        Button(action: {
                            withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                                privateConversationModel.endConversation()
                            }
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: ChromeMetrics.backChevronSize, weight: .semibold))
                                .foregroundColor(palette.primary)
                                .frame(width: 28, height: ChromeMetrics.iconTapSize)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            String(localized: "content.accessibility.back_to_main_chat", comment: "Accessibility label for returning to main chat")
                        )

                        ContentPrivateHeaderInfoButton(
                            headerState: headerState,
                            headerHeight: headerHeight,
                            onShowGroupInfo: { showGroupInfoSheet = true }
                        )
                    }
                } trailing: {
                    if !headerState.conversationPeerID.isGeoDM {
                        let someoneSpeaking = conversationUIModel.activeTalkerInCurrentContext(
                            selectedPeerID: headerState.conversationPeerID
                        ) != nil
                        TopBarIconButton(
                            systemImage: "radio",
                            accessibilityLabel: String(localized: "walkie.accessibility.open", defaultValue: "Open walkie-talkie", comment: "Accessibility label for the header walkie-talkie button"),
                            color: someoneSpeaking ? Color.red : (pttPreferences.liveVoiceEnabled ? palette.accent : palette.secondary),
                            action: {
                                isTextFieldFocused.wrappedValue = false
                                showWalkieTalkieSheet = true
                            }
                        )
                        .modifier(PulsingOpacityModifier(active: someoneSpeaking))
                    }

                    TopBarIconButton(
                        systemImage: "magnifyingglass",
                        accessibilityLabel: String(localized: "chat.search.accessibility", defaultValue: "Search in chat", comment: "Accessibility label for in-chat search toggle button"),
                        color: isSearchPresented ? palette.accent : palette.secondary,
                        action: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isSearchPresented.toggle()
                                if !isSearchPresented {
                                    searchQuery = ""
                                    searchMatchIndex = nil
                                }
                            }
                        }
                    )

                    let activeTimer = privateConversationModel.disappearingTimer(for: headerState.conversationPeerID)
                    Menu {
                        ForEach(DisappearingTimer.allCases) { option in
                            Button {
                                privateConversationModel.setDisappearingTimer(
                                    option,
                                    for: headerState.conversationPeerID
                                )
                            } label: {
                                HStack {
                                    Text(option.displayName)
                                    if activeTimer == option {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: activeTimer.iconName)
                            .font(.system(size: ChromeMetrics.iconSize, weight: .medium))
                            .foregroundColor(activeTimer == .off ? palette.secondary : Color.orange)
                            .frame(width: ChromeMetrics.iconTapSize, height: ChromeMetrics.iconTapSize)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel(
                        String(localized: "chat.timer.label", defaultValue: "Disappearing messages", comment: "Accessibility label for disappearing messages menu")
                    )

                    if headerState.supportsFavoriteToggle {
                        TopBarIconButton(
                            systemImage: headerState.isFavorite ? "star.fill" : "star",
                            accessibilityLabel: headerState.isFavorite
                                ? String(localized: "content.accessibility.remove_favorite", comment: "Accessibility label to remove a favorite")
                                : String(localized: "content.accessibility.add_favorite", comment: "Accessibility label to add a favorite"),
                            color: headerState.isFavorite ? Color.yellow : palette.secondary,
                            action: {
                                privateConversationModel.toggleFavoriteForSelectedConversation()
                            }
                        )
                    }
                }
            }

            if isSearchPresented {
                let matches = privateSearchMatches
                ChatSearchBar(
                    query: $searchQuery,
                    matchCount: matches.count,
                    activeMatchIndex: searchMatchIndex,
                    onPrevious: {
                        guard !matches.isEmpty else { return }
                        if let current = searchMatchIndex {
                            searchMatchIndex = (current - 1 + matches.count) % matches.count
                        } else {
                            searchMatchIndex = matches.count - 1
                        }
                        searchJumpNonce &+= 1
                    },
                    onNext: {
                        guard !matches.isEmpty else { return }
                        if let current = searchMatchIndex {
                            searchMatchIndex = (current + 1) % matches.count
                        } else {
                            searchMatchIndex = 0
                        }
                        searchJumpNonce &+= 1
                    },
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isSearchPresented = false
                            searchQuery = ""
                            searchMatchIndex = nil
                        }
                    }
                )
                .onChange(of: searchQuery) { newQuery in
                    let peer = privateConversationModel.selectedPeerID
                    let latest = MessageInteractionCodec.matchingMessageIDs(
                        in: privateInboxModel.messages(for: peer),
                        query: newQuery
                    )
                    searchMatchIndex = latest.isEmpty ? nil : latest.count - 1
                    searchJumpNonce &+= 1
                }
            }

            PrivateMessageListView(
                privatePeer: privateConversationModel.selectedPeerID,
                isAtBottom: $isAtBottomPrivate,
                selectedMessageSender: $selectedMessageSender,
                selectedMessageSenderID: $selectedMessageSenderID,
                imagePreviewURL: $imagePreviewURL,
                windowCountPrivate: $windowCountPrivate,
                showSidebar: $showSidebar,
                isTextFieldFocused: isTextFieldFocused,
                highlightedMessageID: activePrivateSearchMessageID,
                jumpRequestID: searchJumpNonce
            )
            .themedSurface()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Swipe-right-to-leave lives on the message list only. On the
            // whole sheet it preempted the composer's press-and-hold mic
            // gesture (a high-priority ancestor drag cancels child gestures
            // within milliseconds — same starvation as the image-reveal bug).
            .highPriorityGesture(swipeToLeaveGesture)

            privacyCaption

            ContentComposerView(
                draftModel: draftModel,
                isTextFieldFocused: isTextFieldFocused,
                voiceRecordingVM: voiceRecordingVM,
                onSendMessage: onSendMessage,
                mediaPickerMode: $mediaPickerMode
            )
        }
        .themedSheetBackground()
        .foregroundColor(palette.primary)
        .sheet(isPresented: $showGroupInfoSheet) {
            if let peerID = privateConversationModel.selectedPeerID, peerID.isGroup {
                GroupInfoSheet(groupPeerID: peerID)
                    .environmentObject(privateConversationModel)
                    .environmentObject(peerListModel)
            }
        }
        .sheet(isPresented: $showWalkieTalkieSheet) {
            if let models = appEnvironmentModels {
                WalkieTalkieSheetView(
                    voiceRecordingVM: voiceRecordingVM,
                    allowsChannelSwitching: false
                )
                .installAppEnvironment(models)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #endif
            }
        }
        .onChange(of: privateConversationModel.selectedPeerID) { _ in
            isSearchPresented = false
            searchQuery = ""
            searchMatchIndex = nil
        }
    }

    private var swipeToLeaveGesture: some Gesture {
        DragGesture(minimumDistance: 25, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = abs(value.translation.height)
                guard horizontal > 80, vertical < 60 else { return }
                withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                    privateConversationModel.endConversation()
                }
            }
    }

    /// Persistent one-line indicator above the private composer showing both
    /// encryption posture and how the next message will move (Bluetooth mesh,
    /// Nostr relay, hybrid group split, or queued offline for reconnect/courier).
    private var privacyCaption: some View {
        let info = transportCaptionInfo
        return HStack(spacing: 5) {
            Image(systemName: info.icon)
                .font(.bitchatSystem(size: 10, weight: .medium))
                .foregroundColor(info.tint)
                .offset(y: info.icon == "lock.fill" ? -0.5 : 0)
            Text(verbatim: info.text)
                .bitchatFont(size: 11, weight: .medium)
                .foregroundColor(palette.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .themedSurface()
        .accessibilityElement(children: .combine)
    }

    private var transportCaptionInfo: (icon: String, tint: Color, text: String) {
        guard let header = privateConversationModel.selectedHeaderState else {
            return (
                "lock.fill",
                Color.orange.opacity(0.85),
                String(localized: "content.private.caption", comment: "Caption above the private chat composer before encryption is established")
            )
        }

        if header.isGroupConversation {
            let mesh = header.groupMeshReachableCount
            let nostr = header.groupNostrReachableCount
            if mesh > 0 && nostr > 0 {
                return (
                    "lock.fill",
                    palette.accent,
                    String(
                        format: String(localized: "content.private.transport.group_hybrid", defaultValue: "Encrypted · %lld on mesh, %lld via Nostr", comment: "Group transport caption when members span Bluetooth mesh and Nostr"),
                        locale: .current,
                        mesh,
                        nostr
                    )
                )
            } else if mesh > 0 {
                return (
                    "antenna.radiowaves.left.and.right",
                    palette.accentBlue,
                    String(
                        format: String(localized: "content.private.transport.group_mesh", defaultValue: "Encrypted · %lld on Bluetooth mesh", comment: "Group transport caption when members are reachable over Bluetooth mesh"),
                        locale: .current,
                        mesh
                    )
                )
            } else if nostr > 0 {
                return (
                    "globe",
                    .purple,
                    String(
                        format: String(localized: "content.private.transport.group_nostr", defaultValue: "Encrypted · %lld via Nostr relay", comment: "Group transport caption when members are reachable via Nostr"),
                        locale: .current,
                        nostr
                    )
                )
            } else if header.groupOtherMemberCount > 0 {
                return (
                    "clock.arrow.circlepath",
                    Color.orange.opacity(0.9),
                    String(localized: "content.private.transport.group_offline", defaultValue: "Encrypted · Members offline, sends on reconnect", comment: "Group transport caption when all other members are offline")
                )
            }
            return (
                "lock.fill",
                Color.orange.opacity(0.85),
                String(localized: "content.private.caption_group", comment: "Caption above the group chat composer noting messages are encrypted to group members")
            )
        }

        let isGeoDM = header.conversationPeerID.isGeoDM
        let noiseSecured: Bool = {
            switch header.encryptionStatus {
            case .noiseSecured, .noiseVerified: return true
            default: return false
            }
        }()

        switch header.availability {
        case .bluetoothConnected:
            let text = noiseSecured
                ? String(localized: "content.private.transport.ble_encrypted", defaultValue: "Encrypted · Direct Bluetooth", comment: "DM transport caption for secured direct Bluetooth connection")
                : String(localized: "content.private.transport.ble_securing", defaultValue: "Direct Bluetooth · Securing session", comment: "DM transport caption while Bluetooth Noise handshake is pending")
            return ("dot.radiowaves.left.and.right", palette.accentBlue, text)

        case .meshReachable:
            let text = noiseSecured
                ? String(localized: "content.private.transport.mesh_encrypted", defaultValue: "Encrypted · Relayed on mesh", comment: "DM transport caption for secured multi-hop mesh path")
                : String(localized: "content.private.transport.mesh_securing", defaultValue: "Mesh relay · Securing session", comment: "DM transport caption while multi-hop mesh Noise handshake is pending")
            return ("point.3.filled.connected.trianglepath.dotted", palette.accentBlue, text)

        case .nostrAvailable:
            let text = isGeoDM
                ? String(localized: "content.private.transport.nostr_geo", defaultValue: "Encrypted · Nostr location DM", comment: "DM transport caption for a geohash Nostr DM")
                : String(localized: "content.private.transport.nostr_relay", defaultValue: "Encrypted · Nostr relay", comment: "DM transport caption for a Nostr-routed DM")
            return ("globe", .purple, text)

        case .offline:
            return (
                "clock.arrow.circlepath",
                Color.orange.opacity(0.9),
                String(localized: "content.private.transport.offline_queue", defaultValue: "Offline · Messages queue until reconnect or courier", comment: "DM transport caption when peer is currently offline")
            )
        }
    }
}

private struct ContentPrivateHeaderInfoButton: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @ThemedPalette private var palette

    let headerState: PrivateConversationHeaderState
    let headerHeight: CGFloat
    var onShowGroupInfo: () -> Void = {}

    var body: some View {
        Button(action: {
            if headerState.isGroupConversation {
                onShowGroupInfo()
                return
            }
            appChromeModel.showFingerprint(for: headerState.headerPeerID)
        }) {
            HStack(spacing: 6) {
                if headerState.isGroupConversation {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(palette.primary)
                        .accessibilityLabel(String(localized: "content.accessibility.group_chat", comment: "Accessibility label for the group chat indicator"))
                } else {
                    switch headerState.availability {
                    case .bluetoothConnected:
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(palette.primary)
                            .accessibilityLabel(String(localized: "content.accessibility.connected_mesh", comment: "Accessibility label for mesh-connected peer indicator"))
                    case .meshReachable:
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(palette.primary)
                            .accessibilityLabel(String(localized: "content.accessibility.reachable_mesh", comment: "Accessibility label for mesh-reachable peer indicator"))
                    case .nostrAvailable:
                        Image(systemName: "globe")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.purple)
                            .accessibilityLabel(String(localized: "content.accessibility.available_nostr", comment: "Accessibility label for Nostr-available peer indicator"))
                    case .offline:
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(palette.secondary)
                            .accessibilityLabel(String(localized: "mesh_peers.state.offline", comment: "State label for a peer that is not currently reachable"))
                    }
                }

                Text(headerState.displayName)
                    .bitchatFont(size: 17, weight: .bold)
                    .foregroundColor(palette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let encryptionStatus = headerState.encryptionStatus,
                   let icon = encryptionStatus.icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .offset(y: icon.hasPrefix("lock") ? -0.5 : 0)
                        .foregroundColor(
                            encryptionStatus == .noiseVerified || encryptionStatus == .noiseSecured
                            ? palette.secondary
                            : palette.alertRed
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
