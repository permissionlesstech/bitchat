//
// PlaceFeedView.swift
// bitchat
//
// First-class Place Feed inside active Place rooms: persistent/expiring kind-1
// posts merged with offline mesh board notices, NIP-10 threaded replies,
// NIP-25 emoji reactions, NIP-13 PoW mining/scoring, and per-place unlinkable
// identities routed over GeoRelayDirectory (and Tor in Stealth Mode).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct PlaceFeedView: View {
    let channel: GeohashChannel
    let senderNickname: String
    @ObservedObject var board: BoardManager
    let isTeleported: Bool
    let searchQuery: String
    let topContentInset: CGFloat
    let usesOverlayChrome: Bool
    /// Optional injected manager for tests and previews; live use pools via `LocationNotesPool`.
    let injectedNotesManager: LocationNotesManager?

    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ThemedPalette private var palette

    @State private var liveManager: LocationNotesManager?
    @State private var locationNotesEnabled = LocationNotesSettings.enabled
    @State private var sort: PlaceFeedSort = .latest
    @State private var filter: PlaceFeedFilter = .all
    @State private var draft = ""
    /// Days until the post fades; `0` means permanent (no NIP-40 expiration tag).
    @State private var expiryDays = 0
    @State private var identityMode: PostingIdentityMode = .placePersona
    @State private var showPublicProfileSheet = false
    @State private var selectedThreadRoot: LocationNotesManager.Note?
    @State private var bottomComposerHeight: CGFloat = 0
    @State private var showPhotoPicker = false
    @State private var pendingAttachments: [NostrProtocol.MediaAttachment] = []
    @State private var isUploadingMedia = false
    @State private var mediaUploadError: String?

    init(
        channel: GeohashChannel,
        senderNickname: String,
        board: BoardManager,
        isTeleported: Bool = false,
        searchQuery: String = "",
        topContentInset: CGFloat = 0,
        usesOverlayChrome: Bool = false,
        notesManager: LocationNotesManager? = nil
    ) {
        self.channel = channel
        self.senderNickname = senderNickname
        self.board = board
        self.isTeleported = isTeleported
        self.searchQuery = searchQuery
        self.topContentInset = topContentInset
        self.usesOverlayChrome = usesOverlayChrome
        self.injectedNotesManager = notesManager
    }

    private var activeManager: LocationNotesManager? {
        injectedNotesManager ?? liveManager
    }

    private var geohash: String {
        channel.geohash.lowercased()
    }

    private var maxDraftLines: Int {
        dynamicTypeSize.isAccessibilitySize ? 5 : 3
    }

    var body: some View {
        Group {
            if !locationNotesEnabled {
                disabledView
            } else if let manager = activeManager {
                PlaceFeedContent(
                    channel: channel,
                    senderNickname: senderNickname,
                    board: board,
                    manager: manager,
                    isTeleported: isTeleported,
                    userTorEnabled: locationChannelsModel.userTorEnabled,
                    searchQuery: searchQuery,
                    topContentInset: topContentInset,
                    usesOverlayChrome: usesOverlayChrome,
                    sort: $sort,
                    filter: $filter,
                    draft: $draft,
                    expiryDays: $expiryDays,
                    identityMode: $identityMode,
                    showPublicProfileSheet: $showPublicProfileSheet,
                    selectedThreadRoot: $selectedThreadRoot,
                    bottomComposerHeight: $bottomComposerHeight,
                    showPhotoPicker: $showPhotoPicker,
                    pendingAttachments: $pendingAttachments,
                    isUploadingMedia: $isUploadingMedia,
                    mediaUploadError: $mediaUploadError,
                    maxDraftLines: maxDraftLines
                )
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ThemedRootBackground())
            }
        }
        .onAppear {
            reconcileManager()
        }
        .onChange(of: geohash) { _ in
            reconcileManager()
        }
        .onReceive(NotificationCenter.default.publisher(for: LocationNotesSettings.didChangeNotification)) { _ in
            locationNotesEnabled = LocationNotesSettings.enabled
            reconcileManager()
        }
        .onDisappear {
            releaseLiveManager()
        }
        .sheet(item: $selectedThreadRoot) { rootNote in
            if let manager = activeManager {
                PlaceThreadSheet(
                    rootNote: rootNote,
                    geohash: geohash,
                    senderNickname: senderNickname,
                    isTeleported: isTeleported,
                    manager: manager
                )
            }
        }
        .sheet(isPresented: $showPublicProfileSheet) {
            PublicProfileSheet(defaultNickname: senderNickname)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showPhotoPicker) {
            ImagePickerView(sourceType: .photoLibrary) { image in
                showPhotoPicker = false
                if let image, let jpeg = image.jpegData(compressionQuality: 0.9) {
                    uploadSelectedImageData(jpeg)
                }
            }
            .ignoresSafeArea()
        }
        #else
        .sheet(isPresented: $showPhotoPicker) {
            MacImagePickerView { url in
                showPhotoPicker = false
                if let url, let data = try? Data(contentsOf: url) {
                    uploadSelectedImageData(data)
                }
            }
        }
        #endif
    }

    private func uploadSelectedImageData(_ rawData: Data) {
        guard !isUploadingMedia else { return }
        isUploadingMedia = true
        mediaUploadError = nil
        let usePublicHandle = identityMode == .publicHandle && NostrProfileStore.shared.isPublicHandleEnabled
        let targetGeohash = geohash

        Task {
            do {
                let identity: NostrIdentity
                if usePublicHandle, let persistent = try NostrIdentityBridge.shared.getCurrentNostrIdentity() {
                    identity = persistent
                } else {
                    identity = try NostrIdentityBridge.shared.deriveIdentity(forGeohash: targetGeohash)
                }
                let attachment = try await BlossomMediaService.shared.uploadImage(
                    rawData: rawData,
                    senderIdentity: identity
                )
                await MainActor.run {
                    if pendingAttachments.count < NostrProtocol.maxAttachmentsPerNote {
                        pendingAttachments.append(attachment)
                    }
                    isUploadingMedia = false
                }
            } catch {
                await MainActor.run {
                    mediaUploadError = error.localizedDescription
                    isUploadingMedia = false
                }
            }
        }
    }

    private func reconcileManager() {
        guard injectedNotesManager == nil else { return }
        guard locationNotesEnabled else {
            releaseLiveManager()
            return
        }
        if let existing = liveManager {
            if existing.geohash == geohash {
                if existing.state == .idle {
                    existing.refresh()
                }
                return
            }
            LocationNotesPool.shared.release(existing)
            liveManager = nil
        }
        liveManager = LocationNotesPool.shared.acquire(geohash)
    }

    private func releaseLiveManager() {
        guard injectedNotesManager == nil, let existing = liveManager else { return }
        LocationNotesPool.shared.release(existing)
        liveManager = nil
    }

    private var disabledView: some View {
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
                        Text(String(localized: "app_info.location.notes.title"))
                            .bitchatFont(size: 15, weight: .semibold)
                            .foregroundColor(palette.primary)
                        Text(String(localized: "app_info.location.notes.description"))
                            .bitchatFont(size: 13)
                            .foregroundColor(palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
            .padding(16)
            .padding(.top, usesOverlayChrome ? topContentInset : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemedRootBackground())
    }
}

// MARK: - Observed Feed Body

private struct PlaceFeedContent: View {
    let channel: GeohashChannel
    let senderNickname: String
    @ObservedObject var board: BoardManager
    @ObservedObject var manager: LocationNotesManager
    let isTeleported: Bool
    let userTorEnabled: Bool
    let searchQuery: String
    let topContentInset: CGFloat
    let usesOverlayChrome: Bool
    @Binding var sort: PlaceFeedSort
    @Binding var filter: PlaceFeedFilter
    @Binding var draft: String
    @Binding var expiryDays: Int
    @Binding var identityMode: PostingIdentityMode
    @Binding var showPublicProfileSheet: Bool
    @Binding var selectedThreadRoot: LocationNotesManager.Note?
    @Binding var bottomComposerHeight: CGFloat
    @Binding var showPhotoPicker: Bool
    @Binding var pendingAttachments: [NostrProtocol.MediaAttachment]
    @Binding var isUploadingMedia: Bool
    @Binding var mediaUploadError: String?
    let maxDraftLines: Int

    @ObservedObject private var profileStore = NostrProfileStore.shared
    @ObservedObject private var followsStore = NostrFollowsStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @ThemedPalette private var palette

    private var geohash: String { channel.geohash.lowercased() }

    private var mergedItems: [NoticeItem] {
        UnifiedNotices.merge(
            posts: board.posts(forGeohash: geohash),
            notes: manager.notes
        )
    }

    private var visibleItems: [NoticeItem] {
        PlaceFeedOrganizer.organize(
            items: mergedItems,
            sort: sort,
            filter: filter,
            query: searchQuery,
            replyCount: { manager.replyCount(forRootID: $0) },
            reactionCount: { manager.totalReactionCount(forNoteID: $0) },
            isVouched: { item in
                guard let note = item.nostrNote else { return false }
                return LocalWebOfTrustService.shared.isTrustedAuthor(note.pubkey)
            }
        )
    }

    private var isFiltering: Bool {
        filter != .all || !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showEmptyState: Bool {
        manager.initialLoadComplete
            && manager.state != .loading
            && manager.state != .connecting
    }

    private var composerIdentityLabel: String {
        if identityMode == .publicHandle, profileStore.isPublicHandleEnabled {
            let handle = profileStore.ownProfile.displayName.trimmedOrNilIfEmpty ?? senderNickname.trimmedOrNilIfEmpty ?? "anon"
            return "@\(handle)"
        }
        let base = senderNickname.trimmedOrNilIfEmpty ?? "anon"
        if let suffix = manager.ownIdentitySuffix {
            return "\(base)#\(suffix)"
        }
        return base
    }

    private var sendEnabled: Bool {
        let trimmed = draft.trimmed
        return !trimmed.isEmpty && trimmed.utf8.count <= BoardWireConstants.contentMaxBytes && !manager.isSending
    }

    var body: some View {
        if usesOverlayChrome {
            if #available(iOS 17.0, macOS 14.0, *) {
                scrollList
                    .contentMargins(.top, topContentInset, for: .scrollContent)
                    .contentMargins(.top, topContentInset, for: .scrollIndicators)
                    .contentMargins(.bottom, max(bottomComposerHeight, 96), for: .scrollContent)
                    .contentMargins(.bottom, max(bottomComposerHeight, 96), for: .scrollIndicators)
                    .overlay(alignment: .bottom) {
                        composer
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(key: FeedComposerHeightKey.self, value: proxy.size.height)
                                }
                            )
                    }
                    .onPreferenceChange(FeedComposerHeightKey.self) { height in
                        if abs(bottomComposerHeight - height) > 0.5 {
                            bottomComposerHeight = height
                        }
                    }
            } else {
                scrollList
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        composer
                    }
            }
        } else {
            VStack(spacing: 0) {
                scrollList
                composer
            }
        }
    }

    private var scrollList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                filterBar
                statusRows

                if visibleItems.isEmpty {
                    if showEmptyState {
                        emptyStateCard
                    }
                } else {
                    ForEach(visibleItems) { item in
                        let own = isOwn(item)
                        let authorHex = item.nostrNote?.pubkey
                        PlaceFeedPostCard(
                            item: item,
                            isOwn: own,
                            replyCount: item.nostrNote.map { manager.replyCount(forRootID: $0.id) } ?? 0,
                            reactions: item.nostrNote.map { manager.reactions(forNoteID: $0.id) } ?? [],
                            isFollowingAuthor: authorHex.map { followsStore.isFollowing($0) } ?? false,
                            onToggleFollow: (!own && authorHex != nil) ? {
                                guard let hex = authorHex else { return }
                                let alias = profileStore.displayName(for: hex, fallbackNickname: item.nostrNote?.nickname)
                                followsStore.toggleFollow(hex, alias: alias)
                            } : nil,
                            onOpenThread: {
                                if let note = item.nostrNote {
                                    selectedThreadRoot = note
                                }
                            },
                            onToggleReaction: { emoji in
                                if let note = item.nostrNote {
                                    manager.toggleReaction(emoji: emoji, on: note)
                                }
                            },
                            onDelete: {
                                delete(item)
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            manager.refresh()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemedRootBackground())
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Sort pills
                ForEach(PlaceFeedSort.allCases) { option in
                    let isSelected = sort == option
                    Button {
                        sort = option
                    } label: {
                        Text(sortTitle(option))
                            .bitchatFont(size: 12, weight: isSelected ? .semibold : .medium)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isSelected ? palette.accent : palette.cardBackground)
                            .foregroundColor(isSelected ? palette.accentForeground : palette.secondary)
                            .overlay(
                                Capsule().stroke(isSelected ? Color.clear : palette.cardBorder, lineWidth: 1)
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Rectangle()
                    .fill(palette.divider)
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 2)

                // Signal filter pills
                ForEach(PlaceFeedFilter.allCases) { option in
                    let isSelected = filter == option
                    Button {
                        filter = option
                    } label: {
                        HStack(spacing: 4) {
                            if option == .localOnly {
                                Image(systemName: "location.fill")
                                    .font(.system(size: 10, weight: .semibold))
                            } else if option == .verifiedPoW {
                                Image(systemName: "bolt.shield.fill")
                                    .font(.system(size: 10, weight: .semibold))
                            } else if option == .vouched {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            Text(filterTitle(option))
                                .bitchatFont(size: 12, weight: isSelected ? .semibold : .medium)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isSelected ? palette.locationAccent.opacity(0.18) : palette.cardBackground)
                        .foregroundColor(isSelected ? palette.locationAccent : palette.secondary)
                        .overlay(
                            Capsule().stroke(isSelected ? palette.locationAccent.opacity(0.45) : palette.cardBorder, lineWidth: 1)
                        )
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if userTorEnabled {
                    HStack(spacing: 3) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 10, weight: .semibold))
                        Text(String(localized: "place_feed.badge.tor", defaultValue: "Tor", comment: "Indicator that Place Feed traffic is routed over Tor"))
                            .bitchatFont(size: 11, weight: .semibold)
                    }
                    .foregroundColor(palette.locationAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(palette.locationAccent.opacity(0.12))
                    .clipShape(Capsule())
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var statusRows: some View {
        if manager.state == .loading && !manager.initialLoadComplete {
            HStack(spacing: 10) {
                ProgressView()
                Text(String(localized: "location_notes.loading_notes"))
                    .bitchatFont(size: 12)
                    .foregroundColor(palette.secondary)
                Spacer()
            }
            .padding(.vertical, 6)
        } else if manager.state == .connecting {
            HStack(spacing: 10) {
                ProgressView()
                Text(String(localized: "location_notes.connecting_relays"))
                    .bitchatFont(size: 12)
                    .foregroundColor(palette.secondary)
                Spacer()
            }
            .padding(.vertical, 6)
        } else if manager.state == .noRelays {
            ThemedCard {
                Text(String(localized: "location_notes.no_relays_nearby"))
                    .bitchatFont(size: 13, weight: .semibold)
                    .foregroundColor(palette.primary)
                Text(String(localized: "location_notes.relays_retry_hint"))
                    .bitchatFont(size: 12)
                    .foregroundColor(palette.secondary)
                Button(String(localized: "location_notes.action.retry")) {
                    manager.refresh()
                }
                .bitchatFont(size: 12, weight: .semibold)
                .foregroundColor(palette.accent)
                .buttonStyle(.plain)
            }
        } else if let error = manager.errorMessage {
            ThemedCard {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(palette.alertRed)
                        .font(.system(size: 12))
                    Text(error)
                        .bitchatFont(size: 12)
                        .foregroundColor(palette.primary)
                    Spacer()
                }
                Button(String(localized: "location_notes.action.dismiss")) {
                    manager.clearError()
                }
                .bitchatFont(size: 12, weight: .semibold)
                .foregroundColor(palette.accent)
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyStateCard: some View {
        VStack(spacing: 10) {
            Image(systemName: isFiltering ? "line.3.horizontal.decrease.circle" : "text.bubble")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(palette.secondary)
                .frame(width: 52, height: 52)
                .background(palette.cardBackground)
                .clipShape(Circle())
            Text(
                isFiltering
                    ? String(localized: "place_feed.empty.filtered_title", defaultValue: "No matching posts", comment: "Empty state title when feed filters or search hide all posts")
                    : String(localized: "place_feed.empty.title", defaultValue: "No posts here yet", comment: "Empty state title for a Place Feed with no posts")
            )
            .bitchatFont(size: 15, weight: .semibold)
            .foregroundColor(palette.primary)
            Text(
                isFiltering
                    ? String(localized: "place_feed.empty.filtered_subtitle", defaultValue: "Try clearing your filter or search query.", comment: "Empty state hint when feed filters hide all posts")
                    : String(localized: "place_feed.empty.subtitle", defaultValue: "Start the local timeline for this place. Posts are signed with an unlinkable per-place identity.", comment: "Empty state subtitle explaining per-place pseudonymous posting")
            )
            .bitchatFont(size: 13)
            .foregroundColor(palette.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 24)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    if identityMode == .placePersona {
                        if profileStore.isPublicHandleEnabled {
                            identityMode = .publicHandle
                        } else {
                            showPublicProfileSheet = true
                        }
                    } else {
                        identityMode = .placePersona
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: identityMode == .publicHandle && profileStore.isPublicHandleEnabled ? "person.crop.circle.fill" : "theatermasks.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(identityMode == .publicHandle && profileStore.isPublicHandleEnabled ? palette.accent : PeerColorContrast.selfColor(isDark: colorScheme == .dark))
                        Text(
                            String(
                                format: String(localized: "place_feed.composer.posting_as", defaultValue: "Posting as %@", comment: "Label showing the unlinkable per-place identity used to sign a feed post"),
                                locale: .current,
                                composerIdentityLabel
                            )
                        )
                        .bitchatFont(size: 11, weight: .medium)
                        .foregroundColor(palette.secondary)
                        .lineLimit(1)
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(palette.secondary.opacity(0.75))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(palette.cardBackground)
                    .overlay(Capsule().stroke(palette.cardBorder, lineWidth: 1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                if isTeleported {
                    Text(String(localized: "place_feed.badge.teleported", defaultValue: "teleported", comment: "Badge indicating a post was published remotely while teleported"))
                        .bitchatFont(size: 10, weight: .medium)
                        .foregroundColor(palette.accentBlue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(palette.accentBlue.opacity(0.14))
                        .clipShape(Capsule())
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    let expiryOptions: [(tag: Int, label: String, a11y: String)] = {
                        var options: [(Int, String, String)] = [
                            (0, "∞", String(localized: "notices.expiry.permanent", defaultValue: "permanent", comment: "Accessibility label for permanent post option"))
                        ]
                        for days in [1, 3, 7] {
                            let label = String(
                                format: String(localized: "board.compose.expiry_days", defaultValue: "%lldd", comment: "Expiry picker option, number of days abbreviated"),
                                locale: .current,
                                days
                            )
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
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(isSelected ? palette.accent : palette.cardBackground)
                                .foregroundColor(isSelected ? palette.accentForeground : palette.secondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.a11y)
                    }
                }
            }
            .padding(.horizontal, 12)

            if isUploadingMedia || !pendingAttachments.isEmpty || mediaUploadError != nil {
                HStack(spacing: 6) {
                    if isUploadingMedia {
                        ProgressView()
                            .scaleEffect(0.75)
                        Text(String(localized: "place_feed.media.uploading", defaultValue: "Uploading over Tor…", comment: "Status while uploading an EXIF-stripped image to Blossom"))
                            .bitchatFont(size: 11)
                            .foregroundColor(palette.secondary)
                    } else if !pendingAttachments.isEmpty {
                        Image(systemName: "photo.badge.checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(palette.locationAccent)
                        Text(String(localized: "place_feed.media.attached", defaultValue: "1 photo attached", comment: "Indicator that an uploaded Blossom image is attached to the draft"))
                            .bitchatFont(size: 11, weight: .medium)
                            .foregroundColor(palette.locationAccent)
                        Spacer()
                        Button {
                            pendingAttachments.removeAll()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(palette.secondary)
                        }
                        .buttonStyle(.plain)
                    } else if let mediaUploadError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(palette.alertRed)
                        Text(mediaUploadError)
                            .bitchatFont(size: 11)
                            .foregroundColor(palette.alertRed)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            self.mediaUploadError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(palette.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    showPhotoPicker = true
                } label: {
                    Image(systemName: "photo")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(pendingAttachments.isEmpty ? palette.secondary : palette.locationAccent)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(isUploadingMedia || pendingAttachments.count >= NostrProtocol.maxAttachmentsPerNote)
                .accessibilityLabel(String(localized: "place_feed.media.attach", defaultValue: "Attach image", comment: "Button to attach an EXIF-stripped image via Blossom"))

                TextField(
                    String(localized: "place_feed.composer.placeholder", defaultValue: "Post to this place…", comment: "Placeholder text for the Place Feed post composer"),
                    text: $draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .bitchatFont(size: 15)
                .foregroundColor(palette.primary)
                .lineLimit(1...maxDraftLines)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .themedInputBackground()
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: submitPost) {
                    if manager.isSending {
                        ProgressView()
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundColor(sendEnabled ? palette.accent : palette.secondary.opacity(0.4))
                            .frame(width: 32, height: 32)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!sendEnabled)
                .accessibilityLabel(String(localized: "place_feed.action.post", defaultValue: "Post", comment: "Accessibility label for the Place Feed submit button"))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .padding(.top, 8)
        .themedChromePanel(edge: .bottom)
    }

    private func submitPost() {
        guard let content = draft.trimmedOrNilIfEmpty else { return }
        let activeMode: PostingIdentityMode = (identityMode == .publicHandle && profileStore.isPublicHandleEnabled)
            ? .publicHandle
            : .placePersona
        let postNickname = activeMode == .publicHandle
            ? (profileStore.ownProfile.displayName.trimmedOrNilIfEmpty ?? senderNickname)
            : senderNickname

        if expiryDays == 0 || activeMode == .publicHandle || !pendingAttachments.isEmpty {
            let expiresAt = expiryDays > 0
                ? Date().addingTimeInterval(TimeInterval(expiryDays * 24 * 60 * 60))
                : nil
            if manager.sendFeedPost(
                content: content,
                nickname: postNickname,
                expiresAt: expiresAt,
                urgent: false,
                teleported: isTeleported,
                replyTo: nil,
                identityMode: activeMode,
                attachments: pendingAttachments
            ) {
                draft = ""
                pendingAttachments.removeAll()
            }
        } else {
            // Expiring per-place post: bridges to both mesh board (when nearby) and Nostr with NIP-40 expiry.
            let expiresAt = Date().addingTimeInterval(TimeInterval(expiryDays * 24 * 60 * 60))
            if isTeleported {
                if manager.sendFeedPost(
                    content: content,
                    nickname: senderNickname,
                    expiresAt: expiresAt,
                    urgent: false,
                    teleported: true,
                    replyTo: nil,
                    identityMode: .placePersona
                ) {
                    draft = ""
                }
            } else {
                let sent = board.createPost(
                    content: content,
                    geohash: geohash,
                    urgent: false,
                    expiryDays: expiryDays,
                    nickname: senderNickname
                )
                if sent {
                    draft = ""
                }
            }
        }
    }

    private func isOwn(_ item: NoticeItem) -> Bool {
        switch item.source {
        case .board(let post):
            return board.isOwnPost(post)
        case .nostr(let note):
            return manager.isOwnNote(note)
        }
    }

    private func delete(_ item: NoticeItem) {
        switch item.source {
        case .board(let post):
            board.deletePost(post)
        case .nostr(let note):
            manager.delete(note: note)
        }
    }

    private func sortTitle(_ option: PlaceFeedSort) -> String {
        switch option {
        case .latest:
            return String(localized: "place_feed.sort.latest", defaultValue: "Latest", comment: "Sort option showing newest posts first in Place Feed")
        case .top:
            return String(localized: "place_feed.sort.top", defaultValue: "Top", comment: "Sort option ranking posts by replies, reactions, and PoW in Place Feed")
        }
    }

    private func filterTitle(_ option: PlaceFeedFilter) -> String {
        switch option {
        case .all:
            return String(localized: "place_feed.filter.all", defaultValue: "All", comment: "Filter option showing all Place Feed posts")
        case .localOnly:
            return String(localized: "place_feed.filter.local_only", defaultValue: "On-site", comment: "Filter option hiding remotely teleported posts")
        case .verifiedPoW:
            return String(localized: "place_feed.filter.pow", defaultValue: "PoW", comment: "Filter option showing posts backed by NIP-13 proof of work or mesh")
        case .vouched:
            return String(localized: "place_feed.filter.vouched", defaultValue: "Vouched", comment: "Filter option showing posts from in-person verified or vouched authors")
        }
    }
}

// MARK: - Feed Post Card

struct PlaceFeedPostCard: View {
    let item: NoticeItem
    let isOwn: Bool
    let replyCount: Int
    let reactions: [AggregatedReaction]
    var placeBadgeLabel: String? = nil
    var isFollowingAuthor: Bool = false
    var onTapPlace: (() -> Void)? = nil
    var onToggleFollow: (() -> Void)? = nil
    let onOpenThread: () -> Void
    let onToggleReaction: (String) -> Void
    let onDelete: () -> Void

    @ObservedObject private var profileStore = NostrProfileStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @ThemedPalette private var palette

    private var resolvedAuthorName: String {
        if let note = item.nostrNote {
            return profileStore.displayName(for: note.pubkey, fallbackNickname: note.nickname)
        }
        return item.author
    }

    private var resolvedNip05: String? {
        guard let note = item.nostrNote else { return nil }
        return profileStore.profile(for: note.pubkey)?.nip05
    }

    private var authorColor: Color {
        isOwn
            ? PeerColorContrast.selfColor(isDark: colorScheme == .dark)
            : Color(peerSeed: item.authorColorSeed, isDark: colorScheme == .dark)
    }

    private var avatarInitial: String {
        String(resolvedAuthorName.prefix(1)).uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row: avatar + author + timestamp + badges + follow/delete
            HStack(alignment: .top, spacing: 10) {
                Text(verbatim: avatarInitial)
                    .bitchatFont(size: 13, weight: .bold)
                    .foregroundColor(authorColor)
                    .frame(width: 32, height: 32)
                    .background(authorColor.opacity(0.15))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(verbatim: "@\(resolvedAuthorName)")
                            .bitchatFont(size: 14, weight: .semibold)
                            .foregroundColor(authorColor)
                            .lineLimit(1)

                        if let suffix = item.authorSuffix {
                            Text(verbatim: "#\(suffix)")
                                .bitchatFont(size: 11)
                                .foregroundColor(palette.secondary)
                                .lineLimit(1)
                        }

                        Text(verbatim: "·")
                            .bitchatFont(size: 11)
                            .foregroundColor(palette.secondary)

                        Text(PlaceFeedTimestamp.text(for: item.createdAt))
                            .bitchatFont(size: 11)
                            .foregroundColor(palette.secondary)
                            .lineLimit(1)
                    }

                    if let nip05 = resolvedNip05, !nip05.isEmpty {
                        Text(verbatim: nip05)
                            .bitchatFont(size: 11)
                            .foregroundColor(palette.locationAccent)
                            .lineLimit(1)
                    }

                    metadataBadges
                }

                Spacer(minLength: 4)

                if let onToggleFollow, !isOwn {
                    Button(action: onToggleFollow) {
                        Text(
                            isFollowingAuthor
                                ? String(localized: "public_profile.status.following", defaultValue: "Following", comment: "Badge button indicating author is currently followed")
                                : String(localized: "public_profile.action.follow", defaultValue: "Follow", comment: "Button to follow an author")
                        )
                        .bitchatFont(size: 11, weight: .semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isFollowingAuthor ? palette.accent.opacity(0.14) : palette.secondary.opacity(0.10))
                        .foregroundColor(isFollowingAuthor ? palette.accent : palette.secondary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if isOwn {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(palette.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "board.action.delete", defaultValue: "delete", comment: "Delete action for own posts"))
                }
            }

            if let placeBadgeLabel {
                Button {
                    onTapPlace?()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 10, weight: .semibold))
                        Text(verbatim: placeBadgeLabel)
                            .bitchatFont(size: 11, weight: .medium)
                            .lineLimit(1)
                    }
                    .foregroundColor(palette.locationAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(palette.locationAccent.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            // Post content
            Text(item.content)
                .bitchatFont(size: 15)
                .foregroundColor(palette.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Validated Blossom media attachments (Stealth/Tor tap-to-load)
            if let attachments = item.nostrNote?.attachments, !attachments.isEmpty {
                VStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        BlossomMediaAttachmentView(attachment: attachment)
                    }
                }
            }

            // Action & reaction bar (Nostr posts support NIP-10 replies and NIP-25 reactions)
            if item.nostrNote != nil {
                actionBar
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: palette.cardRadius, style: .continuous)
                .stroke(item.isUrgent ? palette.alertRed.opacity(0.4) : palette.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: palette.cardRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if item.nostrNote != nil {
                onOpenThread()
            }
        }
    }

    private var authorTrust: FeedAuthorTrust {
        guard let pubkey = item.nostrNote?.pubkey else { return .none }
        return LocalWebOfTrustService.shared.trust(forNostrPubkey: pubkey)
    }

    @ViewBuilder
    private var metadataBadges: some View {
        let trust = authorTrust
        let hasExpiry = item.expiresAt.map { $0 > Date() } ?? false
        let showBadges = item.isUrgent || trust.isTrusted || item.isTeleported || item.powDifficulty >= NostrProtocol.verifiedPoWThresholdBits || item.isBoardPost || hasExpiry
        if showBadges {
            HStack(spacing: 6) {
                if case .verified = trust {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(String(localized: "place_feed.badge.verified", defaultValue: "verified", comment: "Badge for an author directly verified in person"))
                            .bitchatFont(size: 10, weight: .semibold)
                    }
                    .foregroundColor(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.14))
                    .clipShape(Capsule())
                } else if case .vouched = trust {
                    HStack(spacing: 3) {
                        Image(systemName: "person.badge.shield.checkmark.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(String(localized: "place_feed.badge.vouched", defaultValue: "vouched", comment: "Badge for an author transitively vouched by verified peers"))
                            .bitchatFont(size: 10, weight: .semibold)
                    }
                    .foregroundColor(palette.locationAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(palette.locationAccent.opacity(0.14))
                    .clipShape(Capsule())
                }
                if item.isUrgent {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(String(localized: "board.urgent_badge", defaultValue: "urgent", comment: "Badge shown on urgent board posts"))
                            .bitchatFont(size: 10, weight: .semibold)
                    }
                    .foregroundColor(palette.alertRed)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(palette.alertRed.opacity(0.14))
                    .clipShape(Capsule())
                }

                if item.isBoardPost {
                    HStack(spacing: 3) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(String(localized: "notices.source.mesh", defaultValue: "mesh", comment: "Source badge for notices carried by the mesh"))
                            .bitchatFont(size: 10, weight: .medium)
                    }
                    .foregroundColor(palette.locationAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(palette.locationAccent.opacity(0.12))
                    .clipShape(Capsule())
                }

                if item.isTeleported {
                    HStack(spacing: 3) {
                        Image(systemName: "globe")
                            .font(.system(size: 9, weight: .medium))
                        Text(String(localized: "place_feed.badge.teleported", defaultValue: "teleported", comment: "Badge indicating a post was published remotely while teleported"))
                            .bitchatFont(size: 10, weight: .medium)
                    }
                    .foregroundColor(palette.accentBlue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(palette.accentBlue.opacity(0.12))
                    .clipShape(Capsule())
                }

                if item.powDifficulty >= NostrProtocol.verifiedPoWThresholdBits {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.shield.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(verbatim: "\(String(localized: "place_feed.badge.pow", defaultValue: "PoW", comment: "Proof of work badge label")) \(item.powDifficulty)")
                            .bitchatFont(size: 10, weight: .medium)
                    }
                    .foregroundColor(palette.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(palette.secondary.opacity(0.10))
                    .clipShape(Capsule())
                }

                if let expiresAt = item.expiresAt, expiresAt > Date() {
                    Text(
                        String(
                            format: String(localized: "notices.fades", defaultValue: "fades %@", comment: "Shown on notices with an expiry"),
                            locale: .current,
                            PlaceFeedTimestamp.relativeFormatter.localizedString(for: expiresAt, relativeTo: Date())
                        )
                    )
                    .bitchatFont(size: 10)
                    .foregroundColor(palette.secondary.opacity(0.85))
                    .lineLimit(1)
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button(action: onOpenThread) {
                HStack(spacing: 4) {
                    Image(systemName: replyCount > 0 ? "bubble.right.fill" : "bubble.right")
                        .font(.system(size: 12, weight: .medium))
                    if replyCount > 0 {
                        Text(verbatim: "\(replyCount)")
                            .bitchatFont(size: 12, weight: .semibold)
                    } else {
                        Text(String(localized: "place_feed.action.reply", defaultValue: "Reply", comment: "Button to open thread and reply to a post"))
                            .bitchatFont(size: 12, weight: .medium)
                    }
                }
                .foregroundColor(replyCount > 0 ? palette.accent : palette.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(palette.secondary.opacity(0.08))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            // Existing NIP-25 reaction chips
            ForEach(reactions) { reaction in
                Button {
                    onToggleReaction(reaction.emoji)
                } label: {
                    HStack(spacing: 3) {
                        Text(verbatim: reaction.emoji)
                            .font(.system(size: 12))
                        Text(verbatim: "\(reaction.count)")
                            .bitchatFont(size: 11, weight: .semibold)
                    }
                    .foregroundColor(reaction.includesCurrentUser ? palette.accent : palette.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        reaction.includesCurrentUser
                            ? palette.accent.opacity(0.16)
                            : palette.secondary.opacity(0.08)
                    )
                    .overlay(
                        Capsule().stroke(
                            reaction.includesCurrentUser ? palette.accent.opacity(0.4) : Color.clear,
                            lineWidth: 1
                        )
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            // Quick NIP-25 reaction picker menu
            Menu {
                ForEach(MessageInteractionCodec.quickReactionPalette, id: \.self) { emoji in
                    Button {
                        onToggleReaction(emoji)
                    } label: {
                        Text(verbatim: emoji)
                    }
                }
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(palette.secondary)
                    .frame(width: 28, height: 24)
                    .background(palette.secondary.opacity(0.08))
                    .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel(String(localized: "place_feed.action.react", defaultValue: "React", comment: "Accessibility label for adding an emoji reaction to a post"))

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Timestamp Helpers

enum PlaceFeedTimestamp {
    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func text(for date: Date, now: Date = Date()) -> String {
        if let days = Calendar.current.dateComponents([.day], from: date, to: now).day, days < 7 {
            return relativeFormatter.localizedString(for: date, relativeTo: now)
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

private struct FeedComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
