//
// HomeFeedView.swift
// bitchat
//
// Merged Home Feed across Saved Places (bookmarked geohashes via
// LocationNotesPool) and Followed authors (private Keychain follow list +
// favorited mesh peers' Nostr keys), with opt-in global kind-1 posting.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct HomeFeedView: View {
    let senderNickname: String
    let topContentInset: CGFloat
    let usesOverlayChrome: Bool
    let onSelectPlace: (String, String?) -> Void
    let onExplorePlaces: () -> Void
    let onOpenProfileSheet: () -> Void
    /// Optional injected manager for tests and previews.
    @ObservedObject var feedManager: HomeFeedManager

    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @ObservedObject private var followsStore = NostrFollowsStore.shared
    @ObservedObject private var profileStore = NostrProfileStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ThemedPalette private var palette

    @State private var scope: HomeFeedScope = .all
    @State private var sort: PlaceFeedSort = .latest
    @State private var filter: PlaceFeedFilter = .all
    @State private var draft = ""
    @State private var selectedThread: ThreadSelection?
    @State private var bottomComposerHeight: CGFloat = 0

    private struct ThreadSelection: Identifiable {
        let note: LocationNotesManager.Note
        let geohash: String
        let manager: LocationNotesManager
        var id: String { note.id }
    }

    @MainActor
    init(
        senderNickname: String,
        topContentInset: CGFloat = 0,
        usesOverlayChrome: Bool = false,
        onSelectPlace: @escaping (String, String?) -> Void,
        onExplorePlaces: @escaping () -> Void,
        onOpenProfileSheet: @escaping () -> Void,
        feedManager: HomeFeedManager? = nil
    ) {
        self.senderNickname = senderNickname
        self.topContentInset = topContentInset
        self.usesOverlayChrome = usesOverlayChrome
        self.onSelectPlace = onSelectPlace
        self.onExplorePlaces = onExplorePlaces
        self.onOpenProfileSheet = onOpenProfileSheet
        self.feedManager = feedManager ?? .shared
    }

    private var visibleItems: [HomeFeedItem] {
        feedManager.filteredItems(scope: scope, sort: sort, filter: filter)
    }

    private var hasAnySources: Bool {
        !locationChannelsModel.bookmarks.isEmpty
            || !followsStore.allFollowedPubkeys.isEmpty
            || profileStore.isPublicHandleEnabled
    }

    private var maxDraftLines: Int {
        dynamicTypeSize.isAccessibilitySize ? 5 : 3
    }

    private var sendEnabled: Bool {
        let trimmed = draft.trimmed
        return profileStore.isPublicHandleEnabled
            && !trimmed.isEmpty
            && trimmed.utf8.count <= BoardWireConstants.contentMaxBytes
            && !feedManager.isSending
    }

    var body: some View {
        contentLayout
            .onAppear {
                feedManager.activate(
                    bookmarks: locationChannelsModel.bookmarks,
                    followedPubkeys: followsStore.allFollowedPubkeys
                )
            }
            .onChange(of: locationChannelsModel.bookmarks) { bookmarks in
                feedManager.updateSources(
                    bookmarks: bookmarks,
                    followedPubkeys: followsStore.allFollowedPubkeys
                )
            }
            .onChange(of: followsStore.allFollowedPubkeys) { follows in
                feedManager.updateSources(
                    bookmarks: locationChannelsModel.bookmarks,
                    followedPubkeys: follows
                )
            }
            .onDisappear {
                if feedManager === HomeFeedManager.shared {
                    feedManager.deactivate()
                }
            }
            .sheet(item: $selectedThread) { selection in
                PlaceThreadSheet(
                    rootNote: selection.note,
                    geohash: selection.geohash,
                    senderNickname: senderNickname,
                    isTeleported: false,
                    manager: selection.manager
                )
            }
    }

    @ViewBuilder
    private var contentLayout: some View {
        if usesOverlayChrome {
            if #available(iOS 17.0, macOS 14.0, *) {
                scrollList
                    .contentMargins(.top, topContentInset, for: .scrollContent)
                    .contentMargins(.top, topContentInset, for: .scrollIndicators)
                    .contentMargins(.bottom, max(bottomComposerHeight, 84), for: .scrollContent)
                    .contentMargins(.bottom, max(bottomComposerHeight, 84), for: .scrollIndicators)
                    .overlay(alignment: .bottom) {
                        composerBar
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(key: HomeComposerHeightKey.self, value: proxy.size.height)
                                }
                            )
                    }
                    .onPreferenceChange(HomeComposerHeightKey.self) { height in
                        if abs(bottomComposerHeight - height) > 0.5 {
                            bottomComposerHeight = height
                        }
                    }
            } else {
                scrollList
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        composerBar
                    }
            }
        } else {
            VStack(spacing: 0) {
                scrollList
                composerBar
            }
        }
    }

    private var scrollList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                scopeAndFilterBar

                if feedManager.isLoadingFollowing && visibleItems.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(String(localized: "location_notes.loading_notes"))
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }

                if let error = feedManager.errorMessage {
                    ThemedCard {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(palette.alertRed)
                            Text(error)
                                .bitchatFont(size: 12)
                                .foregroundColor(palette.primary)
                            Spacer()
                        }
                        Button(String(localized: "location_notes.action.dismiss")) {
                            feedManager.clearError()
                        }
                        .bitchatFont(size: 12, weight: .semibold)
                        .foregroundColor(palette.accent)
                        .buttonStyle(.plain)
                    }
                }

                if visibleItems.isEmpty {
                    emptyStateCard
                } else {
                    ForEach(visibleItems) { item in
                        let placeLabel = item.savedPlaceGeohash.map { gh -> String in
                            if let name = locationChannelsModel.bookmarkNames[gh]?.trimmedOrNilIfEmpty {
                                return "\(name) · #\(gh)"
                            }
                            return "#\(gh)"
                        }
                        let isOwn = feedManager.isOwn(item)
                        let authorHex = item.note.pubkey
                        PlaceFeedPostCard(
                            item: item.noticeItem,
                            isOwn: isOwn,
                            replyCount: feedManager.replyCount(for: item),
                            reactions: feedManager.reactions(for: item),
                            placeBadgeLabel: placeLabel,
                            isFollowingAuthor: followsStore.isFollowing(authorHex),
                            onTapPlace: item.savedPlaceGeohash.map { gh in
                                {
                                    onSelectPlace(gh, locationChannelsModel.bookmarkNames[gh])
                                }
                            },
                            onToggleFollow: isOwn ? nil : {
                                let alias = profileStore.displayName(
                                    for: authorHex,
                                    fallbackNickname: item.note.nickname
                                )
                                followsStore.toggleFollow(authorHex, alias: alias)
                            },
                            onOpenThread: {
                                if let gh = item.savedPlaceGeohash,
                                   let manager = feedManager.manager(forGeohash: gh) {
                                    selectedThread = ThreadSelection(
                                        note: item.note,
                                        geohash: gh,
                                        manager: manager
                                    )
                                }
                            },
                            onToggleReaction: { emoji in
                                feedManager.toggleReaction(emoji: emoji, on: item)
                            },
                            onDelete: {
                                feedManager.delete(item)
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
            feedManager.refresh()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemedRootBackground())
    }

    private var scopeAndFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(HomeFeedScope.allCases) { option in
                    let isSelected = scope == option
                    Button {
                        scope = option
                    } label: {
                        Text(scopeTitle(option))
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

                ForEach(PlaceFeedSort.allCases) { option in
                    let isSelected = sort == option
                    Button {
                        sort = option
                    } label: {
                        Text(
                            option == .latest
                                ? String(localized: "place_feed.sort.latest", defaultValue: "Latest", comment: "Sort option showing newest posts first")
                                : String(localized: "place_feed.sort.top", defaultValue: "Top", comment: "Sort option ranking posts by engagement")
                        )
                        .bitchatFont(size: 12, weight: isSelected ? .semibold : .medium)
                        .padding(.horizontal, 9)
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

                Button {
                    filter = (filter == .vouched) ? .all : .vouched
                } label: {
                    let isSelected = filter == .vouched
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(String(localized: "place_feed.filter.vouched", defaultValue: "Vouched", comment: "Filter option showing posts from in-person verified or vouched authors"))
                            .bitchatFont(size: 12, weight: isSelected ? .semibold : .medium)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(isSelected ? palette.locationAccent.opacity(0.18) : palette.cardBackground)
                    .foregroundColor(isSelected ? palette.locationAccent : palette.secondary)
                    .overlay(
                        Capsule().stroke(isSelected ? palette.locationAccent.opacity(0.45) : palette.cardBorder, lineWidth: 1)
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                if locationChannelsModel.userTorEnabled {
                    HStack(spacing: 3) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 10, weight: .semibold))
                        Text(String(localized: "place_feed.badge.tor", defaultValue: "Tor", comment: "Tor indicator badge"))
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

    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            Image(systemName: hasAnySources ? "text.bubble" : "globe.americas.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(palette.secondary)
                .frame(width: 52, height: 52)
                .background(palette.cardBackground)
                .clipShape(Circle())

            Text(
                hasAnySources
                    ? String(localized: "home_feed.empty.quiet_title", defaultValue: "Quiet across your feed", comment: "Empty state title when Saved Places and Following have no posts yet")
                    : String(localized: "home_feed.empty.setup_title", defaultValue: "Build your spatial feed", comment: "Empty state title when user has no Saved Places or Following accounts")
            )
            .bitchatFont(size: 15, weight: .semibold)
            .foregroundColor(palette.primary)

            Text(
                hasAnySources
                    ? String(localized: "home_feed.empty.quiet_subtitle", defaultValue: "Posts from your saved places and followed accounts will appear here.", comment: "Empty state subtitle when feed has sources but no posts yet")
                    : String(localized: "home_feed.empty.setup_subtitle", defaultValue: "Bookmark places on the globe or follow people privately by npub to build a unified timeline.", comment: "Empty state subtitle explaining how to populate Home Feed")
            )
            .bitchatFont(size: 13)
            .foregroundColor(palette.secondary)
            .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Button(action: onExplorePlaces) {
                    Text(String(localized: "home_feed.action.explore_places", defaultValue: "Explore Places", comment: "Button switching to Places directory"))
                        .bitchatFont(size: 13, weight: .semibold)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(palette.accent)
                        .foregroundColor(palette.accentForeground)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onOpenProfileSheet) {
                    Text(String(localized: "home_feed.action.manage_following", defaultValue: "Following & Handle", comment: "Button opening Public Handle and Following sheet"))
                        .bitchatFont(size: 13, weight: .semibold)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(palette.cardBackground)
                        .foregroundColor(palette.primary)
                        .overlay(Capsule().stroke(palette.cardBorder, lineWidth: 1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var composerBar: some View {
        if profileStore.isPublicHandleEnabled {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button(action: onOpenProfileSheet) {
                        HStack(spacing: 4) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(palette.accent)
                            let handle = profileStore.ownProfile.displayName.trimmedOrNilIfEmpty ?? senderNickname
                            Text(
                                String(
                                    format: String(localized: "place_feed.composer.posting_as", defaultValue: "Posting as %@", comment: "Label showing active posting identity"),
                                    locale: .current,
                                    "@\(handle)"
                                )
                            )
                            .bitchatFont(size: 11, weight: .medium)
                            .foregroundColor(palette.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 12)

                HStack(alignment: .bottom, spacing: 8) {
                    TextField(
                        String(localized: "home_feed.composer.placeholder", defaultValue: "Post to your followers…", comment: "Placeholder for global Home Feed post composer"),
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

                    Button(action: submitGlobalPost) {
                        if feedManager.isSending {
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
                    .accessibilityLabel(String(localized: "place_feed.action.post", defaultValue: "Post", comment: "Submit post button"))
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .padding(.top, 8)
            .themedChromePanel(edge: .bottom)
        } else {
            Button(action: onOpenProfileSheet) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(palette.accent)
                    Text(String(localized: "home_feed.composer.enable_handle_cta", defaultValue: "Enable Public Handle to post globally", comment: "CTA bar shown in Home Feed when user has not opted into a persistent public handle"))
                        .bitchatFont(size: 13, weight: .medium)
                        .foregroundColor(palette.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(palette.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .themedChromePanel(edge: .bottom)
        }
    }

    private func submitGlobalPost() {
        guard let content = draft.trimmedOrNilIfEmpty else { return }
        let handle = profileStore.ownProfile.displayName.trimmedOrNilIfEmpty ?? senderNickname
        feedManager.sendGlobalPost(content: content, nickname: handle)
        draft = ""
    }

    private func scopeTitle(_ option: HomeFeedScope) -> String {
        switch option {
        case .all:
            return String(localized: "place_feed.filter.all", defaultValue: "All", comment: "Show all feed items")
        case .savedPlaces:
            return String(localized: "home_feed.scope.saved_places", defaultValue: "Saved Places", comment: "Scope pill filtering Home Feed to bookmarked places")
        case .following:
            return String(localized: "home_feed.scope.following", defaultValue: "Following", comment: "Scope pill filtering Home Feed to followed accounts")
        }
    }
}

private struct HomeComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
