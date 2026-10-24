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
    /// How far a rounded display corner the safe area leaves uncovered
    /// reaches into the bar from each side (TopCornerClearance).
    var leadingCornerReach: CGFloat = 0
    var trailingCornerReach: CGFloat = 0
    /// The channel of the pane this bar heads in the split layout. Nil
    /// follows the selection (the single column, macOS).
    var paneChannel: ChannelID? = nil
    /// Whether this bar carries the app-wide chrome: the logo, nickname,
    /// app-wide indicators and notices pin, and the app-wide presentations
    /// (location channels, notices, QR, the screenshot alert). Exactly one
    /// mounted bar may, or two would race to present the same sheet; in the
    /// split layout the trailing bar doesn't.
    var carriesAppChrome = true
    /// Replaces the people button's sheet toggle (split layout: the pane's
    /// people popover).
    var onPeopleTap: (() -> Void)? = nil
    /// Replaces the badge's location-channels sheet (split layout, trailing:
    /// the inline picker).
    var onBadgeTap: (() -> Void)? = nil
    /// The badge is a label rather than a button (split layout, leading: the
    /// pane is #mesh, whatever the selection).
    var isBadgeStatic = false
    /// Holds back the app-wide alert this bar hosts (the screenshot
    /// warning) while the root presents something over the layout (the
    /// split layout's people popover, or its legacy-media consent dialog
    /// once it shows): presenting it then would fail and leave its flag,
    /// which root alerts wait on, set for good. It shows once that closes.
    /// Asked each time rather than passed as a value: SwiftUI also runs
    /// the bindings of earlier renders, and a value they captured would be
    /// stale.
    var defersAlerts: () -> Bool = { false }

    /// Courier envelopes this device is carrying for offline third parties.
    @State private var carriedMailCount = 0

    /// Board posts mirrored from the store so the pin icon can show when the
    /// current scope has notices.
    @State private var boardPosts: [BoardPostPacket] = []

    /// Nostr-only location notes at this place (live while the empty mesh
    /// timeline is showing) — they should light the pin too.
    @ObservedObject private var nearbyNotes = NearbyNotesCounter.shared

    @State private var pendingShareGeohash: String?
    @State private var showSharePrecisionWarning = false
    @State private var activeSharePayload: ChannelSharePayload?

    /// How far the content already sits in from the bar's edges: 12pt, and
    /// glass floats the bar as a panel another 8pt in (themedChromePanel).
    private var cornerContentInset: CGFloat {
        theme.usesGlassChrome ? 20 : 12
    }

    /// The channel this bar shows: its pane's, or the selection. Every
    /// channel-dependent part of the bar reads this, except the notices pin:
    /// app chrome, it keeps today's scope (the mesh plus the selection).
    private var channel: ChannelID {
        paneChannel ?? locationChannelsModel.selectedChannel
    }

    /// The bridged-people count belongs to the mesh channel only.
    private var showBridgedPeerCount: Bool {
        if case .location = channel { return false }
        return bridgeService.bridgedPeerCount > 0
    }

    var body: some View {
        HStack(spacing: 0) {
            if carriesAppChrome {
                appIdentity
            }

            Spacer()

            let countAndColor = channelPeopleCountAndColor()
            let headerCountColor = countAndColor.1
            let headerOtherPeersCount: Int = {
                if case .location = channel {
                    return peerListModel.visibleGeohashPeerCount
                }
                // One number for the whole room: radio-reachable peers plus
                // people across the bridge (visible via carriers even while
                // this device's own bridge is off). The sheet breaks it down.
                return countAndColor.0 + bridgeService.bridgedPeerCount
            }()

            HStack(spacing: 2) {
                if carriesAppChrome {
                    appIndicators
                }

                if case .location(let location) = channel {
                    Button(action: { locationChannelsModel.toggleBookmark(location.geohash) }) {
                        Image(systemName: locationChannelsModel.isBookmarked(location.geohash) ? "bookmark.fill" : "bookmark")
                            .font(.bitchatSystem(size: 12))
                            .headerTapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(
                            format: String(localized: "content.accessibility.toggle_bookmark", comment: "Accessibility label for toggling a geohash bookmark"),
                            locale: .current,
                            location.geohash
                        )
                    )

                    Button(action: { requestHeaderShare(forGeohash: location.geohash) }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.bitchatSystem(size: 12))
                            .headerTapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(localized: "channel.share.action", defaultValue: "share channel", comment: "Accessibility label for sharing the active location channel")
                    )
                }

                channelBadge

                Button(action: {
                    if let onPeopleTap {
                        onPeopleTap()
                    } else {
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            showSidebar.toggle()
                        }
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
            .sheet(isPresented: hosted($showVerifySheet)) {
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
        // Inside the bar's background or glass panel; horizontal only.
        .padding(.leading, TopCornerClearance.padding(
            forReach: leadingCornerReach,
            contentInset: cornerContentInset
        ))
        .padding(.trailing, TopCornerClearance.padding(
            forReach: trailingCornerReach,
            contentInset: cornerContentInset
        ))
        // The mail indicator and the notices pin are app chrome; a bar
        // without them has nothing to redraw for.
        .onReceive(CourierStore.shared.$carriedCount) { count in
            guard carriesAppChrome else { return }
            carriedMailCount = count
        }
        .onReceive(BoardStore.shared.$postsSnapshot) { posts in
            guard carriesAppChrome else { return }
            boardPosts = posts
        }
        .sheet(isPresented: hosted($appChromeModel.isLocationChannelsSheetPresented)) {
            LocationChannelsSheet(isPresented: $appChromeModel.isLocationChannelsSheetPresented)
                .environmentObject(locationChannelsModel)
                .environmentObject(peerListModel)
        }
        .sheet(
            isPresented: hosted($appChromeModel.isNoticesSheetPresented),
            onDismiss: { appChromeModel.noticesSheetPrefersGeoTab = false }
        ) {
            NoticesView(
                senderNickname: appChromeModel.nickname,
                board: appChromeModel.boardManager,
                initialTab: initialNoticesTab
            )
            .environmentObject(locationChannelsModel)
        }
        // The building cell scopes the notices pin on #mesh: one ask, from
        // the bar that carries the pin.
        .onAppear {
            guard carriesAppChrome else { return }
            locationChannelsModel.refreshMeshChannelsIfNeeded()
        }
        .onChange(of: locationChannelsModel.selectedChannel) { _ in
            guard carriesAppChrome else { return }
            locationChannelsModel.refreshMeshChannelsIfNeeded()
        }
        .onChange(of: locationChannelsModel.permissionState) { _ in
            guard carriesAppChrome else { return }
            locationChannelsModel.refreshMeshChannelsIfNeeded()
        }
        .alert("content.alert.screenshot.title", isPresented: screenshotWarningBinding) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("content.alert.screenshot.message")
        }
        .confirmationDialog(
            String(localized: "channel.share.precision_warning.title", defaultValue: "share a precise location channel?", comment: "Title of the confirmation before sharing a neighborhood-or-finer geohash invite"),
            isPresented: $showSharePrecisionWarning,
            titleVisibility: .visible
        ) {
            Button(String(localized: "channel.share.precision_warning.confirm", defaultValue: "share anyway", comment: "Confirms sharing a fine-precision location channel after the OpSec warning")) {
                if let gh = pendingShareGeohash {
                    activeSharePayload = ChannelSharePayload(text: ChannelShare.payload(forGeohash: gh))
                }
                pendingShareGeohash = nil
            }
            Button("common.cancel", role: .cancel) {
                pendingShareGeohash = nil
            }
        } message: {
            Text(String(localized: "channel.share.precision_warning.message", defaultValue: "this channel covers a small area. an invite sent over sms or imessage is visible to the carrier and both handsets — it discloses interest in that place, not only that someone uses bitchat.", comment: "Body of the confirmation before sharing a fine-precision geohash invite"))
        }
        .sheet(item: $activeSharePayload) { payload in
            ShareActivityView(text: payload.text)
        }
        .themedChromePanel(edge: .top)
    }

    /// The logo (App Info; a triple tap asks for the panic wipe) and the
    /// nickname field.
    @ViewBuilder
    private var appIdentity: some View {
        Text(verbatim: "bitchat/")
            .bitchatFont(size: 18, weight: .medium)
            .lineLimit(1)
            .foregroundColor(palette.primary)
            // When icons crowd the header, squeeze the nickname first
            // (priority 0) and the logo only as a last resort; the icon
            // cluster at priority 3 never gives up width.
            .layoutPriority(2)
            .onTapGesture(count: 3) {
                // Confirm before destroying: the same logo is the single-tap
                // App Info entry point and sits beside the nickname field, so
                // a fumbled tap must never be able to wipe the device. The
                // dialog matches the Settings-pane panic button; under duress
                // it costs one extra tap.
                appChromeModel.requestPanicWipe()
            }
            .onTapGesture(count: 1) {
                appChromeModel.presentAppInfo()
            }
            // The confirmation dialog itself is hosted on ContentView
            // (next to the failed-wipe banner), not on this Text: a host
            // that can be covered or removed could take the pending
            // dialog down with it.
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
    }

    /// App-wide state: the internet gateway, courier mail, unread DMs and
    /// the notices pin.
    @ViewBuilder
    private var appIndicators: some View {
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
    }

    /// The channel's name. A button to the location channels (or the bar's
    /// own `onBadgeTap`), or a label where the pane's channel is fixed.
    @ViewBuilder
    private var channelBadge: some View {
        if isBadgeStatic {
            badgeLabel
        } else {
            Button(action: {
                if let onBadgeTap {
                    onBadgeTap()
                } else {
                    appChromeModel.isLocationChannelsSheetPresented = true
                }
            }) {
                badgeLabel
                    .accessibilityLabel(
                        String(localized: "content.accessibility.location_channels", comment: "Accessibility label for the location channels button")
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var badgeLabel: some View {
        let badgeText: String = {
            switch channel {
            case .mesh: return "#mesh"
            case .location(let location): return "#\(location.geohash)"
            }
        }()
        let badgeColor: Color = {
            switch channel {
            case .mesh:
                return Color(hue: 0.60, saturation: 0.85, brightness: 0.82)
            case .location:
                return palette.locationAccent
            }
        }()

        return Text(badgeText)
            .bitchatFont(size: 14)
            .foregroundColor(badgeColor)
            .lineLimit(headerLineLimit)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    /// An app-wide presentation's flag: bound on the bar that carries the
    /// app chrome, never presenting from any other.
    private func hosted(_ isPresented: Binding<Bool>) -> Binding<Bool> {
        carriesAppChrome ? isPresented : .constant(false)
    }

    /// The screenshot warning, hosted like the sheets and held back while
    /// `defersAlerts`.
    ///
    /// Only a dismissal clears the flag: the alert's OK, or a presentation
    /// SwiftUI couldn't make (a flag left set would hold every root alert
    /// back). Never while the warning is held back, when SwiftUI also writes
    /// false as it takes it down, and from an earlier render's instance of
    /// this binding too: the warning must come back once that closes. The
    /// flag and the deferral are read live, never from this binding's
    /// capture; a flag already clear isn't written again; and the write
    /// waits a hop, as SwiftUI can call this inside a view update, where
    /// publishing is undefined.
    private var screenshotWarningBinding: Binding<Bool> {
        Binding(
            get: {
                carriesAppChrome
                    && appChromeModel.showScreenshotPrivacyWarning
                    && !defersAlerts()
            },
            set: { isPresented in
                guard !isPresented,
                      carriesAppChrome,
                      appChromeModel.showScreenshotPrivacyWarning,
                      !defersAlerts() else {
                    return
                }
                Task { @MainActor in
                    appChromeModel.showScreenshotPrivacyWarning = false
                }
            }
        )
    }

    private func requestHeaderShare(forGeohash geohash: String) {
        if ChannelShare.shouldWarn(forGeohash: geohash) {
            pendingShareGeohash = geohash
            showSharePrecisionWarning = true
        } else {
            activeSharePayload = ChannelSharePayload(text: ChannelShare.payload(forGeohash: geohash))
        }
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

    // The notices pin is app chrome: one pin, on the bar that carries it,
    // scoped as today to the mesh plus the selected location channel (in
    // the split layout, the trailing pane's), whatever the bar's own pane.

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

    /// Whether anyone is actually reachable on the bar's channel — the
    /// state the count icon's color encodes visually.
    var headerPeersReachable: Bool {
        switch channel {
        case .location:
            return peerListModel.visibleGeohashPeerCount > 0
        case .mesh:
            return peerListModel.connectedMeshPeerCount > 0
        }
    }

    func channelPeopleCountAndColor() -> (Int, Color) {
        switch channel {
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
