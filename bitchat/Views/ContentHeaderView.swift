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
    @ThemedPalette private var palette

    @Binding var showSidebar: Bool
    @Binding var showVerifySheet: Bool
    @Binding var showLocationNotes: Bool
    @Binding var notesGeohash: String?
    var isNicknameFieldFocused: FocusState<Bool>.Binding

    let headerHeight: CGFloat
    let headerPeerIconSize: CGFloat
    let headerPeerCountFontSize: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: "bitchat/")
                .font(.bitchatSystem(size: 18, weight: .medium, design: .monospaced))
                .foregroundColor(palette.primary)
                .onTapGesture(count: 3) {
                    appChromeModel.panicClearAllData()
                }
                .onTapGesture(count: 1) {
                    appChromeModel.presentAppInfo()
                }

            HStack(spacing: 0) {
                Text(verbatim: "@")
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(palette.secondary)

                TextField(
                    "content.input.nickname_placeholder",
                    text: Binding(
                        get: { appChromeModel.nickname },
                        set: { appChromeModel.setNickname($0) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.bitchatSystem(size: 14, design: .monospaced))
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

            HStack(spacing: 10) {
                if appChromeModel.hasUnreadPrivateMessages {
                    Button(action: { appChromeModel.openMostRelevantPrivateChat() }) {
                        Image(systemName: "envelope.fill")
                            .font(.bitchatSystem(size: 12))
                            .foregroundColor(Color.orange)
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
                        HStack(alignment: .center, spacing: 4) {
                            Image(systemName: "note.text")
                                .font(.bitchatSystem(size: 12))
                                .foregroundColor(Color.orange.opacity(0.8))
                                .padding(.top, 1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
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
                            return palette.primary
                        }
                    }()

                    Text(badgeText)
                        .font(.bitchatSystem(size: 14, design: .monospaced))
                        .foregroundColor(badgeColor)
                        .lineLimit(headerLineLimit)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                        .accessibilityLabel(
                            String(localized: "content.accessibility.location_channels", comment: "Accessibility label for the location channels button")
                        )
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
                .padding(.trailing, 2)

                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: headerPeerIconSize, weight: .regular))
                        .accessibilityLabel(
                            String(
                                format: String(localized: "content.accessibility.people_count", comment: "Accessibility label announcing number of people in header"),
                                locale: .current,
                                headerOtherPeersCount
                            )
                        )
                    Text("\(headerOtherPeersCount)")
                        .font(.system(size: headerPeerCountFontSize, weight: .regular, design: .monospaced))
                        .accessibilityHidden(true)
                }
                .foregroundColor(headerCountColor)
                .padding(.leading, 2)
                .lineLimit(headerLineLimit)
                .fixedSize(horizontal: true, vertical: false)
            }
            .layoutPriority(3)
            .onTapGesture {
                withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                    showSidebar.toggle()
                }
            }
            .sheet(isPresented: $showVerifySheet) {
                VerificationSheetView(isPresented: $showVerifySheet)
                    .environmentObject(verificationModel)
            }
        }
        .frame(height: headerHeight)
        .padding(.horizontal, 12)
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
        .background(palette.background.opacity(0.95))
    }
}

private extension ContentHeaderView {
    var headerLineLimit: Int? {
        dynamicTypeSize.isAccessibilitySize ? 2 : 1
    }

    func channelPeopleCountAndColor() -> (Int, Color) {
        switch locationChannelsModel.selectedChannel {
        case .location:
            let count = peerListModel.visibleGeohashPeerCount
            return (count, count > 0 ? palette.primary : Color.secondary)
        case .mesh:
            let meshBlue = Color(hue: 0.60, saturation: 0.85, brightness: 0.82)
            let color: Color = peerListModel.connectedMeshPeerCount > 0 ? meshBlue : Color.secondary
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
                    .font(.bitchatSystem(size: 16, weight: .bold, design: .monospaced))
                Spacer()
                Button(action: { showLocationNotes = false }) {
                    Image(systemName: "xmark")
                        .font(.bitchatSystem(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(palette.primary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "common.close", comment: "Accessibility label for close buttons"))
            }
            .frame(height: headerHeight)
            .padding(.horizontal, 12)
            .background(palette.background.opacity(0.95))
            Text("content.notes.location_unavailable")
                .font(.bitchatSystem(size: 14, design: .monospaced))
                .foregroundColor(palette.secondary)
            Button("content.location.enable") {
                locationChannelsModel.enableAndRefresh()
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .background(palette.background)
        .foregroundColor(palette.primary)
    }
}
