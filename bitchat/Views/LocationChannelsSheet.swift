import SwiftUI
import CoreLocation
#if os(iOS)
import UIKit
#else
import AppKit
#endif
/// The location channels sheet: the picker below in a navigation view, with
/// the sheet backdrop. Choosing a channel or closing dismisses it.
struct LocationChannelsSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationView {
            LocationChannelsPicker(
                presentation: .sheet,
                onChoose: { _ in isPresented = false },
                onClose: { isPresented = false }
            )
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            #else
            .navigationTitle("")
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
        .themedSheetBackground()
    }
}

/// The location channels: #mesh, the nearby cells, teleport, quick join and
/// bookmarks, with the permission prompt. In the sheet, or inline as the
/// split layout's trailing pane.
struct LocationChannelsPicker: View {
    enum Presentation: Equatable {
        /// The location channels sheet (LocationChannelsSheet).
        case sheet
        #if os(iOS)
        /// The split layout's trailing pane: a title row as tall as the bar
        /// beside it, and clear of the display corner it reaches into.
        /// `panicEpoch` is `AppChromeModel.panicEpoch`. A panic wipe closes
        /// the sheet, and what it held goes with it; the pane stays up, so a
        /// new epoch drops what the pane holds and asks for a fresh fix, as
        /// the pane does when it appears.
        case pane(headerHeight: CGFloat, trailingCornerReach: CGFloat, panicEpoch: UInt64)
        #endif
    }

    let presentation: Presentation
    /// A channel was chosen, reported at the tap with whether the choice
    /// selects anything (`selects(ofGeohash:presentation:selected:)`): false
    /// for the pane's selected geohash chosen again, which only ends
    /// browsing (E7). The sheet dismisses either way.
    let onChoose: (_ selects: Bool) -> Void
    /// The close control's action; nil hides it (the idle pane).
    let onClose: (() -> Void)?

    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var peerListModel: PeerListModel
    #if os(iOS)
    @Environment(\.appTheme) private var theme
    #endif
    @ThemedPalette private var palette
    /// What the picker holds of its own. A panic wipe drops all of it.
    @State private var local = LocalState()
    #if os(iOS)
    /// When the pane last asked for a fix: once `nearbyFixPatience` has
    /// passed without one, it stops promising one.
    @State private var fixRequestedAt: Date?
    #endif

    private struct LocalState {
        var customGeohash = ""
        var customError: String?
        /// Geohash waiting on the fine-precision OpSec confirmation before
        /// share.
        var pendingShareGeohash: String?
        var showSharePrecisionWarning = false
        var activeSharePayload: ChannelSharePayload?
    }

    private enum Strings {
        static let title: LocalizedStringKey = "location_channels.title"
        static let description: LocalizedStringKey = "location_channels.description"
        static let requestPermissions: LocalizedStringKey = "location_channels.action.request_permissions"
        static let permissionDenied: LocalizedStringKey = "location_channels.permission_denied"
        static let openSettings: LocalizedStringKey = "location_channels.action.open_settings"
        static let loadingNearby: LocalizedStringKey = "location_channels.loading_nearby"
        static let grantToFind: LocalizedStringKey = "location_channels.grant_to_find"
        static let teleport: LocalizedStringKey = "location_channels.action.teleport"
        static let bookmarked: LocalizedStringKey = "location_channels.bookmarked_section_title"
        #if os(iOS)
        // The notices sheet's words for the same situation: no fix came.
        static let locationUnavailable: LocalizedStringKey = "content.notes.location_unavailable"
        static let retry: LocalizedStringKey = "location_notes.action.retry"
        #endif
        // Same string the settings pane shows under the tor toggle — the
        // warning belongs wherever the exposure is about to happen.
        static let torOffWarning = String(localized: "app_info.settings.tor.off_warning", defaultValue: "tor is off: every relay you connect to can see your IP address, including relays carrying your private messages.", comment: "Warning shown under the tor toggle while tor is switched off, stating that relay operators can see the device IP address")

        static let quickJoinTitle = String(localized: "location_channels.quick_join.title", defaultValue: "quick join", comment: "Section header in the location channels sheet for the one-tap suggestion of the region channel derived from the device region")
        static func quickJoinDescription(_ regionName: String) -> String {
            String(
                format: String(localized: "location_channels.quick_join.description", defaultValue: "the region channel where people from %@ tend to gather — the wide cell around the main population center, not your location. it's public and well-known, so assume it's watched: quick join saves typing a geohash; it doesn't hide you or bypass blocks.", comment: "Caption under the quick join row; %@ is the localized country/region name. States plainly that the cell is the main population center's (not the person's location), that the channel must be assumed watched, and that quick join is discovery, not circumvention"),
                locale: .current,
                regionName
            )
        }
        static func quickJoinLabel(_ regionName: String) -> String {
            String(
                format: String(localized: "location_channels.quick_join.join_label", defaultValue: "join the %@ region channel", comment: "Accessibility label for the quick join row; %@ is the localized country/region name"),
                locale: .current,
                regionName
            )
        }

        static let invalidGeohash = String(localized: "location_channels.error.invalid_geohash", comment: "Error shown when a custom geohash is invalid")
        static let switchChannelHint = String(localized: "location_channels.accessibility.switch_hint", comment: "Accessibility hint on a channel row explaining activation switches to it")
        static let addBookmark = String(localized: "location_channels.accessibility.add_bookmark", comment: "Accessibility action name for bookmarking a channel")
        static let removeBookmark = String(localized: "location_channels.accessibility.remove_bookmark", comment: "Accessibility action name for removing a channel bookmark")
        static let shareChannel = String(localized: "channel.share.action", defaultValue: "share channel", comment: "Context-menu / accessibility action that shares a location-channel invite")
        static let sharePrecisionTitle = String(localized: "channel.share.precision_warning.title", defaultValue: "share a precise location channel?", comment: "Title of the confirmation before sharing a neighborhood-or-finer geohash invite")
        static let sharePrecisionMessage = String(localized: "channel.share.precision_warning.message", defaultValue: "this channel covers a small area. an invite sent over sms or imessage is visible to the carrier and both handsets — it discloses interest in that place, not only that someone uses bitchat.", comment: "Body of the confirmation before sharing a fine-precision geohash invite")
        static let shareAnyway = String(localized: "channel.share.precision_warning.confirm", defaultValue: "share anyway", comment: "Confirms sharing a fine-precision location channel after the OpSec warning")

        static func meshTitle(_ count: Int) -> String {
            let label = String(localized: "location_channels.mesh_label", comment: "Label for the mesh channel row")
            return rowTitle(label: label, count: count)
        }

        static func levelTitle(for level: GeohashChannelLevel, count: Int) -> String {
            // High-precision uncertainty: if count is 0 for high-precision levels,
            // show "?" because presence broadcasting is disabled for privacy.
            let isHighPrecision = (level == .neighborhood || level == .block || level == .building)
            if isHighPrecision && count == 0 {
                return String(
                    format: String(localized: "location_channels.row_title_unknown", defaultValue: "%@ [? people]"),
                    locale: .current,
                    level.displayName
                )
            }
            return rowTitle(label: level.displayName, count: count)
        }

        static func bookmarkTitle(geohash: String, count: Int) -> String {
            // Check precision for bookmarks too
            let len = geohash.count
            // Neighborhood=6, Block=7, Building=8+
            let isHighPrecision = (len >= 6)
            if isHighPrecision && count == 0 {
                return String(
                    format: String(localized: "location_channels.row_title_unknown", defaultValue: "%@ [? people]"),
                    locale: .current,
                    "#\(geohash)"
                )
            }
            return rowTitle(label: "#\(geohash)", count: count)
        }

        static func subtitlePrefix(geohash: String, coverage: String) -> String {
            String(
                format: String(localized: "location_channels.subtitle_prefix", comment: "Subtitle prefix showing geohash and coverage"),
                locale: .current,
                geohash, coverage
            )
        }

        static func subtitle(prefix: String, name: String?) -> String {
            guard let name, !name.isEmpty else { return prefix }
            return String(
                format: String(localized: "location_channels.subtitle_with_name", comment: "Subtitle combining prefix and resolved location name"),
                locale: .current,
                prefix, name
            )
        }

        private static func rowTitle(label: String, count: Int) -> String {
            String(
                format: String(localized: "location_channels.row_title", comment: "List row title with participant count"),
                locale: .current,
                label, count
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow
            Text(Strings.description)
                .bitchatFont(size: 12)
                .foregroundColor(palette.secondary)

            // The description's tor claim is only true while tor is on;
            // when it's off, say what that exposes right where the person
            // is about to join a channel, not just in settings.
            if !locationChannelsModel.userTorEnabled {
                Text(verbatim: Strings.torOffWarning)
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.alertRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Group {
                switch locationChannelsModel.permissionState {
                case .notDetermined:
                    // The only way the picker asks for location permission:
                    // never on its own, in any presentation.
                    Button(action: { locationChannelsModel.enableLocationChannels() }) {
                        Text(Strings.requestPermissions)
                            .bitchatFont(size: 12)
                            .foregroundColor(standardGreen)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(standardGreen.opacity(0.12))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                case .denied, .restricted:
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Strings.permissionDenied)
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.secondary)
                        Button(Strings.openSettings, action: SystemSettings.location.open)
                        .buttonStyle(.plain)
                    }
                case .authorized:
                    EmptyView()
                }
            }

            channelList
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .themedSurface()
        .onAppear {
            perform(.appear, permission: locationChannelsModel.permissionState)
        }
        .onDisappear {
            perform(.disappear, permission: locationChannelsModel.permissionState)
        }
        .onChange(of: locationChannelsModel.permissionState) { newValue in
            perform(.permissionChange, permission: newValue)
        }
        .onChange(of: locationChannelsModel.availableChannels) { _ in }
        #if os(iOS)
        .onChange(of: panicEpoch) { _ in
            wipe()
        }
        .onReceive(locationChannelsModel.liveRefreshEnded) { _ in
            perform(.liveRefreshEnded, permission: locationChannelsModel.permissionState)
        }
        #endif
        .confirmationDialog(
            Strings.sharePrecisionTitle,
            isPresented: $local.showSharePrecisionWarning,
            titleVisibility: .visible
        ) {
            Button(Strings.shareAnyway) {
                if let gh = local.pendingShareGeohash {
                    presentShare(forGeohash: gh)
                }
                local.pendingShareGeohash = nil
            }
            Button("common.cancel", role: .cancel) {
                local.pendingShareGeohash = nil
            }
        } message: {
            Text(Strings.sharePrecisionMessage)
        }
        .sheet(item: $local.activeSharePayload) { payload in
            ShareActivityView(text: payload.text)
        }
    }

    /// The title and, where there is somewhere to return to, the close
    /// control. In the pane it is exactly as tall as the bar beside it, and
    /// holds its content clear of the display corner.
    @ViewBuilder
    private var titleRow: some View {
        let row = HStack(spacing: 12) {
            Text(Strings.title)
                .bitchatFont(size: 18)
            Spacer()
            if let onClose {
                SheetCloseButton(action: onClose)
            }
        }
        switch presentation {
        case .sheet:
            row
        #if os(iOS)
        case .pane(let headerHeight, let trailingCornerReach, _):
            // A fixed height, not a minimum: no child here may stretch the
            // row (the bar beside it is fixed too).
            row
                .frame(height: headerHeight)
                // The content sits 16pt in (the horizontal padding).
                .padding(.trailing, TopCornerClearance.padding(
                    forReach: trailingCornerReach,
                    contentInset: 16
                ))
        #endif
        }
    }

    private var topPadding: CGFloat {
        switch presentation {
        case .sheet:
            return 12
        #if os(iOS)
        case .pane:
            // Level with the bar beside it, which glass floats as a panel
            // 4pt below the top (themedChromePanel).
            return theme.usesGlassChrome ? 4 : 0
        #endif
        }
    }

    private var bottomPadding: CGFloat {
        switch presentation {
        case .sheet:
            return 12
        #if os(iOS)
        case .pane:
            return 0
        #endif
        }
    }

    private func perform(_ event: LifecycleEvent, permission: LocationChannelManager.PermissionState) {
        #if os(iOS)
        let actions = Self.perform(event, presentation: presentation, permission: permission, on: locationChannelsModel)
        if actions.contains(.refreshChannels) {
            fixRequestedAt = Date()
        }
        #else
        Self.perform(event, presentation: presentation, permission: permission, on: locationChannelsModel)
        #endif
    }

    #if os(iOS)
    /// The pane's `panicEpoch`; nil for the sheet, which the wipe closes.
    private var panicEpoch: UInt64? {
        guard case .pane(_, _, let panicEpoch) = presentation else { return nil }
        return panicEpoch
    }

    /// A panic wipe: nothing typed, shown or on its way here outlives it,
    /// and the nearby cells come from a fix taken after it.
    private func wipe() {
        local = LocalState()
        perform(.panicWipe, permission: locationChannelsModel.permissionState)
    }
    #endif

    /// Selects `channel`, unless it is the pane's selection already
    /// (`selects(ofGeohash:presentation:selected:)`), and reports the choice.
    /// - Parameter prepare: Runs right before a selection (teleport marks).
    private func choose(_ channel: ChannelID, prepare: () -> Void = {}) {
        let selects = Self.selects(
            ofGeohash: channel.nostrGeohashTag,
            presentation: presentation,
            selected: locationChannelsModel.selectedChannel
        )
        if selects {
            prepare()
            locationChannelsModel.select(channel)
        }
        onChoose(selects)
    }

    /// Teleports to `geohash` as `choose(_:prepare:)` selects.
    private func chooseTeleport(to geohash: String) {
        let selects = Self.selects(
            ofGeohash: geohash,
            presentation: presentation,
            selected: locationChannelsModel.selectedChannel
        )
        if selects {
            locationChannelsModel.teleport(to: geohash)
        }
        onChoose(selects)
    }

    /// The #mesh row (`showsMeshRow(presentation:canClose:)`).
    private var showsMeshRow: Bool {
        Self.showsMeshRow(presentation: presentation, canClose: onClose != nil)
    }

    private func requestShare(forGeohash geohash: String) {
        if ChannelShare.shouldWarn(forGeohash: geohash) {
            local.pendingShareGeohash = geohash
            local.showSharePrecisionWarning = true
        } else {
            presentShare(forGeohash: geohash)
        }
    }

    private func presentShare(forGeohash geohash: String) {
        local.activeSharePayload = ChannelSharePayload(text: ChannelShare.payload(forGeohash: geohash))
    }

    /// Participant counts mean "active in the last five minutes": they change
    /// as people arrive and as quiet ones age out, neither of which publishes
    /// anything this picker observes, so re-read them every few seconds while
    /// it is on screen.
    private var channelList: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            channelListContent(at: context.date)
        }
    }

    private func channelListContent(at now: Date) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if showsMeshRow {
                    channelRow(title: Strings.meshTitle(peerListModel.reachableMeshPeerCount), subtitlePrefix: Strings.subtitlePrefix(geohash: "bluetooth", coverage: bluetoothRangeString()), isSelected: isMeshSelected, titleColor: standardBlue, titleBold: peerListModel.reachableMeshPeerCount > 0) {
                        choose(ChannelID.mesh)
                    }
                    .padding(.vertical, 6)
                }

                let nearby = locationChannelsModel.availableChannels.filter { $0.level != .building }
                if !nearby.isEmpty {
                    ForEach(nearby) { channel in
                        sectionDivider
                        let coverage = coverageString(forPrecision: channel.geohash.count)
                        let nameBase = locationName(for: channel.level)
                        let namePart = nameBase.map { formattedNamePrefix(for: channel.level) + $0 }
                        let participantCount = peerListModel.participantCount(for: channel.geohash)
                        let subtitlePrefix = Strings.subtitlePrefix(geohash: channel.geohash, coverage: coverage)
                        let highlight = participantCount > 0
                        channelRow(
                            title: Strings.levelTitle(for: channel.level, count: participantCount),
                            subtitlePrefix: subtitlePrefix,
                            subtitleName: namePart,
                            isSelected: isSelected(channel),
                            titleBold: highlight,
                            trailingAccessory: {
                                Button(action: { locationChannelsModel.toggleBookmark(channel.geohash) }) {
                                    Image(systemName: locationChannelsModel.isBookmarked(channel.geohash) ? "bookmark.fill" : "bookmark")
                                        .font(.bitchatSystem(size: 14))
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, 8)
                                .accessibilityLabel(locationChannelsModel.isBookmarked(channel.geohash) ? Strings.removeBookmark : Strings.addBookmark)
                            },
                            accessoryActionTitle: locationChannelsModel.isBookmarked(channel.geohash) ? Strings.removeBookmark : Strings.addBookmark,
                            accessoryAction: { locationChannelsModel.toggleBookmark(channel.geohash) },
                            shareGeohash: channel.geohash,
                            onShare: { requestShare(forGeohash: channel.geohash) }
                        ) {
                            choose(ChannelID.location(channel)) {
                                locationChannelsModel.markTeleported(for: channel.geohash, false)
                            }
                        }
                        .contextMenu {
                            Button {
                                requestShare(forGeohash: channel.geohash)
                            } label: {
                                Label(Strings.shareChannel, systemImage: "square.and.arrow.up")
                            }
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    sectionDivider
                    nearbyPlaceholder(at: now)
                }

                sectionDivider
                customTeleportSection
                    .padding(.vertical, 8)

                if QuickJoinSuggestion.current() != nil {
                    sectionDivider
                    quickJoinSection
                        .padding(.vertical, 8)
                }

                let bookmarkedList = locationChannelsModel.bookmarks
                if !bookmarkedList.isEmpty {
                    sectionDivider
                    bookmarkedSection(bookmarkedList)
                        .padding(.vertical, 8)
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .themedSurface()
        }
        .themedSurface()
    }

    /// What stands in for the nearby cells while none is known.
    /// - Parameter now: The list's timeline tick, so a fix that never comes
    ///   turns into the retry within a tick of the patience running out.
    @ViewBuilder
    private func nearbyPlaceholder(at now: Date) -> some View {
        #if os(iOS)
        switch Self.nearbyPlaceholder(
            presentation: presentation,
            permission: locationChannelsModel.permissionState,
            fixRequestedAt: fixRequestedAt,
            now: now
        ) {
        case .finding:
            findingNearbyRow
        case .grantPermission:
            grantToFindRow
        case .unavailable:
            locationUnavailableRow
        }
        #else
        if locationChannelsModel.permissionState == .authorized {
            findingNearbyRow
        } else {
            grantToFindRow
        }
        #endif
    }

    private var findingNearbyRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(Strings.loadingNearby)
                .bitchatFont(size: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    /// No permission means no fix is coming: an honest hint beats a spinner
    /// that would never finish.
    private var grantToFindRow: some View {
        Text(Strings.grantToFind)
            .bitchatFont(size: 12)
            .foregroundColor(palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }

    #if os(iOS)
    /// The pane's fix never came, and nothing would ask again while the pane
    /// is up: say so, and leave the next ask to a tap (I3).
    private var locationUnavailableRow: some View {
        HStack(spacing: 8) {
            Text(Strings.locationUnavailable)
                .bitchatFont(size: 12)
                .foregroundColor(palette.secondary)
            Spacer()
            Button(Strings.retry) {
                perform(.retry, permission: locationChannelsModel.permissionState)
            }
            .buttonStyle(.plain)
            .bitchatFont(size: 12)
            .foregroundColor(standardGreen)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }
    #endif

    private var sectionDivider: some View {
        Rectangle()
            .fill(dividerColor)
            .frame(height: 1)
    }

    private var dividerColor: Color { palette.divider }

    private var customTeleportSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text(verbatim: "#")
                    .bitchatFont(size: 14)
                    .foregroundColor(palette.secondary)
                TextField("geohash", text: $local.customGeohash)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.asciiCapable)
                    #endif
                    .bitchatFont(size: 14)
                    .onChange(of: local.customGeohash) { newValue in
                        let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
                        let filtered = newValue
                            .lowercased()
                            .replacingOccurrences(of: "#", with: "")
                            .filter { allowed.contains($0) }
                        if filtered.count > 12 {
                            local.customGeohash = String(filtered.prefix(12))
                        } else if filtered != newValue {
                            local.customGeohash = filtered
                        }
                    }
                let normalized = local.customGeohash
                    .trimmed
                    .lowercased()
                    .replacingOccurrences(of: "#", with: "")
                let isValid = validateGeohash(normalized)
                Button(action: {
                    let gh = normalized
                    guard isValid else { local.customError = Strings.invalidGeohash; return }
                    chooseTeleport(to: gh)
                }) {
                    HStack(spacing: 6) {
                        Text(Strings.teleport)
                            .bitchatFont(size: 14)
                        Image(systemName: "face.dashed")
                            .font(.bitchatSystem(size: 14))
                    }
                }
                .buttonStyle(.plain)
                .bitchatFont(size: 14)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(palette.secondary.opacity(0.12))
                .cornerRadius(6)
                .opacity(isValid ? 1.0 : 0.4)
                .disabled(!isValid)
            }
            if let err = local.customError {
                Text(err)
                    .bitchatFont(size: 12)
                    .foregroundColor(.red)
            }
        }
    }

    /// One tap into the region channel around the device region's main
    /// population center — derived from the locale, no location access, no
    /// roster (see QuickJoinSuggestion). The caption is deliberately blunt
    /// that the cell is public and watched: discovery, not circumvention.
    @ViewBuilder
    private var quickJoinSection: some View {
        if let suggestion = QuickJoinSuggestion.current() {
            VStack(alignment: .leading, spacing: 8) {
                Text(Strings.quickJoinTitle)
                    .bitchatFont(size: 12)
                    .foregroundColor(palette.secondary)

                Button(action: {
                    chooseTeleport(to: suggestion.geohash)
                }) {
                    HStack {
                        Text(verbatim: "\(suggestion.flag) \(suggestion.localizedName)")
                            .bitchatFont(size: 14)
                            .foregroundColor(palette.primary)
                        Spacer()
                        Text(verbatim: "#\(suggestion.geohash)")
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.secondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Strings.quickJoinLabel(suggestion.localizedName))
                .accessibilityHint(Strings.switchChannelHint)

                Text(Strings.quickJoinDescription(suggestion.localizedName))
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bookmarkedSection(_ entries: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Strings.bookmarked)
                .bitchatFont(size: 12)
                .foregroundColor(palette.secondary)
            LazyVStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, gh in
                    let level = levelForLength(gh.count)
                    let channel = GeohashChannel(level: level, geohash: gh)
                    let coverage = coverageString(forPrecision: gh.count)
                    let subtitle = Strings.subtitlePrefix(geohash: gh, coverage: coverage)
                    let name = locationChannelsModel.bookmarkNames[gh]
                    let participantCount = peerListModel.participantCount(for: gh)
                    channelRow(
                        title: Strings.bookmarkTitle(geohash: gh, count: participantCount),
                        subtitlePrefix: subtitle,
                        subtitleName: name.map { formattedNamePrefix(for: level) + $0 },
                        isSelected: locationChannelsModel.isSelected(channel),
                        trailingAccessory: {
                            Button(action: { locationChannelsModel.toggleBookmark(gh) }) {
                                Image(systemName: locationChannelsModel.isBookmarked(gh) ? "bookmark.fill" : "bookmark")
                                    .font(.bitchatSystem(size: 14))
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 8)
                            .accessibilityLabel(locationChannelsModel.isBookmarked(gh) ? Strings.removeBookmark : Strings.addBookmark)
                        },
                        accessoryActionTitle: locationChannelsModel.isBookmarked(gh) ? Strings.removeBookmark : Strings.addBookmark,
                        accessoryAction: { locationChannelsModel.toggleBookmark(gh) },
                        shareGeohash: gh,
                        onShare: { requestShare(forGeohash: gh) }
                    ) {
                        choose(ChannelID.location(channel)) {
                            let inRegional = locationChannelsModel.availableChannels.contains { $0.geohash == gh }
                            if !inRegional && !locationChannelsModel.availableChannels.isEmpty {
                                locationChannelsModel.markTeleported(for: gh, true)
                            } else {
                                locationChannelsModel.markTeleported(for: gh, false)
                            }
                        }
                    }
                    .contextMenu {
                        Button {
                            requestShare(forGeohash: gh)
                        } label: {
                            Label(Strings.shareChannel, systemImage: "square.and.arrow.up")
                        }
                    }
                    .padding(.vertical, 6)
                    .onAppear { locationChannelsModel.resolveBookmarkNameIfNeeded(for: gh) }

                    if index < entries.count - 1 {
                        sectionDivider
                    }
                }
            }
        }
    }


    private func isSelected(_ channel: GeohashChannel) -> Bool {
        locationChannelsModel.isSelected(channel)
    }

    private var isMeshSelected: Bool {
        if case .mesh = locationChannelsModel.selectedChannel { return true }
        return false
    }

    @ViewBuilder
    private func channelRow(
        title: String,
        subtitlePrefix: String,
        subtitleName: String? = nil,
        subtitleNameBold _: Bool = false,
        isSelected: Bool,
        titleColor: Color? = nil,
        titleBold: Bool = false,
        @ViewBuilder trailingAccessory: () -> some View = { EmptyView() },
        accessoryActionTitle: String? = nil,
        accessoryAction: (() -> Void)? = nil,
        shareGeohash: String? = nil,
        onShare: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading) {
                // Render title with smaller font for trailing count in parentheses
                let parts = splitTitleAndCount(title)
                HStack(spacing: 4) {
                    Text(parts.base)
                            .bitchatFont(size: 14)
                            .fontWeight(titleBold ? .bold : .regular)
                            .foregroundColor(titleColor ?? palette.primary)
                        if let count = parts.countSuffix, !count.isEmpty {
                            Text(count)
                                .bitchatFont(size: 11)
                                .foregroundColor(palette.secondary)
                        }
                    }
                let subtitleFull = Strings.subtitle(prefix: subtitlePrefix, name: subtitleName)
                Text(subtitleFull)
                    .bitchatFont(size: 12)
                    .foregroundColor(palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
                Spacer()
                if isSelected {
                    Text(verbatim: "✔︎")
                        .bitchatFont(size: 16)
                        .foregroundColor(standardGreen)
                }
                trailingAccessory()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        // The row is a plain HStack with a tap gesture, which VoiceOver reads
        // as disconnected static text. Expose it as one activatable button;
        // the visible bookmark accessory is mirrored as a named action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title), \(Strings.subtitle(prefix: subtitlePrefix, name: subtitleName))"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityHint(Strings.switchChannelHint)
        .accessibilityAction(.default, action)
        .accessibilityActions {
            if let accessoryActionTitle, let accessoryAction {
                Button(accessoryActionTitle, action: accessoryAction)
            }
            if shareGeohash != nil, let onShare {
                Button(Strings.shareChannel, action: onShare)
            }
        }
    }

    // Split a title like "#mesh [3 people]" into base and suffix "[3 people]"
    private func splitTitleAndCount(_ s: String) -> (base: String, countSuffix: String?) {
        guard let idx = s.lastIndex(of: "[") else { return (s, nil) }
        let prefix = String(s[..<idx]).trimmed
        let suffix = String(s[idx...])
        return (prefix, suffix)
    }
    private func validateGeohash(_ s: String) -> Bool {
        let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
        guard !s.isEmpty, s.count <= 12 else { return false }
        return s.allSatisfy { allowed.contains($0) }
    }

    private func levelForLength(_ len: Int) -> GeohashChannelLevel {
        switch len {
        case 0...2: return .region
        case 3...4: return .province
        case 5: return .city
        case 6: return .neighborhood
        case 7: return .block
        case 8: return .building
        default: return .block
        }
    }
}

// MARK: - Lifecycle

extension LocationChannelsPicker {
    enum LifecycleEvent: Equatable {
        case appear
        case disappear
        /// The location permission changed.
        case permissionChange
        #if os(iOS)
        /// A panic wipe: the pane's `panicEpoch` changed.
        case panicWipe
        /// The pane's retry, after a fix that never came.
        case retry
        /// Continuous updates elsewhere ended (the sheet or the notices
        /// closing), cancelling any one-shot fix still on its way.
        case liveRefreshEnded
        #endif
    }

    enum LifecycleAction: Equatable {
        /// One location fix, if authorized (`refreshChannels`).
        case refreshChannels
        /// Continuous high-accuracy updates until `endLiveRefresh`.
        case beginLiveRefresh
        case endLiveRefresh
    }

    /// What the picker asks of location as it comes and goes. None of it
    /// prompts for permission: that stays the tap on the enable button. The
    /// sheet keeps its continuous refresh while it is up. The pane can sit on
    /// screen for hours, so it never starts one: it asks for a single fix as
    /// it appears, when permission arrives, after a panic wipe (whatever it
    /// listed came from a fix taken before the wipe), on its retry, and when
    /// continuous updates elsewhere end, which cancels a fix still on its way
    /// (the location sheet closing as the device unfolds, E8).
    /// - Parameter permission: The permission state as of the event (after
    ///   the change, for `.permissionChange`).
    static func lifecycleActions(
        for event: LifecycleEvent,
        presentation: Presentation,
        permission: LocationChannelManager.PermissionState
    ) -> [LifecycleAction] {
        let refresh: [LifecycleAction] = permission == .authorized ? [.refreshChannels] : []
        switch (event, presentation) {
        case (.appear, .sheet):
            return refresh + [.beginLiveRefresh]
        case (.disappear, .sheet):
            return [.endLiveRefresh]
        #if os(iOS)
        case (.appear, .pane):
            return refresh
        case (.disappear, .pane):
            return []
        case (.panicWipe, .pane):
            return refresh
        case (.panicWipe, .sheet):
            // The wipe closes the sheet; its disappearance ends the updates.
            return []
        case (.retry, _):
            return refresh
        case (.liveRefreshEnded, .pane):
            return refresh
        case (.liveRefreshEnded, .sheet):
            // Its own, as it closes.
            return []
        #endif
        case (.permissionChange, _):
            return refresh
        }
    }

    /// Runs `lifecycleActions(for:presentation:permission:)` on `model`.
    /// - Returns: The actions it ran.
    @MainActor
    @discardableResult
    static func perform(
        _ event: LifecycleEvent,
        presentation: Presentation,
        permission: LocationChannelManager.PermissionState,
        on model: LocationChannelsModel
    ) -> [LifecycleAction] {
        let actions = lifecycleActions(for: event, presentation: presentation, permission: permission)
        for action in actions {
            switch action {
            case .refreshChannels:
                model.refreshChannels()
            case .beginLiveRefresh:
                model.beginLiveRefresh()
            case .endLiveRefresh:
                model.endLiveRefresh()
            }
        }
        return actions
    }

    /// Whether a choice selects (or teleports): the sheet selects whatever
    /// is chosen, as it always has. In the pane, choosing the selected
    /// channel again only ends browsing (E7): selecting it again would
    /// resubscribe for nothing. Any other choice moves the timeline, whose
    /// landing ends browsing, so the geohash being left never comes back
    /// while the choice lands.
    /// - Parameters:
    ///   - geohash: The chosen cell; nil for #mesh.
    ///   - selected: The selection as the choice is made.
    static func selects(
        ofGeohash geohash: String?,
        presentation: Presentation,
        selected: ChannelID
    ) -> Bool {
        switch presentation {
        case .sheet:
            return true
        #if os(iOS)
        case .pane:
            return !isSelected(geohash: geohash, in: selected)
        #endif
        }
    }

    /// Whether the #mesh row shows: always in the sheet. The pane shows it
    /// only while browsing away from a geohash, its close control up: idle,
    /// #mesh is the pane beside it and no location channel is selected to
    /// leave (E7). Read from the close control, not the selection: a
    /// geohash chosen in the idle pane is selected a hop or more before
    /// its channel replaces the pane, and the row would pop in meanwhile.
    /// - Parameter canClose: The picker has a close control.
    static func showsMeshRow(presentation: Presentation, canClose: Bool) -> Bool {
        presentation == .sheet || canClose
    }

    #if os(iOS)
    /// Whether choosing `geohash` (nil: #mesh) picks the channel already
    /// selected. Compared by geohash: the same cell can arrive with
    /// different levels (a bookmark, a teleport, a nearby row).
    static func isSelected(geohash: String?, in selected: ChannelID) -> Bool {
        switch selected {
        case .mesh:
            return geohash == nil
        case .location(let channel):
            return geohash?.lowercased() == channel.geohash.lowercased()
        }
    }

    /// How long the pane waits for its one fix. CoreLocation answers a
    /// one-shot request within seconds, a failure included, but a failure
    /// only reaches the log, and a stop of continuous updates elsewhere (the
    /// sheet, the notices) cancels the request outright.
    static let nearbyFixPatience: TimeInterval = 15

    /// What stands in for the nearby cells while none is known.
    enum NearbyPlaceholder: Equatable {
        /// A fix is on its way: the spinner.
        case finding
        /// No permission, so no fix is coming: the hint to grant it.
        case grantPermission
        /// The pane's fix had its chance and none came: say so, with a retry.
        case unavailable
    }

    /// The sheet's continuous updates keep trying, so it keeps its spinner.
    /// The pane asks once, so its spinner lasts `nearbyFixPatience` from the
    /// ask. Nothing asked yet is a pane that will as it appears or as
    /// permission arrives.
    /// - Parameters:
    ///   - fixRequestedAt: When the pane last asked for a fix.
    ///   - now: The time to judge at.
    static func nearbyPlaceholder(
        presentation: Presentation,
        permission: LocationChannelManager.PermissionState,
        fixRequestedAt: Date?,
        now: Date
    ) -> NearbyPlaceholder {
        guard permission == .authorized else { return .grantPermission }
        switch presentation {
        case .sheet:
            return .finding
        case .pane:
            guard let fixRequestedAt,
                  now.timeIntervalSince(fixRequestedAt) >= nearbyFixPatience else {
                return .finding
            }
            return .unavailable
        }
    }
    #endif
}

// MARK: - Standardized Colors
// (The tor and internet-gateway toggles moved to AppInfoView's Settings pane;
// IRCToggleStyle now lives in Views/Components.)
extension LocationChannelsPicker {
    private var standardGreen: Color { palette.primary }
    private var standardBlue: Color { palette.accentBlue }
}

// MARK: - Coverage helpers
extension LocationChannelsPicker {
    private func coverageString(forPrecision len: Int) -> String {
        // Approximate max cell dimension at equator for a given geohash length.
        // Values sourced from common geohash dimension tables.
        let maxMeters: Double = {
            switch len {
            case 2: return 1_250_000
            case 3: return 156_000
            case 4: return 39_100
            case 5: return 4_890
            case 6: return 1_220
            case 7: return 153
            case 8: return 38.2
            case 9: return 4.77
            case 10: return 1.19
            default:
                if len <= 1 { return 5_000_000 }
                // For >10, scale down conservatively by ~1/4 each char
                let over = len - 10
                return 1.19 * pow(0.25, Double(over))
            }
        }()

        let usesMetric: Bool = {
            if #available(iOS 16.0, macOS 13.0, *) {
                return Locale.current.measurementSystem == .metric
            } else {
                return Locale.current.usesMetricSystem
            }
        }()
        if usesMetric {
            let km = maxMeters / 1000.0
            return "~\(formatDistance(km)) km"
        } else {
            let miles = maxMeters / 1609.344
            return "~\(formatDistance(miles)) mi"
        }
    }

    private func formatDistance(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f", value.rounded()) }
        if value >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.1f", value)
    }

    private func bluetoothRangeString() -> String {
        let usesMetric: Bool = {
            if #available(iOS 16.0, macOS 13.0, *) {
                return Locale.current.measurementSystem == .metric
            } else {
                return Locale.current.usesMetricSystem
            }
        }()
        // Approximate Bluetooth LE range for typical mobile devices; environment dependent
        return usesMetric ? "~10–50 m" : "~30–160 ft"
    }

    private func locationName(for level: GeohashChannelLevel) -> String? {
        locationChannelsModel.locationName(for: level)
    }

    private func formattedNamePrefix(for level: GeohashChannelLevel) -> String {
        switch level {
        case .region:
            return ""
        case .building, .block, .neighborhood, .city, .province:
            return "~"
        }
    }
}
