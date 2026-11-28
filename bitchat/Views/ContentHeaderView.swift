//
// ContentHeaderView.swift
// bitchat
//
// Unified top bar for the Nearby (#mesh) room and active Place rooms, built on
// AppTopBar so all three root tabs share identical height, spacing, and style.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct ContentHeaderView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @EnvironmentObject private var boardAlertsModel: BoardAlertsModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @ObservedObject private var bridgeService = BridgeService.shared
    @ObservedObject private var pttPreferences = PTTPreferences.shared
    @ThemedPalette private var palette

    @Binding var showSidebar: Bool

    var navItems: [SectionNavItem<AppRootTab>] = []
    var onSelectTab: ((AppRootTab) -> Void)? = nil
    var onBack: (() -> Void)? = nil
    var placeTitle: String? = nil
    var isSearchActive: Bool = false
    var onToggleSearch: (() -> Void)? = nil
    var onOpenWalkieTalkie: (() -> Void)? = nil

    @State private var boardPosts: [BoardPostPacket] = []
    @ObservedObject private var nearbyNotes = NearbyNotesCounter.shared

    @State private var pendingShareGeohash: String?
    @State private var showSharePrecisionWarning = false
    @State private var activeSharePayload: ChannelSharePayload?

    private var showBridgedPeerCount: Bool {
        if case .location = locationChannelsModel.selectedChannel { return false }
        return bridgeService.bridgedPeerCount > 0
    }

    var body: some View {
        let countAndColor = channelPeopleCountAndColor()
        let headerCountColor = countAndColor.1
        let headerOtherPeersCount: Int = {
            if case .location = locationChannelsModel.selectedChannel {
                return peerListModel.visibleGeohashPeerCount
            }
            return countAndColor.0 + bridgeService.bridgedPeerCount
        }()

        AppTopBar {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: ChromeMetrics.backChevronSize, weight: .semibold))
                            .frame(width: 28, height: ChromeMetrics.iconTapSize)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(placeTitle ?? String(localized: "tab.places", defaultValue: "Places", comment: "Back label to Places directory"))
                                .bitchatFont(size: 17, weight: .bold)
                                .lineLimit(1)
                            if case .location(let channel) = locationChannelsModel.selectedChannel {
                                Text(verbatim: "#\(channel.geohash)")
                                    .bitchatFont(size: 11)
                                    .foregroundColor(palette.locationAccent)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .foregroundColor(palette.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .layoutPriority(2)
            } else {
                HStack(spacing: 8) {
                    if !navItems.isEmpty, let onSelectTab {
                        SectionNavMenu(
                            currentTab: .nearby,
                            items: navItems,
                            onSelect: onSelectTab
                        )
                        .layoutPriority(2)
                    } else {
                        Text(String(localized: "tab.nearby", defaultValue: "Nearby", comment: "Header title for the Nearby mesh tab"))
                            .bitchatFont(size: 19, weight: .bold)
                            .lineLimit(1)
                            .foregroundColor(palette.primary)
                            .layoutPriority(2)
                    }

                    Button {
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            showSidebar.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 12, weight: .semibold))
                            Text(headerOtherPeersCount, format: .number)
                                .bitchatFont(size: 12, weight: .semibold)
                        }
                        .foregroundColor(headerCountColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(headerCountColor.opacity(0.14))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(
                            format: String(localized: "content.accessibility.people_count", comment: "Accessibility label announcing number of people in header"),
                            locale: .current,
                            headerOtherPeersCount
                        )
                    )
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
            }
        } trailing: {
            if let onOpenWalkieTalkie,
               case .mesh = locationChannelsModel.selectedChannel {
                let someoneSpeaking = conversationUIModel.activeLiveVoiceTalker != nil
                TopBarIconButton(
                    systemImage: "radio",
                    accessibilityLabel: String(localized: "walkie.accessibility.open", defaultValue: "Open walkie-talkie", comment: "Accessibility label for the header walkie-talkie button"),
                    color: someoneSpeaking ? Color.red : (pttPreferences.liveVoiceEnabled ? palette.accent : palette.secondary),
                    action: onOpenWalkieTalkie
                )
                .modifier(PulsingOpacityModifier(active: someoneSpeaking))
            }

            if let onToggleSearch {
                TopBarIconButton(
                    systemImage: "magnifyingglass",
                    accessibilityLabel: String(localized: "chat.search.accessibility", defaultValue: "Search in chat", comment: "Accessibility label for the in-chat search toggle button"),
                    color: isSearchActive ? palette.accent : palette.secondary,
                    action: onToggleSearch
                )
            }

            if case .location(let channel) = locationChannelsModel.selectedChannel {
                TopBarIconButton(
                    systemImage: locationChannelsModel.isBookmarked(channel.geohash) ? "bookmark.fill" : "bookmark",
                    accessibilityLabel: String(
                        format: String(localized: "content.accessibility.toggle_bookmark", comment: "Accessibility label for toggling a geohash bookmark"),
                        locale: .current,
                        channel.geohash
                    ),
                    color: locationChannelsModel.isBookmarked(channel.geohash) ? palette.locationAccent : palette.secondary,
                    action: { locationChannelsModel.toggleBookmark(channel.geohash) }
                )

                TopBarIconButton(
                    systemImage: "square.and.arrow.up",
                    accessibilityLabel: String(localized: "channel.share.action", defaultValue: "share channel", comment: "Accessibility label for sharing the active location channel"),
                    color: palette.secondary,
                    action: { requestHeaderShare(forGeohash: channel.geohash) }
                )
            }

            TopBarIconButton(
                systemImage: scopeHasNotices || unseenNoticesCount > 0 ? "pin.fill" : "pin",
                accessibilityLabel: String(localized: "content.accessibility.notices", defaultValue: "Notices", comment: "Accessibility label for the notices button"),
                color: scopeHasNotices || unseenNoticesCount > 0 ? Color.orange : palette.secondary,
                badgeCount: unseenNoticesCount,
                action: {
                    if case .location(let channel) = locationChannelsModel.selectedChannel {
                        boardAlertsModel.markSeen(forScopes: [channel.geohash])
                    } else {
                        boardAlertsModel.markSeen(forScopes: [""])
                    }
                    appChromeModel.presentNotices()
                }
            )

            if case .location = locationChannelsModel.selectedChannel {
                Button {
                    withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                        showSidebar.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text(headerOtherPeersCount, format: .number)
                            .bitchatFont(size: 12, weight: .semibold)
                    }
                    .foregroundColor(headerCountColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(headerCountColor.opacity(0.14))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
                .accessibilityLabel(
                    String(
                        format: String(localized: "content.accessibility.people_count", comment: "Accessibility label announcing number of people in header"),
                        locale: .current,
                        headerOtherPeersCount
                    )
                )
            }
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
                initialTab: initialNoticesTab,
                lockedScope: initialNoticesTab
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
        .alert(String(localized: "content.alert.screenshot.title"), isPresented: $appChromeModel.showScreenshotPrivacyWarning) {
            Button(String(localized: "common.ok"), role: .cancel) {}
        } message: {
            Text(String(localized: "content.alert.screenshot.message"))
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
            Button(String(localized: "common.cancel"), role: .cancel) {
                pendingShareGeohash = nil
            }
        } message: {
            Text(String(localized: "channel.share.precision_warning.message", defaultValue: "this channel covers a small area. an invite sent over sms or imessage is visible to the carrier and both handsets — it discloses interest in that place, not only that someone uses bitchat.", comment: "Body of the confirmation before sharing a fine-precision geohash invite"))
        }
        .sheet(item: $activeSharePayload) { payload in
            ShareActivityView(text: payload.text)
        }
        .stealthTripleTapPanicWipe {
            appChromeModel.requestPanicWipe()
        }
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

private extension ContentHeaderView {
    var initialNoticesTab: NoticesView.Tab {
        if appChromeModel.noticesSheetPrefersGeoTab {
            return .geo
        }
        if case .location = locationChannelsModel.selectedChannel {
            return .geo
        }
        return .mesh
    }

    var scopeHasNotices: Bool {
        if case .location(let channel) = locationChannelsModel.selectedChannel {
            let isCurrentBuilding = channel.geohash == locationChannelsModel.currentBuildingGeohash
            return boardPosts.contains { $0.geohash == channel.geohash }
                || (isCurrentBuilding && nearbyNotes.noteCount > 0)
        }
        return boardPosts.contains { $0.geohash.isEmpty }
    }

    var unseenNoticesCount: Int {
        if case .location(let channel) = locationChannelsModel.selectedChannel {
            return boardAlertsModel.unseenCount(forGeohash: channel.geohash)
        }
        return boardAlertsModel.unseenCount(forGeohash: "")
    }

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
            let count = peerListModel.reachableMeshPeerCount
            let color: Color = peerListModel.connectedMeshPeerCount > 0 ? palette.accentBlue : palette.secondary
            return (count, color)
        }
    }
}
