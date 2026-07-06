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
                    String(localized: "content.accessibility.app_info_hint", comment: "Accessibility hint on the bitchat/ logo explaining a tap opens app info")
                )
                .accessibilityAction {
                    appChromeModel.presentAppInfo()
                }

            HStack(spacing: 0) {
                Text(verbatim: "@")
                    .bitchatFont(size: 14)
                    .foregroundColor(palette.secondary)

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
                return countAndColor.0
            }()

            HStack(spacing: 2) {
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
                        String(localized: "content.accessibility.location_notes", comment: "Accessibility label for location notes button")
                    )
                }

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

                if case .mesh = locationChannelsModel.selectedChannel {
                    Text(verbatim: "public · unencrypted")
                        .bitchatFont(size: 10)
                        .foregroundColor(palette.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel(Text(verbatim: "public, unencrypted"))
                }

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
                // color; say it.
                .accessibilityValue(
                    headerPeersReachable
                    ? String(localized: "content.accessibility.peers_connected", comment: "Accessibility value when peers are reachable")
                    : String(localized: "content.accessibility.peers_none", comment: "Accessibility value when no peers are reachable")
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
                Text("content.notes.title")
                    .bitchatFont(size: 16, weight: .bold)
                Spacer()
                SheetCloseButton { showLocationNotes = false }
                    .foregroundColor(palette.primary)
            }
            .frame(minHeight: headerHeight)
            .padding(.horizontal, 12)
            .themedChromePanel(edge: .top)
            Text("content.notes.location_unavailable")
                .bitchatFont(size: 14)
                .foregroundColor(palette.secondary)
            Button("content.location.enable") {
                locationChannelsModel.enableAndRefresh()
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .themedSheetBackground()
        .foregroundColor(palette.primary)
    }
}
