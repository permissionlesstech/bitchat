//
// NoticesView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// The unified notices sheet behind the header's pin icon: one place for
/// everything pinned around you, with a scope toggle.
///
/// - geo: the current geohash's notices — mesh-synced board posts merged and
///   deduped with Nostr kind-1 location notes, so you also see notices from
///   people who aren't on your mesh.
/// - mesh: the mesh-local board only (empty geohash, fully offline).
struct NoticesView: View {
    enum Tab: Hashable {
        case geo
        case mesh
    }

    let senderNickname: String
    @ObservedObject var board: BoardManager

    @ThemedPalette private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @State private var tab: Tab
    @State private var draft: String = ""
    @State private var urgent = false
    @State private var expiryDays = 7

    /// Injected notes manager for tests; live use derives one per geohash.
    private let notesManager: LocationNotesManager?

    init(
        senderNickname: String,
        board: BoardManager,
        initialTab: Tab,
        notesManager: LocationNotesManager? = nil
    ) {
        self.senderNickname = senderNickname
        self.board = board
        self.notesManager = notesManager
        _tab = State(initialValue: initialTab)
    }

    private var maxDraftLines: Int { dynamicTypeSize.isAccessibilitySize ? 5 : 3 }

    /// The geohash the geo tab is scoped to: the selected location channel,
    /// or the device's building geohash when chatting on mesh.
    private var geoGeohash: String? {
        if case .location(let channel) = locationChannelsModel.selectedChannel {
            return channel.geohash
        }
        return locationChannelsModel.currentBuildingGeohash
    }

    /// The geo scope comes from device location only when no location channel
    /// is selected; that's the case that needs the location machinery.
    private var geoTabNeedsDeviceLocation: Bool {
        if case .location = locationChannelsModel.selectedChannel { return false }
        return true
    }

    private var activeGeohash: String? {
        switch tab {
        case .geo: return geoGeohash
        case .mesh: return ""
        }
    }

    enum Strings {
        static let title = String(localized: "notices.title", defaultValue: "notices", comment: "Title prefix of the unified notices sheet")
        static let geoTab = String(localized: "notices.tab.geo", defaultValue: "geo", comment: "Segmented control label for geohash-scoped notices")
        static let meshTab = String(localized: "notices.tab.mesh", defaultValue: "mesh", comment: "Segmented control label for mesh-local notices")
        static let scopePicker = String(localized: "notices.accessibility.scope", defaultValue: "Notices scope", comment: "Accessibility label for the geo/mesh scope toggle")
        static let geoDescription = String(localized: "notices.description.geo", defaultValue: "notices for this area: signed posts carried by the mesh, merged with notes seen on nostr relays.", comment: "Explainer for the geo tab of the notices sheet")
        static let meshDescription = String(localized: "board.description", defaultValue: "persistent notices carried by the mesh. posts are signed, spread device-to-device, and expire on their own.", comment: "Explainer under the board sheet title")
        static let emptyTitle = String(localized: "board.empty_title", defaultValue: "no notices yet", comment: "Title shown when the board has no posts")
        static let emptySubtitle = String(localized: "board.empty_subtitle", defaultValue: "pin the first notice for people around here.", comment: "Subtitle shown when the board has no posts")
        static let urgentBadge = String(localized: "board.urgent_badge", defaultValue: "urgent", comment: "Badge shown on urgent board posts")
        static let urgentToggle = String(localized: "board.compose.urgent", defaultValue: "urgent", comment: "Label for the urgent toggle in the board composer")
        static let placeholder = String(localized: "board.compose.placeholder", defaultValue: "post a notice…", comment: "Placeholder for the board composer text field")
        static let send = String(localized: "board.accessibility.post", defaultValue: "Post notice", comment: "Accessibility label for the board post button")
        static let deleteAction = String(localized: "board.action.delete", defaultValue: "delete", comment: "Delete action for own board posts")
        static let expiryLabel = String(localized: "board.compose.expiry", defaultValue: "expires in", comment: "Label for the board post expiry picker")
        static let closeHint = String(localized: "notices.accessibility.close", defaultValue: "Close notices", comment: "Accessibility label for the notices close button")
        static let meshSource = String(localized: "notices.source.mesh", defaultValue: "mesh", comment: "Source badge for notices carried by the mesh")
        static let nostrSource = String(localized: "notices.source.nostr", defaultValue: "net", comment: "Source badge for notices seen on internet relays")
        static let locationUnavailable = String(localized: "content.notes.location_unavailable", comment: "Shown when the device location is unavailable for geo notices")
        static let enableLocation = String(localized: "content.location.enable", comment: "Button enabling location for geo notices")
        static let loadingNotes: LocalizedStringKey = "location_notes.loading_notes"
        static let noRelaysNearby: LocalizedStringKey = "location_notes.no_relays_nearby"
        static let relaysRetryHint: LocalizedStringKey = "location_notes.relays_retry_hint"
        static let retry: LocalizedStringKey = "location_notes.action.retry"
        static let dismissError: LocalizedStringKey = "location_notes.action.dismiss"

        static func expiryDaysOption(_ days: Int) -> String {
            String(
                format: String(localized: "board.compose.expiry_days", defaultValue: "%lldd", comment: "Expiry picker option, number of days abbreviated"),
                locale: .current,
                days
            )
        }

        static func rowAccessibilityLabel(author: String, content: String, urgent: Bool) -> String {
            let base = String(
                format: String(localized: "board.accessibility.post_row", defaultValue: "Notice from %@: %@", comment: "Accessibility label for a board post row"),
                locale: .current,
                author, content
            )
            return urgent ? "\(urgentBadge), \(base)" : base
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            contentSection
            if activeGeohash != nil {
                composer
            }
        }
        .themedSurface()
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 440, minHeight: 620, idealHeight: 680)
        #endif
        .themedSheetBackground()
        .onAppear { beginGeoLocationIfNeeded() }
        .onChange(of: tab) { newTab in
            if newTab == .geo {
                beginGeoLocationIfNeeded()
            } else {
                locationChannelsModel.endLiveRefresh()
            }
        }
        // Catches permission granted from the geo tab's enable button.
        .onChange(of: locationChannelsModel.permissionState) { _ in
            beginGeoLocationIfNeeded()
        }
        .onDisappear { locationChannelsModel.endLiveRefresh() }
    }

    /// The geo tab tracks the device's building geohash while on mesh; keep
    /// location fresh only in that case (a selected location channel already
    /// fixes the scope).
    private func beginGeoLocationIfNeeded() {
        guard tab == .geo, geoTabNeedsDeviceLocation,
              locationChannelsModel.permissionState == .authorized else { return }
        locationChannelsModel.enableLocationChannels()
        locationChannelsModel.beginLiveRefresh()
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(verbatim: scopeTitle)
                    .bitchatFont(size: 18)
                Spacer()
                SheetCloseButton { dismiss() }
                    .accessibilityLabel(Strings.closeHint)
            }
            Picker(Strings.scopePicker, selection: $tab) {
                Text(Strings.geoTab).tag(Tab.geo)
                Text(Strings.meshTab).tag(Tab.mesh)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(Strings.scopePicker)
            Text(tab == .geo ? Strings.geoDescription : Strings.meshDescription)
                .bitchatFont(size: 12)
                .foregroundColor(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .themedSurface()
    }

    private var scopeTitle: String {
        switch tab {
        case .mesh:
            return "\(Strings.title) @ #mesh"
        case .geo:
            if let geohash = geoGeohash {
                return "\(Strings.title) @ #\(geohash)"
            }
            return Strings.title
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        switch tab {
        case .mesh:
            NoticesList(
                items: UnifiedNotices.merge(posts: board.posts(forGeohash: ""), notes: []),
                showsSource: false,
                board: board,
                notesManager: nil
            )
        case .geo:
            if let geohash = geoGeohash {
                GeoNoticesList(geohash: geohash, board: board, manager: notesManager)
            } else {
                locationUnavailableSection
            }
        }
    }

    private var locationUnavailableSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(Strings.locationUnavailable)
                    .bitchatFont(size: 14)
                    .foregroundColor(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(Strings.enableLocation) {
                    locationChannelsModel.enableAndRefresh()
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedSurface()
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                TextField(Strings.placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .bitchatFont(size: 14)
                    .lineLimit(maxDraftLines, reservesSpace: true)
                    .padding(.vertical, 6)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.bitchatSystem(size: 20))
                        .foregroundColor(sendEnabled ? palette.accent : .secondary)
                }
                .padding(.top, 2)
                .buttonStyle(.plain)
                .disabled(!sendEnabled)
                .accessibilityLabel(Strings.send)
            }
            HStack(spacing: 12) {
                Toggle(isOn: $urgent) {
                    Text(Strings.urgentToggle)
                        .bitchatFont(size: 12)
                        .foregroundColor(urgent ? palette.alertRed : palette.secondary)
                }
                .toggleStyle(.switch)
                .fixedSize()
                .accessibilityLabel(Strings.urgentToggle)
                Spacer()
                Text(Strings.expiryLabel)
                    .bitchatFont(size: 12)
                    .foregroundColor(palette.secondary)
                Picker(Strings.expiryLabel, selection: $expiryDays) {
                    ForEach([1, 3, 7], id: \.self) { days in
                        Text(Strings.expiryDaysOption(days)).tag(days)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityLabel(Strings.expiryLabel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .themedSurface()
        .overlay(Divider(), alignment: .top)
    }

    private var sendEnabled: Bool {
        let trimmed = draft.trimmed
        return !trimmed.isEmpty && trimmed.utf8.count <= BoardWireConstants.contentMaxBytes
    }

    private func send() {
        guard let geohash = activeGeohash, let content = draft.trimmedOrNilIfEmpty else { return }
        // Geo posts go to the board and are bridged to Nostr by BoardManager,
        // so mesh and internet see the same notice.
        let sent = board.createPost(
            content: content,
            geohash: geohash,
            urgent: urgent,
            expiryDays: expiryDays,
            nickname: senderNickname
        )
        if sent {
            draft = ""
            urgent = false
        }
    }
}

/// The geo tab's list: owns the Nostr notes subscription for the scope
/// geohash and merges it with the board posts for the same geohash.
private struct GeoNoticesList: View {
    let geohash: String
    @ObservedObject var board: BoardManager
    @StateObject private var notesManager: LocationNotesManager

    init(geohash: String, board: BoardManager, manager: LocationNotesManager? = nil) {
        let gh = geohash.lowercased()
        self.geohash = gh
        self.board = board
        _notesManager = StateObject(wrappedValue: manager ?? LocationNotesManager(geohash: gh))
    }

    var body: some View {
        NoticesList(
            items: UnifiedNotices.merge(
                posts: board.posts(forGeohash: geohash),
                notes: notesManager.notes
            ),
            showsSource: true,
            board: board,
            notesManager: notesManager
        )
        .onChange(of: geohash) { newValue in
            notesManager.setGeohash(newValue)
        }
        .onDisappear { notesManager.cancel() }
    }
}

/// Renders merged notices with per-source affordances: swipe-delete for own
/// items and a mesh/net badge when sources mix.
private struct NoticesList: View {
    let items: [NoticeItem]
    let showsSource: Bool
    let board: BoardManager
    let notesManager: LocationNotesManager?

    @ThemedPalette private var palette

    private typealias Strings = NoticesView.Strings

    var body: some View {
        Group {
            if items.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        statusRows
                        if showEmptyState {
                            Text(Strings.emptyTitle)
                                .bitchatFont(size: 13, weight: .semibold)
                            Text(Strings.emptySubtitle)
                                .bitchatFont(size: 12)
                                .foregroundColor(palette.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            } else {
                List {
                    statusRows
                        .listRowBackground(palette.background)
                        .listRowSeparatorTint(palette.divider)
                    ForEach(items) { item in
                        row(item)
                            .listRowBackground(palette.background)
                            .listRowSeparatorTint(palette.divider)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedSurface()
    }

    /// Notes may still be loading or unreachable; only claim "no notices yet"
    /// once the sources settled.
    private var showEmptyState: Bool {
        guard let notesManager else { return true }
        return notesManager.initialLoadComplete && notesManager.state != .loading
    }

    @ViewBuilder
    private var statusRows: some View {
        if let notesManager {
            if notesManager.state == .loading && !notesManager.initialLoadComplete {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(Strings.loadingNotes)
                        .bitchatFont(size: 12)
                        .foregroundColor(palette.secondary)
                    Spacer()
                }
                .padding(.vertical, 8)
            } else if notesManager.state == .noRelays {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Strings.noRelaysNearby)
                        .bitchatFont(size: 13, weight: .semibold)
                    Text(Strings.relaysRetryHint)
                        .bitchatFont(size: 12)
                        .foregroundColor(palette.secondary)
                    Button(Strings.retry) { notesManager.refresh() }
                        .bitchatFont(size: 12)
                        .buttonStyle(.plain)
                }
                .padding(.bottom, 8)
            } else if let error = notesManager.errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .bitchatFont(size: 12)
                        Text(error)
                            .bitchatFont(size: 12)
                        Spacer()
                    }
                    Button(Strings.dismissError) { notesManager.clearError() }
                        .bitchatFont(size: 12)
                        .buttonStyle(.plain)
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func canDelete(_ item: NoticeItem) -> Bool {
        switch item.source {
        case .board(let post):
            return board.isOwnPost(post)
        case .nostr(let note):
            return notesManager?.isOwnNote(note) ?? false
        }
    }

    private func delete(_ item: NoticeItem) {
        switch item.source {
        case .board(let post):
            // Tombstones the board post and retracts the bridged Nostr copy.
            board.deletePost(post)
        case .nostr(let note):
            notesManager?.delete(note: note)
        }
    }

    private func row(_ item: NoticeItem) -> some View {
        let isOwn = canDelete(item)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if item.isUrgent {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.bitchatSystem(size: 11))
                        .foregroundColor(palette.alertRed)
                    Text(Strings.urgentBadge)
                        .bitchatFont(size: 11, weight: .semibold)
                        .foregroundColor(palette.alertRed)
                }
                Text(verbatim: "@\(item.author)")
                    .bitchatFont(size: 12, weight: .semibold)
                Text(Self.timestampText(for: item.createdAt))
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.secondary)
                Spacer()
                if showsSource {
                    sourceBadge(item)
                }
                if isOwn {
                    Button {
                        delete(item)
                    } label: {
                        Image(systemName: "trash")
                            .font(.bitchatSystem(size: 12))
                            .foregroundColor(palette.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Strings.deleteAction)
                }
            }
            Text(item.content)
                .bitchatFont(size: 14)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.rowAccessibilityLabel(author: item.author, content: item.content, urgent: item.isUrgent))
        .accessibilityActions {
            if isOwn {
                Button(Strings.deleteAction) { delete(item) }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isOwn {
                Button(role: .destructive) {
                    delete(item)
                } label: {
                    Label(Strings.deleteAction, systemImage: "trash")
                }
            }
        }
    }

    private func sourceBadge(_ item: NoticeItem) -> some View {
        HStack(spacing: 3) {
            Image(systemName: item.isBoardPost ? "antenna.radiowaves.left.and.right" : "globe")
                .font(.bitchatSystem(size: 10))
            Text(item.isBoardPost ? Strings.meshSource : Strings.nostrSource)
                .bitchatFont(size: 10)
        }
        .foregroundColor(palette.secondary.opacity(0.8))
        .accessibilityLabel(item.isBoardPost ? Strings.meshSource : Strings.nostrSource)
    }

    // MARK: - Timestamp Formatting

    private static func timestampText(for date: Date) -> String {
        let now = Date()
        if let days = Calendar.current.dateComponents([.day], from: date, to: now).day, days < 7 {
            let rel = relativeFormatter.string(from: date, to: now) ?? ""
            return rel.isEmpty ? "" : "\(rel) ago"
        }
        let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        return (sameYear ? absDateFormatter : absDateYearFormatter).string(from: date)
    }

    private static let relativeFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.maximumUnitCount = 1
        f.unitsStyle = .abbreviated
        f.collapsesLargestUnit = true
        return f
    }()

    private static let absDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f
    }()

    private static let absDateYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d, y")
        return f
    }()
}
