import SwiftUI

struct ContentHeaderView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var verificationModel: VerificationModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @EnvironmentObject private var boardAlertsModel: BoardAlertsModel
    @ObservedObject private var bridgeService = BridgeService.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette

    @Binding var showSidebar: Bool
    @Binding var showVerifySheet: Bool
    var isNicknameFieldFocused: FocusState<Bool>.Binding

    let headerHeight: CGFloat
    let headerPeerIconSize: CGFloat
    let headerPeerCountFontSize: CGFloat

    /// Courier envelopes this device is carrying for offline third parties.
    @State private var carriedMailCount = 0

    /// Board posts mirrored from the store so the pin icon can show when the
    /// current scope has notices.
    @State private var boardPosts: [BoardPostPacket] = []

    /// Nostr-only location notes at this place (live while the empty mesh
    /// timeline is showing) — they should light the pin too.
    @ObservedObject private var nearbyNotes = NearbyNotesCounter.shared

    /// The bridged-people count belongs to the mesh channel only.
    private var showBridgedPeerCount: Bool {
        if case .location = locationChannelsModel.selectedChannel { return false }
        return bridgeService.bridgedPeerCount > 0
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: "bitchat/")
                .bitchatFont(size: 18, weight: .medium)
                .lineLimit(1)
                .foregroundColor(palette.primary)
                // When icons crowd the header, squeeze the nickname first
                // (priority 0) and the logo only as a last resort; the icon
                // cluster at priority 3 never gives up width.
                .layoutPriority(2)
                .onTapGesture(count: 3) {
                    appChromeModel.panicClearAllData()
                }
                .onTapGesture(count: 1) {
                    appChromeModel.presentAppInfo()
                }
                // This is the only entry point to App Info, but it reads as
                // static text; surface the tap. (The triple-tap panic wipe
                // stays undiscoverable on purpose — it's destructive.)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(
                    String(localized: "content.accessibility.app_info_hint", comment: "Accessibility hint on the bitchat/ logo explaining a tap opens app info")
                )
                .accessibilityAction {
                    appChromeModel.presentAppInfo()
                }

            HStack(spacing: 0) {
                Text(verbatim: "@")
                    .bitchatFont(size: 14)
                    .foregroundColor(palette.secondary)
                    // Keep the sigil whole while the field beside it shrinks.
                    .fixedSize()

                TextField(
                    "content.input.nickname_placeholder",
                    text: Binding(
                        get: { appChromeModel.nickname },
                        set: { appChromeModel.setNickname($0) }
                    )
                )
                .textFieldStyle(.plain)
                .bitchatFont(size: 14)
                .frame(maxWidth: 80)
                .foregroundColor(palette.primary)
                .focused(isNicknameFieldFocused)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .modifier(FocusEffectDisabledModifier())
                .onChange(of: isNicknameFieldFocused.wrappedValue) { isFocused in
                    if !isFocused {
                        appChromeModel.validateAndSaveNickname()
                    }
                }
                .onSubmit {
                    appChromeModel.validateAndSaveNickname()
                }
            }

            Spacer()

            let countAndColor = channelPeopleCountAndColor()
            let headerCountColor = countAndColor.1
            let headerOtherPeersCount: Int = {
                if case .location = locationChannelsModel.selectedChannel {
                    return peerListModel.visibleGeohashPeerCount
                }
                // One number for the whole room: radio-reachable peers plus
                // people across the bridge (visible via carriers even while
                // this device's own bridge is off). The sheet breaks it down.
                return countAndColor.0 + bridgeService.bridgedPeerCount
            }()

            HStack(spacing: 2) {
                if locationChannelsModel.gatewayEnabled {
                    // The gateway toggle lives in the App Info settings pane
                    // now, so the indicator deep-links there.
                    Button(action: { appChromeModel.presentAppInfo() }) {
                        Image(systemName: "globe")
                            .font(.bitchatSystem(size: 12))
                            .foregroundColor(palette.secondary.opacity(0.8))
                            .headerTapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(localized: "content.accessibility.gateway_active", defaultValue: "Internet gateway active, sharing your connection with the mesh", comment: "Accessibility label for the internet gateway indicator")
                    )
                    .accessibilityHint(
                        String(localized: "content.accessibility.gateway_settings_hint", defaultValue: "Opens settings to turn the gateway on or off", comment: "Accessibility hint for the internet gateway indicator explaining a tap opens the settings sheet")
                    )
                    .help(
                        String(localized: "content.header.gateway_active", defaultValue: "Sharing your internet connection with nearby mesh peers", comment: "Tooltip for the internet gateway indicator")
                    )
                }

                if carriedMailCount > 0 {
                    Image(systemName: "figure.walk")
                        .font(.bitchatSystem(size: 12))
                        .foregroundColor(palette.secondary.opacity(0.8))
                        .headerTapTarget()
                        .accessibilityLabel(
                            String(
                                format: String(localized: "content.accessibility.carrying_mail", defaultValue: "Carrying %lld sealed messages for friends", comment: "Accessibility label for the courier mail indicator"),
                                locale: .current,
                                carriedMailCount
                            )
                        )
                        .help(
                            String(localized: "content.header.carrying_mail", defaultValue: "Carrying sealed messages for friends to deliver", comment: "Tooltip for the courier mail indicator")
                        )
                }

                if appChromeModel.hasUnreadPrivateMessages {
                    Button(action: { appChromeModel.openMostRelevantPrivateChat() }) {
                        Image(systemName: "envelope.fill")
                            .font(.bitchatSystem(size: 12))
                            .foregroundColor(Color.orange)
                            .headerTapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(localized: "content.accessibility.open_unread_private_chat", comment: "Accessibility label for the unread private chat button")
                    )
                }

                Button(action: {
                    var scopes: Set<String> = [""]
                    if let geoScope = noticesGeoScope {
                        scopes.insert(geoScope)
                    }
                    boardAlertsModel.markSeen(forScopes: scopes)
                    appChromeModel.presentNotices()
                }) {
                    // Filled whenever the current scope has notices at all
                    // (matching the orange tint); hollow means nothing here.
                    Image(systemName: scopeHasNotices || unseenNoticesCount > 0 ? "pin.fill" : "pin")
                        .font(.bitchatSystem(size: 12))
                        .foregroundColor(
                            scopeHasNotices || unseenNoticesCount > 0
                                ? Color.orange.opacity(0.8)
                                : palette.secondary.opacity(0.9)
                        )
                        .headerTapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(localized: "content.accessibility.notices", defaultValue: "Notices", comment: "Accessibility label for the notices button")
                )
                .accessibilityValue(
                    unseenNoticesCount > 0
                        ? String(
                            format: String(localized: "content.accessibility.notices_new", defaultValue: "%lld new", comment: "Accessibility value for the notices button when unseen pins arrived"),
                            locale: .current,
                            unseenNoticesCount
                        )
                        : ""
                )
                .help(
                    String(localized: "content.header.notices", defaultValue: "Notices: pinned posts for this area and the mesh", comment: "Tooltip for the notices button")
                )

                if case .location(let channel) = locationChannelsModel.selectedChannel {
                    Button(action: { locationChannelsModel.toggleBookmark(channel.geohash) }) {
                        Image(systemName: locationChannelsModel.isBookmarked(channel.geohash) ? "bookmark.fill" : "bookmark")
                            .font(.bitchatSystem(size: 12))
                            .headerTapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(
                            format: String(localized: "content.accessibility.toggle_bookmark", comment: "Accessibility label for toggling a geohash bookmark"),
                            locale: .current,
                            channel.geohash
                        )
                    )
                }

                Button(action: { appChromeModel.isLocationChannelsSheetPresented = true }) {
                    let badgeText: String = {
                        switch locationChannelsModel.selectedChannel {
                        case .mesh: return "#mesh"
                        case .location(let channel): return "#\(channel.geohash)"
                        }
                    }()
                    let badgeColor: Color = {
                        switch locationChannelsModel.selectedChannel {
                        case .mesh:
                            return Color(hue: 0.60, saturation: 0.85, brightness: 0.82)
                        case .location:
                            return palette.locationAccent
                        }
                    }()

                    Text(badgeText)
                        .bitchatFont(size: 14)
                        .foregroundColor(badgeColor)
                        .lineLimit(headerLineLimit)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                        .padding(.horizontal, 6)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .accessibilityLabel(
                            String(localized: "content.accessibility.location_channels", comment: "Accessibility label for the location channels button")
                        )
                }
                .buttonStyle(.plain)

                Button(action: {
                    withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                        showSidebar.toggle()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: headerPeerIconSize, weight: .regular))
                        Text("\(headerOtherPeersCount)")
                            .font(.system(size: headerPeerCountFontSize, weight: .regular, design: theme.bodyFontDesign))
                            .accessibilityHidden(true)
                    }
                    .foregroundColor(headerCountColor)
                    .lineLimit(headerLineLimit)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(
                        format: String(localized: "content.accessibility.people_count", comment: "Accessibility label announcing number of people in header"),
                        locale: .current,
                        headerOtherPeersCount
                    )
                )
                // Connected-vs-nobody is otherwise encoded only in the icon's
                // color; say it. With a live bridge, also say who's across it.
                .accessibilityValue(
                    showBridgedPeerCount
                    ? String(
                        format: String(localized: "content.accessibility.bridged_count", defaultValue: "%lld more people across the bridge", comment: "Accessibility value announcing the number of people reachable via the mesh bridge"),
                        locale: .current,
                        bridgeService.bridgedPeerCount
                    )
                    : (headerPeersReachable
                        ? String(localized: "content.accessibility.peers_connected", comment: "Accessibility value when peers are reachable")
                        : String(localized: "content.accessibility.peers_none", comment: "Accessibility value when no peers are reachable"))
                )
            }
            .layoutPriority(3)
            .sheet(isPresented: $showVerifySheet) {
                VerificationSheetView(isPresented: $showVerifySheet)
                    .environmentObject(verificationModel)
            }
        }
        // Fixed height is load-bearing: children fill the bar with
        // .frame(maxHeight: .infinity) tap targets, so an open-ended
        // minHeight lets the header expand to swallow the whole screen.
        // headerHeight is a @ScaledMetric, so it still grows with Dynamic
        // Type.
        .frame(height: headerHeight)
        .padding(.horizontal, 12)
        .onReceive(CourierStore.shared.$carriedCount) { count in
            carriedMailCount = count
        }
        .onReceive(BoardStore.shared.$postsSnapshot) { posts in
            boardPosts = posts
        }
        .sheet(isPresented: $appChromeModel.isLocationChannelsSheetPresented) {
            LocationChannelsSheet(isPresented: $appChromeModel.isLocationChannelsSheetPresented)
                .environmentObject(locationChannelsModel)
                .environmentObject(peerListModel)
        }
        .sheet(
            isPresented: $appChromeModel.isNoticesSheetPresented,
            onDismiss: { appChromeModel.noticesSheetPrefersGeoTab = false }
        ) {
            NoticesView(
                senderNickname: appChromeModel.nickname,
                board: appChromeModel.boardManager,
                initialTab: initialNoticesTab
            )
            .environmentObject(locationChannelsModel)
        }
        .onAppear {
            locationChannelsModel.refreshMeshChannelsIfNeeded()
        }
        .onChange(of: locationChannelsModel.selectedChannel) { _ in
            locationChannelsModel.refreshMeshChannelsIfNeeded()
        }
        .onChange(of: locationChannelsModel.permissionState) { _ in
            locationChannelsModel.refreshMeshChannelsIfNeeded()
        }
        .alert("content.alert.screenshot.title", isPresented: $appChromeModel.showScreenshotPrivacyWarning) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("content.alert.screenshot.message")
        }
        .themedChromePanel(edge: .top)
    }
}

private extension View {
    /// Expands a small header icon to a comfortably tappable, full-bar-height
    /// hit area without changing its visual size.
    func headerTapTarget() -> some View {
        frame(minWidth: 30, maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}

private extension ContentHeaderView {
    var headerLineLimit: Int? {
        dynamicTypeSize.isAccessibilitySize ? 2 : 1
    }

    /// Open the notices sheet on the tab matching the current channel: the
    /// geohash channel's notices, or the mesh-local board in mesh chat. An
    /// explicit geo-tab request (the "notes left here" hint) wins.
    var initialNoticesTab: NoticesView.Tab {
        if appChromeModel.noticesSheetPrefersGeoTab {
            return .geo
        }
        if case .location = locationChannelsModel.selectedChannel {
            return .geo
        }
        return .mesh
    }

    /// The geo scope the notices sheet would open on: the selected location
    /// channel, or the device's building geohash when chatting on mesh.
    var noticesGeoScope: String? {
        if case .location(let channel) = locationChannelsModel.selectedChannel {
            return channel.geohash
        }
        return locationChannelsModel.currentBuildingGeohash
    }

    /// Whether either tab of the notices sheet currently has content: board
    /// posts in scope, plus Nostr-only location notes when the nearby-notes
    /// counter happens to be live (it runs with the empty mesh timeline).
    var scopeHasNotices: Bool {
        boardPosts.contains { $0.geohash.isEmpty || $0.geohash == noticesGeoScope }
            || nearbyNotes.noteCount > 0
    }

    /// New pins in either visible scope since the sheet was last opened.
    var unseenNoticesCount: Int {
        let meshCount = boardAlertsModel.unseenCount(forGeohash: "")
        let geoCount = noticesGeoScope.map { boardAlertsModel.unseenCount(forGeohash: $0) } ?? 0
        return meshCount + geoCount
    }

    /// Whether anyone is actually reachable on the current channel — the
    /// state the count icon's color encodes visually.
    var headerPeersReachable: Bool {
        switch locationChannelsModel.selectedChannel {
        case .location:
            return peerListModel.visibleGeohashPeerCount > 0
        case .mesh:
            return peerListModel.connectedMeshPeerCount > 0
        }
    }

    func channelPeopleCountAndColor() -> (Int, Color) {
        switch locationChannelsModel.selectedChannel {
        case .location:
            let count = peerListModel.visibleGeohashPeerCount
            return (count, count > 0 ? palette.locationAccent : palette.secondary)
        case .mesh:
            let meshBlue = Color(hue: 0.60, saturation: 0.85, brightness: 0.82)
            let color: Color = peerListModel.connectedMeshPeerCount > 0 ? meshBlue : palette.secondary
            return (peerListModel.reachableMeshPeerCount, color)
        }
    }
}
