//
// PlacesTabView.swift
// bitchat
//
// First-class Places tab using the unified AppTopBar and ThemedCard system:
// surfaces human-readable local location channels, quick join, bookmarks, and
// the 3D globe picker, switching cleanly into the selected place's room.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CoreLocation
import SwiftUI

struct PlacesTabView<RoomContent: View>: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette

    @Binding var activeLocationChannel: GeohashChannel?
    @ViewBuilder let roomContent: (GeohashChannel) -> RoomContent

    @State private var customGeohash = ""
    @State private var customError: String?
    @State private var showGlobePicker = false
    @State private var pickedGeohash: String?
    @State private var pendingShareGeohash: String?
    @State private var showSharePrecisionWarning = false
    @State private var activeSharePayload: ChannelSharePayload?

    var body: some View {
        Group {
            if let activeChannel = activeLocationChannel {
                roomContent(activeChannel)
            } else {
                placesDirectory
            }
        }
        .onAppear {
            locationChannelsModel.beginLiveRefresh()
        }
        .onDisappear {
            locationChannelsModel.endLiveRefresh()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                locationChannelsModel.beginLiveRefresh()
            } else {
                locationChannelsModel.endLiveRefresh()
            }
        }
        .onChange(of: locationChannelsModel.permissionState) { newValue in
            if newValue == .authorized {
                locationChannelsModel.refreshChannels()
            }
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
        #if os(iOS)
        .fullScreenCover(isPresented: $showGlobePicker, onDismiss: applyPickedGeohash) {
            globePicker
        }
        #else
        .sheet(isPresented: $showGlobePicker, onDismiss: applyPickedGeohash) {
            globePicker
        }
        #endif
    }

    private var placesDirectory: some View {
        VStack(spacing: 0) {
            AppTopBar {
                Text(String(localized: "tab.places", defaultValue: "Places", comment: "Navigation title for the Places tab"))
                    .bitchatFont(size: 19, weight: .bold)
                    .foregroundColor(palette.primary)
            } trailing: {
                TopBarIconButton(
                    systemImage: "globe.americas.fill",
                    accessibilityLabel: String(localized: "location_channels.accessibility.open_map", defaultValue: "open map", comment: "Accessibility label for opening the globe picker"),
                    color: palette.locationAccent,
                    action: { showGlobePicker = true }
                )

                TopBarIconButton(
                    systemImage: "gearshape",
                    accessibilityLabel: String(localized: "chats.accessibility.settings", defaultValue: "Settings", comment: "Accessibility label for the settings gear button"),
                    color: palette.secondary,
                    action: { appChromeModel.presentAppInfo(pane: .settings) }
                )
            }

            if !theme.usesGlassChrome {
                Rectangle()
                    .fill(palette.divider)
                    .frame(height: 1)
            }

            if appChromeModel.torBlocked {
                ConnectivityStatusBanner(issue: .torBlocked)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    locationPermissionCard
                    nearbyPlacesSection

                    if let suggestion = QuickJoinSuggestion.current() {
                        quickJoinCard(suggestion)
                    }

                    if !locationChannelsModel.bookmarks.isEmpty {
                        bookmarksSection(locationChannelsModel.bookmarks)
                    }

                    teleportSection
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemedRootBackground())
    }

    @ViewBuilder
    private var locationPermissionCard: some View {
        switch locationChannelsModel.permissionState {
        case .notDetermined:
            ThemedCard {
                Text(String(localized: "places.permission.title", defaultValue: "Discover rooms around you", comment: "Headline prompting for location permission in Places tab"))
                    .bitchatFont(size: 16, weight: .semibold)
                    .foregroundColor(palette.primary)
                Text(String(localized: "places.permission.subtitle", defaultValue: "Your exact coordinates never leave your device — bitchat only computes broad area rooms like your neighborhood or city.", comment: "Explanation of privacy-preserving location rooms"))
                    .bitchatFont(size: 13)
                    .foregroundColor(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    locationChannelsModel.enableLocationChannels()
                } label: {
                    Text(String(localized: "places.permission.cta", defaultValue: "Enable Nearby Places", comment: "CTA button to request location permission in Places tab"))
                        .bitchatFont(size: 14, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(palette.accent)
                        .foregroundColor(palette.accentForeground)
                        .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
                }
                .buttonStyle(.plain)
            }

        case .denied, .restricted:
            ThemedCard {
                Text("location_channels.permission_denied")
                    .bitchatFont(size: 13)
                    .foregroundColor(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("location_channels.action.open_settings", action: SystemSettings.location.open)
                    .bitchatFont(size: 13, weight: .semibold)
                    .foregroundColor(palette.accent)
                    .buttonStyle(.plain)
            }

        case .authorized:
            EmptyView()
        }
    }

    @ViewBuilder
    private var nearbyPlacesSection: some View {
        let nearby = locationChannelsModel.availableChannels.filter { $0.level != .building }
        if !nearby.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ThemedSectionLabel(text: String(localized: "places.section.around_you", defaultValue: "AROUND YOU", comment: "Section header for local place channels"))

                ThemedCard(padding: 0, spacing: 0) {
                    ForEach(Array(nearby.enumerated()), id: \.element.id) { index, channel in
                        let placeName = locationChannelsModel.locationName(for: channel.level)
                        let primaryTitle = (placeName?.isEmpty == false ? placeName! : channel.level.displayName)
                        let coverage = GeohashCoverage.string(forPrecision: channel.geohash.count)
                        let count = peerListModel.participantCount(for: channel.geohash)
                        placeRow(
                            title: primaryTitle,
                            subtitle: "\(channel.level.displayName) · \(coverage) · #\(channel.geohash)",
                            count: count,
                            isHighPrecision: channel.level == .neighborhood || channel.level == .block || channel.level == .building,
                            geohash: channel.geohash
                        ) {
                            locationChannelsModel.markTeleported(for: channel.geohash, false)
                            locationChannelsModel.select(.location(channel))
                            activeLocationChannel = channel
                        }
                        if index < nearby.count - 1 {
                            Rectangle()
                                .fill(palette.divider)
                                .frame(height: 1)
                                .padding(.leading, 14)
                        }
                    }
                }
            }
        } else if locationChannelsModel.permissionState == .authorized {
            ThemedCard {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("location_channels.loading_nearby")
                        .bitchatFont(size: 13)
                        .foregroundColor(palette.secondary)
                }
            }
        }
    }

    private func quickJoinCard(_ suggestion: QuickJoinSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemedSectionLabel(text: String(localized: "places.section.regional", defaultValue: "POPULAR REGION", comment: "Section header for quick join region"))

            Button {
                locationChannelsModel.teleport(to: suggestion.geohash)
                let level = GeohashCoverage.level(forLength: suggestion.geohash.count)
                activeLocationChannel = GeohashChannel(level: level, geohash: suggestion.geohash)
            } label: {
                ThemedCard {
                    HStack(spacing: 12) {
                        Text(suggestion.flag)
                            .font(.system(size: 22))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.localizedName)
                                .bitchatFont(size: 15, weight: .semibold)
                                .foregroundColor(palette.primary)
                            Text(verbatim: "#\(suggestion.geohash)")
                                .bitchatFont(size: 12)
                                .foregroundColor(palette.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(palette.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func bookmarksSection(_ bookmarks: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemedSectionLabel(text: String(localized: "places.section.saved", defaultValue: "SAVED PLACES", comment: "Section header for bookmarked places"))

            ThemedCard(padding: 0, spacing: 0) {
                ForEach(Array(bookmarks.enumerated()), id: \.element) { index, gh in
                    let level = GeohashCoverage.level(forLength: gh.count)
                    let channel = GeohashChannel(level: level, geohash: gh)
                    let resolvedName = locationChannelsModel.bookmarkNames[gh]
                    let title = (resolvedName?.isEmpty == false ? resolvedName! : "#\(gh)")
                    let coverage = GeohashCoverage.string(forPrecision: gh.count)
                    let count = peerListModel.participantCount(for: gh)
                    placeRow(
                        title: title,
                        subtitle: "\(level.displayName) · \(coverage) · #\(gh)",
                        count: count,
                        isHighPrecision: gh.count >= 6,
                        geohash: gh
                    ) {
                        let inRegional = locationChannelsModel.availableChannels.contains { $0.geohash == gh }
                        locationChannelsModel.markTeleported(for: gh, !inRegional && !locationChannelsModel.availableChannels.isEmpty)
                        locationChannelsModel.select(.location(channel))
                        activeLocationChannel = channel
                    }
                    .onAppear { locationChannelsModel.resolveBookmarkNameIfNeeded(for: gh) }

                    if index < bookmarks.count - 1 {
                        Rectangle()
                            .fill(palette.divider)
                            .frame(height: 1)
                            .padding(.leading, 14)
                    }
                }
            }
        }
    }

    private var teleportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemedSectionLabel(text: String(localized: "places.section.explore", defaultValue: "EXPLORE ANYWHERE", comment: "Section header for globe and geohash teleport"))

            ThemedCard(spacing: 12) {
                Button {
                    showGlobePicker = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "globe.americas.fill")
                            .font(.system(size: 18))
                            .foregroundColor(palette.locationAccent)
                        Text(String(localized: "places.action.pick_on_globe", defaultValue: "Pick a Place on the Globe", comment: "Button to open the 3D globe picker"))
                            .bitchatFont(size: 15, weight: .medium)
                            .foregroundColor(palette.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(palette.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Rectangle()
                    .fill(palette.divider)
                    .frame(height: 1)

                HStack(spacing: 8) {
                    Text(verbatim: "#")
                        .bitchatFont(size: 14)
                        .foregroundColor(palette.secondary)
                    TextField("geohash", text: $customGeohash)
                        .textFieldStyle(.plain)
                        .bitchatFont(size: 14)
                        .foregroundColor(palette.primary)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.asciiCapable)
                        #endif
                        .onChange(of: customGeohash) { newValue in
                            let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
                            let filtered = newValue
                                .lowercased()
                                .replacingOccurrences(of: "#", with: "")
                                .filter { allowed.contains($0) }
                            if filtered.count > 12 {
                                customGeohash = String(filtered.prefix(12))
                            } else if filtered != newValue {
                                customGeohash = filtered
                            }
                        }

                    let normalized = customGeohash.trimmed.lowercased()
                    Button {
                        if normalized.isEmpty {
                            showGlobePicker = true
                            return
                        }
                        guard Geohash.isValidGeohash(normalized) else {
                            customError = String(localized: "location_channels.error.invalid_geohash", comment: "Error shown when a custom geohash is invalid")
                            return
                        }
                        customError = nil
                        locationChannelsModel.teleport(to: normalized)
                        let level = GeohashCoverage.level(forLength: normalized.count)
                        activeLocationChannel = GeohashChannel(level: level, geohash: normalized)
                    } label: {
                        Text(String(localized: "places.action.join", defaultValue: "Join", comment: "Join custom geohash button"))
                            .bitchatFont(size: 13, weight: .semibold)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(palette.accent)
                            .foregroundColor(palette.accentForeground)
                            .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if let customError {
                    Text(customError)
                        .bitchatFont(size: 12)
                        .foregroundColor(palette.alertRed)
                }
            }
        }
    }

    private func placeRow(
        title: String,
        subtitle: String,
        count: Int,
        isHighPrecision: Bool,
        geohash: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .bitchatFont(size: 15, weight: count > 0 ? .semibold : .medium)
                        .foregroundColor(palette.primary)
                        .lineLimit(1)

                    if count > 0 {
                        Text(verbatim: "\(count)")
                            .bitchatFont(size: 11, weight: .semibold)
                            .foregroundColor(palette.locationAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(palette.locationAccent.opacity(0.14))
                            .clipShape(Capsule())
                    } else if isHighPrecision {
                        Text(verbatim: "?")
                            .bitchatFont(size: 11)
                            .foregroundColor(palette.secondary)
                    }
                }
                Text(subtitle)
                    .bitchatFont(size: 12)
                    .foregroundColor(palette.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                locationChannelsModel.toggleBookmark(geohash)
            } label: {
                Image(systemName: locationChannelsModel.isBookmarked(geohash) ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 14))
                    .foregroundColor(locationChannelsModel.isBookmarked(geohash) ? palette.locationAccent : palette.secondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .contextMenu {
            Button {
                requestShare(forGeohash: geohash)
            } label: {
                Label(
                    String(localized: "channel.share.action", defaultValue: "share channel", comment: "Share location channel"),
                    systemImage: "square.and.arrow.up"
                )
            }
        }
    }

    private var globePicker: some View {
        let initial: String = {
            if let active = activeLocationChannel {
                return active.geohash
            }
            return customGeohash.trimmed.lowercased()
        }()
        return GeohashPickerView(
            initialGeohash: initial,
            nearbyGeohashes: locationChannelsModel.availableChannels.map(\.geohash),
            onSelect: { geohash in
                pickedGeohash = geohash
                showGlobePicker = false
            },
            onCancel: { showGlobePicker = false }
        )
    }

    private func applyPickedGeohash() {
        guard let geohash = pickedGeohash else { return }
        pickedGeohash = nil
        guard Geohash.isValidGeohash(geohash) else { return }
        locationChannelsModel.teleport(to: geohash)
        let level = GeohashCoverage.level(forLength: geohash.count)
        activeLocationChannel = GeohashChannel(level: level, geohash: geohash)
    }

    private func requestShare(forGeohash geohash: String) {
        if ChannelShare.shouldWarn(forGeohash: geohash) {
            pendingShareGeohash = geohash
            showSharePrecisionWarning = true
        } else {
            activeSharePayload = ChannelSharePayload(text: ChannelShare.payload(forGeohash: geohash))
        }
    }
}
