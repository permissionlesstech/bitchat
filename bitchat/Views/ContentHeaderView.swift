import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ContentHeaderView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var verificationModel: VerificationModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette

    @Binding var showSidebar: Bool
    @Binding var showVerifySheet: Bool
    @Binding var showLocationNotes: Bool
    @Binding var notesGeohash: String?
    var isNicknameFieldFocused: FocusState<Bool>.Binding

    let headerHeight: CGFloat
    let headerPeerIconSize: CGFloat
    let headerPeerCountFontSize: CGFloat

    /// Courier envelopes this device is carrying for offline third parties.
    @State private var carriedMailCount = 0

    /// Bulletin board sheet for the current channel context.
    @State private var showBoard = false

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: "bitchat/")
                .bitchatFont(size: 18, weight: .medium)
                .foregroundColor(palette.primary)
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
                    String(localized: "content.accessibility.app_info_hint", defaultValue: "shows app info", comment: "Accessibility hint on the bitchat/ logo explaining a tap opens app info")
                )
                .accessibilityAction {
                    appChromeModel.presentAppInfo()
                }

            HStack(spacing: 0) {
                Text(verbatim: "@")
                    .bitchatFont(size: 14)
                    .foregroundColor(palette.secondary)

                TextField(
                    String(localized: "content.input.nickname_placeholder", defaultValue: "nickname"),
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
                return countAndColor.0
            }()

            HStack(spacing: 2) {
                if locationChannelsModel.gatewayEnabled {
                    Image(systemName: "globe")
                        .font(.bitchatSystem(size: 12))
                        .foregroundColor(palette.secondary.opacity(0.8))
                        .headerTapTarget()
                        .accessibilityLabel(
                            String(localized: "content.accessibility.gateway_active", defaultValue: "Internet gateway active, sharing your connection with the mesh", comment: "Accessibility label for the internet gateway indicator")
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
                        String(localized: "content.accessibility.open_unread_private_chat", defaultValue: "open unread private chat", comment: "Accessibility label for the unread private chat button")
                    )
                }

                if case .mesh = locationChannelsModel.selectedChannel,
                   locationChannelsModel.permissionState == .authorized {
                    Button(action: {
                        locationChannelsModel.enableAndRefresh()
                        notesGeohash = locationChannelsModel.currentBuildingGeohash
                        showLocationNotes = true
                    }) {
                        Image(systemName: "note.text")
                            .font(.bitchatSystem(size: 12))
                            .foregroundColor(Color.orange.opacity(0.8))
                            .headerTapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(localized: "content.accessibility.location_notes", defaultValue: "location notes for this place", comment: "Accessibility label for location notes button")
                    )
                }

                Button(action: { showBoard = true }) {
                    Image(systemName: "pin")
                        .font(.bitchatSystem(size: 12))
                        .foregroundColor(palette.secondary.opacity(0.9))
                        .headerTapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(localized: "content.accessibility.board", defaultValue: "Bulletin board", comment: "Accessibility label for the bulletin board button")
                )
                .help(
                    String(localized: "content.header.board", defaultValue: "Bulletin board: persistent notices for this channel", comment: "Tooltip for the bulletin board button")
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
                            format: String(localized: "content.accessibility.toggle_bookmark", defaultValue: "toggle bookmark for #%@", comment: "Accessibility label for toggling a geohash bookmark"),
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
                            String(localized: "content.accessibility.location_channels", defaultValue: "location channels", comment: "Accessibility label for the location channels button")
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
                        format: String(localized: "content.accessibility.people_count", defaultValue: "%#@people@", comment: "Accessibility label announcing number of people in header"),
                        locale: .current,
                        headerOtherPeersCount
                    )
                )
                // Connected-vs-nobody is otherwise encoded only in the icon's
                // color; say it.
                .accessibilityValue(
                    headerPeersReachable
                    ? String(localized: "content.accessibility.peers_connected", defaultValue: "connected", comment: "Accessibility value when peers are reachable")
                    : String(localized: "content.accessibility.peers_none", defaultValue: "no one reachable", comment: "Accessibility value when no peers are reachable")
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
        .sheet(isPresented: $appChromeModel.isLocationChannelsSheetPresented) {
            LocationChannelsSheet(isPresented: $appChromeModel.isLocationChannelsSheetPresented)
                .environmentObject(locationChannelsModel)
                .environmentObject(peerListModel)
        }
        .sheet(isPresented: $showBoard) {
            BoardView(
                geohash: boardGeohash,
                senderNickname: appChromeModel.nickname,
                board: appChromeModel.boardManager
            )
        }
        .sheet(isPresented: $showLocationNotes, onDismiss: {
            notesGeohash = nil
        }) {
            Group {
                if let geohash = notesGeohash ?? locationChannelsModel.currentBuildingGeohash {
                    LocationNotesView(
                        geohash: geohash,
                        senderNickname: appChromeModel.nickname
                    )
                    .environmentObject(locationChannelsModel)
                } else {
                    ContentLocationNotesUnavailableView(
                        showLocationNotes: $showLocationNotes,
                        headerHeight: headerHeight
                    )
                    .environmentObject(locationChannelsModel)
                }
            }
            .onAppear {
                locationChannelsModel.enableLocationChannels()
                locationChannelsModel.beginLiveRefresh()
            }
            .onDisappear {
                locationChannelsModel.endLiveRefresh()
            }
            .onChange(of: locationChannelsModel.availableChannels) { channels in
                if let current = channels.first(where: { $0.level == .building })?.geohash,
                   notesGeohash != current {
                    notesGeohash = current
                    #if os(iOS)
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.prepare()
                    generator.impactOccurred()
                    #endif
                }
            }
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
        .alert(String(localized: "content.alert.screenshot.title", defaultValue: "heads up"), isPresented: $appChromeModel.showScreenshotPrivacyWarning) {
            Button(String(localized: "common.ok", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "content.alert.screenshot.message", defaultValue: "screenshots of location channels will reveal your location. think before sharing publicly."))
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

    /// The board scope for the current channel: the geohash channel's board,
    /// or the mesh-local board ("") in mesh chat.
    var boardGeohash: String {
        if case .location(let channel) = locationChannelsModel.selectedChannel {
            return channel.geohash
        }
        return ""
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

private struct ContentLocationNotesUnavailableView: View {
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @ThemedPalette private var palette

    @Binding var showLocationNotes: Bool

    let headerHeight: CGFloat

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(String(localized: "content.notes.title", defaultValue: "notes"))
                    .bitchatFont(size: 16, weight: .bold)
                Spacer()
                SheetCloseButton { showLocationNotes = false }
                    .foregroundColor(palette.primary)
            }
            .frame(minHeight: headerHeight)
            .padding(.horizontal, 12)
            .themedChromePanel(edge: .top)
            Text(String(localized: "content.notes.location_unavailable", defaultValue: "location unavailable"))
                .bitchatFont(size: 14)
                .foregroundColor(palette.secondary)
            Button(String(localized: "content.location.enable", defaultValue: "enable location")) {
                locationChannelsModel.enableAndRefresh()
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .themedSheetBackground()
        .foregroundColor(palette.primary)
    }
}
