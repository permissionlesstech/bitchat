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
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @State private var tab: Tab
    @State private var draft: String = ""
    @State private var urgent = false
    /// Days until the notice fades; `permanentExpiry` (geo default) means no
    /// NIP-40 tag — the note stays until its relay drops it.
    @State private var expiryDays: Int
    /// Mirrors the app-info kill switch so its notification produces an
    /// immediate presentation update as well as tearing down subscriptions.
    @State private var locationNotesEnabled = LocationNotesSettings.enabled

    /// Sentinel picker tag for the ∞ option (geo tab only).
    private static let permanentExpiry = 0

    /// Injected notes manager for tests; live use derives one per geohash.
    private let notesManager: LocationNotesManager?
    /// When set, locks the sheet to a single scope (Mesh Notices from Nearby,
    /// or Place Notes from Places) and hides the redundant Geo/Mesh switcher.
    private let lockedScope: Tab?
    /// When true, the geo scope always targets the device's current building
    /// cell instead of any previously selected remote location channel.
    private let prefersDeviceLocation: Bool
    /// Pooled manager held by the sheet so the composer can post pure Nostr
    /// notes (∞ expiry has no mesh-board copy) and the list can render them.
    /// Acquired from `LocationNotesPool` (shared with the nearby-notes
    /// counter, one REQ per geohash) and released on dismissal.
    @State private var liveGeoManager: LocationNotesManager?
    /// Tracks only this sheet's high-accuracy refresh ownership, so repeated
    /// Combine/SwiftUI invalidations do not restart CoreLocation and a
    /// revocation or kill-switch transition balances the begin call once.
    @State private var ownsLiveGeoRefresh = false

    init(
        senderNickname: String,
        board: BoardManager,
        initialTab: Tab,
        notesManager: LocationNotesManager? = nil,
        lockedScope: Tab? = nil,
        prefersDeviceLocation: Bool = false
    ) {
        self.senderNickname = senderNickname
        self.board = board
        self.notesManager = notesManager
        self.lockedScope = lockedScope
        self.prefersDeviceLocation = prefersDeviceLocation
        let resolvedTab = lockedScope ?? initialTab
        _tab = State(initialValue: resolvedTab)
        _expiryDays = State(initialValue: resolvedTab == .geo ? Self.permanentExpiry : 7)
    }

    private var activeNotesManager: LocationNotesManager? {
        notesManager ?? liveGeoManager
    }

    /// The one explicit act inside the sheet that unlocks the passive
    /// nearby-notes counter: the person actively picking the geo segment
    /// while the sheet has a geo scope. Landing on the geo tab via the
    /// sheet's initial selection (auto-derived from the current channel —
    /// e.g. browsing a remote geohash) is not an act toward the LOCAL
    /// building cell and must not reveal it.
    static func revealsNearbyNotes(onSwitchingTo tab: Tab, geoGeohash: String?) -> Bool {
        tab == .geo && geoGeohash != nil
    }

    struct GeoSessionState {
        let manager: LocationNotesManager?
        let ownsLiveRefresh: Bool
    }

    enum GeoPresentationState: Equatable {
        case disabled
        case locationUnavailable
        case available(String)
    }

    static func geoPresentationState(notesEnabled: Bool, geohash: String?) -> GeoPresentationState {
        guard notesEnabled else { return .disabled }
        guard let geohash else { return .locationUnavailable }
        return .available(geohash)
    }

    static func composerGeohash(tab: Tab, notesEnabled: Bool, geoGeohash: String?) -> String? {
        switch tab {
        case .geo:
            guard case .available(let geohash) = geoPresentationState(
                notesEnabled: notesEnabled,
                geohash: geoGeohash
            ) else {
                return nil
            }
            return geohash
        case .mesh:
            return ""
        }
    }

    /// Reconciles both privacy-sensitive resources owned by the sheet: the
    /// high-accuracy CoreLocation refresh and the precise notes REQ. Kept as
    /// a callback-driven function so permission and kill-switch transitions
    /// can be regression tested without presenting SwiftUI.
    @MainActor
    static func reconcileGeoSession(
        tab: Tab,
        needsDeviceLocation: Bool,
        permissionState: LocationChannelManager.PermissionState,
        notesEnabled: Bool,
        geohash: String?,
        manager: LocationNotesManager?,
        ownsLiveRefresh: Bool,
        isAppActive: Bool = true,
        beginLiveRefresh: () -> Void,
        endLiveRefresh: () -> Void,
        acquire: (String) -> LocationNotesManager,
        release: (LocationNotesManager?) -> Void
    ) -> GeoSessionState {
        let geoTabActive = tab == .geo && notesEnabled
        let wantsLiveRefresh = geoTabActive && needsDeviceLocation && permissionState == .authorized && isAppActive

        if wantsLiveRefresh != ownsLiveRefresh {
            if wantsLiveRefresh {
                beginLiveRefresh()
            } else {
                endLiveRefresh()
            }
        }

        // A selected location channel is an explicit remote/teleported scope
        // and remains usable without device permission. Only device-derived
        // scope requires current authorization.
        let mayUseNotes = geoTabActive &&
            (!needsDeviceLocation || permissionState == .authorized)
        guard mayUseNotes, let geohash else {
            if manager != nil {
                release(manager)
            }
            return GeoSessionState(manager: nil, ownsLiveRefresh: wantsLiveRefresh)
        }

        if let manager {
            if manager.geohash != geohash.lowercased() {
                // Pooled managers are shared; never retarget one in place.
                release(manager)
                return GeoSessionState(
                    manager: acquire(geohash),
                    ownsLiveRefresh: wantsLiveRefresh
                )
            }
            if manager.state == .idle {
                manager.refresh()
            }
            return GeoSessionState(manager: manager, ownsLiveRefresh: wantsLiveRefresh)
        }

        return GeoSessionState(
            manager: acquire(geohash),
            ownsLiveRefresh: wantsLiveRefresh
        )
    }

    private func reconcileGeoSession(notesEnabled: Bool? = nil) {
        let notesEnabled = notesEnabled ?? locationNotesEnabled
        let next = Self.reconcileGeoSession(
            tab: tab,
            needsDeviceLocation: geoTabNeedsDeviceLocation,
            permissionState: locationChannelsModel.permissionState,
            notesEnabled: notesEnabled,
            geohash: geoGeohash,
            manager: liveGeoManager,
            ownsLiveRefresh: ownsLiveGeoRefresh,
            isAppActive: scenePhase == .active,
            beginLiveRefresh: {
                locationChannelsModel.enableLocationChannels()
                locationChannelsModel.beginLiveRefresh()
            },
            endLiveRefresh: { locationChannelsModel.endLiveRefresh() },
            acquire: { geohash in
                notesManager ?? LocationNotesPool.shared.acquire(geohash)
            },
            release: { manager in
                guard notesManager == nil else { return }
                LocationNotesPool.shared.release(manager)
            }
        )
        // A test-injected manager is owned by the caller, not by the pool or
        // this view's lifecycle state.
        liveGeoManager = notesManager == nil ? next.manager : nil
        ownsLiveGeoRefresh = next.ownsLiveRefresh
    }

    private var maxDraftLines: Int { dynamicTypeSize.isAccessibilitySize ? 5 : 3 }

    /// The geohash the geo tab is scoped to: the selected location channel,
    /// or the device's building geohash when chatting on mesh.
    private var geoGeohash: String? {
        if !prefersDeviceLocation, case .location(let channel) = locationChannelsModel.selectedChannel {
            return channel.geohash
        }
        guard locationChannelsModel.permissionState == .authorized else {
            return nil
        }
        return locationChannelsModel.currentBuildingGeohash
    }

    /// The geo scope comes from device location only when no location channel
    /// is selected (or when explicitly opened for the user's current spot).
    private var geoTabNeedsDeviceLocation: Bool {
        if prefersDeviceLocation { return true }
        if case .location = locationChannelsModel.selectedChannel { return false }
        return true
    }

    private var activeGeohash: String? {
        Self.composerGeohash(
            tab: tab,
            notesEnabled: locationNotesEnabled,
            geoGeohash: geoGeohash
        )
    }

    enum Strings {
        static let title = String(localized: "notices.title", defaultValue: "notices", comment: "Title prefix of the unified notices sheet")
        static let geoTab = String(localized: "notices.tab.geo", defaultValue: "geo", comment: "Segmented control label for geohash-scoped notices")
        static let meshTab = String(localized: "notices.tab.mesh", defaultValue: "mesh", comment: "Segmented control label for mesh-local notices")
        static let scopePicker = String(localized: "notices.accessibility.scope", defaultValue: "Notices scope", comment: "Accessibility label for the geo/mesh scope toggle")
        // The pre-merge location-notes explainer, reused so its existing
        // translations carry over.
        static let geoDescription = String(localized: "location_notes.description", comment: "Explainer for the geo tab of the notices sheet")
        static let meshDescription = String(localized: "notices.description.mesh", defaultValue: "pin short notices for people around you. they hop phone to phone, even offline, and disappear on their own after a few days.", comment: "Explainer for the mesh tab of the notices sheet")
        static let emptyTitle = String(localized: "board.empty_title", defaultValue: "no notices yet", comment: "Title shown when the board has no posts")
        static let emptySubtitle = String(localized: "board.empty_subtitle", defaultValue: "pin the first notice for people around here.", comment: "Subtitle shown when the board has no posts")
        static let urgentBadge = String(localized: "board.urgent_badge", defaultValue: "urgent", comment: "Badge shown on urgent board posts")
        static let urgentToggle = String(localized: "board.compose.urgent", defaultValue: "urgent", comment: "Label for the urgent toggle in the board composer")
        static let placeholder = String(localized: "board.compose.placeholder", defaultValue: "post a notice…", comment: "Placeholder for the board composer text field")
        static let send = String(localized: "board.accessibility.post", defaultValue: "Post notice", comment: "Accessibility label for the board post button")
        static let deleteAction = String(localized: "board.action.delete", defaultValue: "delete", comment: "Delete action for own board posts")
        static let expiryLabel = String(localized: "board.compose.expiry", defaultValue: "expires in", comment: "Label for the board post expiry picker")
        static let permanentOption = String(localized: "notices.expiry.permanent", defaultValue: "permanent", comment: "Accessibility label for the ∞ (never expires) option in the geo notes expiry picker")
        static let meshSource = String(localized: "notices.source.mesh", defaultValue: "mesh", comment: "Source badge for notices carried by the mesh")
        static let nostrSource = String(localized: "notices.source.nostr", defaultValue: "net", comment: "Source badge for notices seen on internet relays")
        static let locationUnavailable = String(localized: "content.notes.location_unavailable", comment: "Shown when the device location is unavailable for geo notices")
        static let enableLocation = String(localized: "content.location.enable", comment: "Button enabling location for geo notices")
        static let locationNotesTitle = String(localized: "app_info.location.notes.title")
        static let locationNotesDescription = String(localized: "app_info.location.notes.description")
        static let loadingNotes = String(localized: "location_notes.loading_notes")
        static let connectingRelays = String(localized: "location_notes.connecting_relays")
        static let noRelaysNearby = String(localized: "location_notes.no_relays_nearby")
        static let relaysRetryHint = String(localized: "location_notes.relays_retry_hint")
        static let retry = String(localized: "location_notes.action.retry")
        static let dismissError = String(localized: "location_notes.action.dismiss")

        static func expiryDaysOption(_ days: Int) -> String {
            String(
                format: String(localized: "board.compose.expiry_days", defaultValue: "%lldd", comment: "Expiry picker option, number of days abbreviated"),
                locale: .current,
                days
            )
        }

        static let relativeFormatter: RelativeDateTimeFormatter = {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .abbreviated
            return f
        }()

        static func fades(_ expiresAt: Date) -> String {
            String(
                format: String(localized: "notices.fades", defaultValue: "fades %@", comment: "Shown on notices with an expiry; placeholder is a localized relative time like 'in 23h'"),
                locale: .current,
                relativeFormatter.localizedString(for: expiresAt, relativeTo: Date())
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
        .onAppear {
            if tab == .geo && geoTabNeedsDeviceLocation,
               Self.revealsNearbyNotes(onSwitchingTo: .geo, geoGeohash: geoGeohash) {
                NearbyNotesCounter.shared.reveal()
            }
            reconcileGeoSession()
        }
        .onChange(of: tab) { newTab in
            if newTab == .geo {
                if Self.revealsNearbyNotes(onSwitchingTo: newTab, geoGeohash: geoGeohash) {
                    NearbyNotesCounter.shared.reveal()
                }
            }
            reconcileGeoSession()
            // Each tab keeps its natural default: geo notes stay until
            // deleted (∞), mesh board posts fade within a week.
            expiryDays = newTab == .geo ? Self.permanentExpiry : 7
            urgent = false
        }
        // Catches both grant and revocation. Revocation must balance the live
        // refresh and release a device-derived building REQ immediately.
        .onChange(of: locationChannelsModel.permissionState) { _ in
            reconcileGeoSession()
        }
        .onChange(of: geoGeohash) { _ in
            reconcileGeoSession()
        }
        .onChange(of: geoTabNeedsDeviceLocation) { _ in
            reconcileGeoSession()
        }
        .onChange(of: scenePhase) { _ in
            reconcileGeoSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: LocationNotesSettings.didChangeNotification)) { _ in
            let enabled = LocationNotesSettings.enabled
            locationNotesEnabled = enabled
            reconcileGeoSession(notesEnabled: enabled)
        }
        .onDisappear {
            if ownsLiveGeoRefresh {
                locationChannelsModel.endLiveRefresh()
                ownsLiveGeoRefresh = false
            }
            if notesManager == nil {
                LocationNotesPool.shared.release(liveGeoManager)
            }
            liveGeoManager = nil
        }
    }

    private var sheetTitle: String {
        switch lockedScope {
        case .geo:
            return String(localized: "app_info.location.notes.title", defaultValue: "Location Notes", comment: "Title for place-scoped notes sheet").capitalized
        case .mesh, .none:
            return Strings.title.capitalized
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThemedSheetHeader(
                title: sheetTitle,
                subtitle: scopeSubtitle,
                onClose: { dismiss() }
            )

            VStack(alignment: .leading, spacing: 8) {
                if lockedScope == nil {
                    Picker(Strings.scopePicker, selection: $tab) {
                        Text(Strings.geoTab.capitalized).tag(Tab.geo)
                        Text(Strings.meshTab.capitalized).tag(Tab.mesh)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel(Strings.scopePicker)
                }
                Text(tab == .geo ? Strings.geoDescription : Strings.meshDescription)
                    .bitchatFont(size: 12)
                    .foregroundColor(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .themedSurface()
        }
    }

    private var scopeSubtitle: String? {
        switch tab {
        case .mesh:
            return "#mesh"
        case .geo:
            return geoGeohash.map { "#\($0)" }
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
            switch Self.geoPresentationState(
                notesEnabled: locationNotesEnabled,
                geohash: geoGeohash
            ) {
            case .disabled:
                locationNotesDisabledSection
            case .available(let geohash):
                if let manager = activeNotesManager {
                    GeoNoticesList(geohash: geohash, board: board, manager: manager)
                } else {
                    // Manager is created on appear; visible for one frame.
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear { reconcileGeoSession() }
                }
            case .locationUnavailable:
                locationUnavailableSection
            }
        }
    }

    private var locationNotesDisabledSection: some View {
        ScrollView {
            ThemedCard {
                Toggle(
                    isOn: Binding(
                        get: { locationNotesEnabled },
                        set: { enabled in
                            locationNotesEnabled = enabled
                            LocationNotesSettings.enabled = enabled
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Strings.locationNotesTitle)
                            .bitchatFont(size: 15, weight: .semibold)
                            .foregroundColor(palette.primary)
                        Text(Strings.locationNotesDescription)
                            .bitchatFont(size: 13)
                            .foregroundColor(palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var locationUnavailableSection: some View {
        ScrollView {
            ThemedCard {
                Text(Strings.locationUnavailable)
                    .bitchatFont(size: 13)
                    .foregroundColor(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: { locationChannelsModel.enableAndRefresh() }) {
                    Text(Strings.enableLocation)
                        .bitchatFont(size: 14, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(palette.accent)
                        .foregroundColor(palette.accentForeground)
                        .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if tab == .mesh {
                    Button {
                        urgent.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: urgent ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                                .font(.system(size: 11, weight: .semibold))
                            Text(Strings.urgentToggle)
                                .bitchatFont(size: 11, weight: .semibold)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(urgent ? palette.alertRed.opacity(0.16) : palette.cardBackground)
                        .foregroundColor(urgent ? palette.alertRed : palette.secondary)
                        .overlay(
                            Capsule()
                                .stroke(urgent ? palette.alertRed.opacity(0.4) : palette.cardBorder, lineWidth: 1)
                        )
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Strings.urgentToggle)
                }

                Spacer()

                HStack(spacing: 4) {
                    Text(Strings.expiryLabel)
                        .bitchatFont(size: 11)
                        .foregroundColor(palette.secondary)
                        .padding(.trailing, 2)

                    let expiryOptions: [(tag: Int, label: String, a11y: String)] = {
                        var options: [(Int, String, String)] = []
                        if tab == .geo {
                            options.append((Self.permanentExpiry, "∞", Strings.permanentOption))
                        }
                        for days in [1, 3, 7] {
                            let label = Strings.expiryDaysOption(days)
                            options.append((days, label, label))
                        }
                        return options
                    }()

                    ForEach(expiryOptions, id: \.tag) { option in
                        let isSelected = expiryDays == option.tag
                        Button {
                            expiryDays = option.tag
                        } label: {
                            Text(verbatim: option.label)
                                .bitchatFont(size: 11, weight: isSelected ? .semibold : .medium)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isSelected ? palette.accent : palette.cardBackground)
                                .foregroundColor(isSelected ? palette.accentForeground : palette.secondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.a11y)
                    }
                }
            }
            .padding(.horizontal, 14)

            HStack(alignment: .bottom, spacing: 8) {
                TextField(Strings.placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .bitchatFont(size: 15)
                    .foregroundColor(palette.primary)
                    .lineLimit(1...maxDraftLines)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    .themedInputBackground()
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundColor(sendEnabled ? palette.accent : palette.secondary.opacity(0.4))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(!sendEnabled)
                .accessibilityLabel(Strings.send)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .themedChromePanel(edge: .bottom)
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var sendEnabled: Bool {
        let trimmed = draft.trimmed
        return !trimmed.isEmpty && trimmed.utf8.count <= BoardWireConstants.contentMaxBytes
    }

    private func send() {
        guard let geohash = activeGeohash, let content = draft.trimmedOrNilIfEmpty else { return }

        // ∞ (geo default): a pure relay note with no NIP-40 tag. It skips
        // the mesh board deliberately — a board copy must fade within days,
        // which would contradict the permanence the user just picked.
        if tab == .geo, expiryDays == Self.permanentExpiry {
            guard let manager = activeNotesManager else { return }
            manager.send(content: content, nickname: senderNickname, expiresAt: nil)
            draft = ""
            urgent = false
            return
        }

        // Expiring posts go to the board and are bridged to Nostr by
        // BoardManager, so mesh and internet see the same notice with the
        // chosen expiry (expiresAt on mesh, NIP-40 on the bridged note).
        // Urgency is mesh-only.
        let sent = board.createPost(
            content: content,
            geohash: geohash,
            urgent: tab == .mesh && urgent,
            expiryDays: expiryDays,
            nickname: senderNickname
        )
        if sent {
            draft = ""
            urgent = false
        }
    }
}

/// The geo tab's list: renders the sheet-owned Nostr notes subscription
/// merged with the board posts for the same geohash. The manager lives on
/// `NoticesView` so the composer can post through the same instance (∞
/// notes local-echo into this list).
private struct GeoNoticesList: View {
    let geohash: String
    @ObservedObject var board: BoardManager
    @ObservedObject var notesManager: LocationNotesManager

    init(geohash: String, board: BoardManager, manager: LocationNotesManager) {
        self.geohash = geohash.lowercased()
        self.board = board
        self.notesManager = manager
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                statusRows

                if items.isEmpty {
                    if showEmptyState {
                        VStack(spacing: 10) {
                            Image(systemName: "pin")
                                .font(.system(size: 24, weight: .medium))
                                .foregroundColor(palette.secondary)
                                .frame(width: 52, height: 52)
                                .background(palette.cardBackground)
                                .clipShape(Circle())
                            Text(Strings.emptyTitle)
                                .bitchatFont(size: 15, weight: .semibold)
                                .foregroundColor(palette.primary)
                            Text(Strings.emptySubtitle)
                                .bitchatFont(size: 13)
                                .foregroundColor(palette.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                        .padding(.horizontal, 24)
                    }
                } else {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Notes may still be loading or unreachable; only claim "no notices yet"
    /// once the sources settled.
    private var showEmptyState: Bool {
        guard let notesManager else { return true }
        return notesManager.initialLoadComplete
            && notesManager.state != .loading
            && notesManager.state != .connecting
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
            } else if notesManager.state == .connecting {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(Strings.connectingRelays)
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
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if item.isUrgent {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(Strings.urgentBadge)
                            .bitchatFont(size: 10, weight: .semibold)
                    }
                    .foregroundColor(palette.alertRed)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(palette.alertRed.opacity(0.14))
                    .clipShape(Capsule())
                }
                Text(verbatim: "@\(item.author)")
                    .bitchatFont(size: 13, weight: .semibold)
                    .foregroundColor(palette.primary)
                    .lineLimit(1)
                Text(Self.timestampText(for: item.createdAt))
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.secondary)
                if let expiresAt = item.expiresAt, expiresAt > Date() {
                    Text(Strings.fades(expiresAt))
                        .bitchatFont(size: 11)
                        .foregroundColor(palette.secondary.opacity(0.8))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if showsSource {
                    sourceBadge(item)
                }
                if isOwn {
                    Button {
                        delete(item)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(palette.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Strings.deleteAction)
                }
            }
            Text(item.content)
                .bitchatFont(size: 14)
                .foregroundColor(palette.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: palette.cardRadius, style: .continuous)
                .stroke(item.isUrgent ? palette.alertRed.opacity(0.35) : palette.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: palette.cardRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.rowAccessibilityLabel(author: item.author, content: item.content, urgent: item.isUrgent))
        .accessibilityActions {
            if isOwn {
                Button(Strings.deleteAction) { delete(item) }
            }
        }
    }

    private func sourceBadge(_ item: NoticeItem) -> some View {
        HStack(spacing: 3) {
            Image(systemName: item.isBoardPost ? "antenna.radiowaves.left.and.right" : "globe")
                .font(.system(size: 10, weight: .medium))
            Text(item.isBoardPost ? Strings.meshSource : Strings.nostrSource)
                .bitchatFont(size: 10, weight: .medium)
        }
        .foregroundColor(palette.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(palette.secondary.opacity(0.10))
        .clipShape(Capsule())
        .accessibilityLabel(item.isBoardPost ? Strings.meshSource : Strings.nostrSource)
    }

    // MARK: - Timestamp Formatting

    private static func timestampText(for date: Date) -> String {
        let now = Date()
        if let days = Calendar.current.dateComponents([.day], from: date, to: now).day, days < 7 {
            // The whole "3 hr ago" phrase must come from the formatter —
            // gluing an English "ago" onto a localized duration ships the
            // wrong word order to most locales ("hace 3 h", "vor 3 Std").
            return NoticesView.Strings.relativeFormatter.localizedString(for: date, relativeTo: now)
        }
        let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        return (sameYear ? absDateFormatter : absDateYearFormatter).string(from: date)
    }

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
