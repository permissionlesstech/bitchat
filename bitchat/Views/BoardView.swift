//
// BoardView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// The bulletin board for one context: a geohash channel, or the mesh-local
/// board when `geohash` is empty. Urgent posts pin to the top; own posts can
/// be swipe-deleted, which broadcasts a signed tombstone.
struct BoardView: View {
    /// Empty string = mesh-local board.
    let geohash: String
    let senderNickname: String
    @ObservedObject var board: BoardManager

    @ThemedPalette private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""
    @State private var urgent = false
    @State private var expiryDays = 7

    private var maxDraftLines: Int { dynamicTypeSize.isAccessibilitySize ? 5 : 3 }
    private var posts: [BoardPostPacket] { board.posts(forGeohash: geohash) }

    private enum Strings {
        static let boardName = String(localized: "board.title", defaultValue: "board", comment: "Title prefix of the bulletin board sheet")
        static let description = String(localized: "board.description", defaultValue: "persistent notices carried by the mesh. posts are signed, spread device-to-device, and expire on their own.", comment: "Explainer under the board sheet title")
        static let emptyTitle = String(localized: "board.empty_title", defaultValue: "no notices yet", comment: "Title shown when the board has no posts")
        static let emptySubtitle = String(localized: "board.empty_subtitle", defaultValue: "pin the first notice for people around here.", comment: "Subtitle shown when the board has no posts")
        static let urgentBadge = String(localized: "board.urgent_badge", defaultValue: "urgent", comment: "Badge shown on urgent board posts")
        static let urgentToggle = String(localized: "board.compose.urgent", defaultValue: "urgent", comment: "Label for the urgent toggle in the board composer")
        static let placeholder = String(localized: "board.compose.placeholder", defaultValue: "post a notice…", comment: "Placeholder for the board composer text field")
        static let send = String(localized: "board.accessibility.post", defaultValue: "Post notice", comment: "Accessibility label for the board post button")
        static let deleteAction = String(localized: "board.action.delete", defaultValue: "delete", comment: "Delete action for own board posts")
        static let expiryLabel = String(localized: "board.compose.expiry", defaultValue: "expires in", comment: "Label for the board post expiry picker")
        static let closeHint = String(localized: "board.accessibility.close", defaultValue: "Close board", comment: "Accessibility label for the board close button")

        static func expiryDaysOption(_ days: Int) -> String {
            String(
                format: String(localized: "board.compose.expiry_days", defaultValue: "%lldd", comment: "Expiry picker option, number of days abbreviated"),
                locale: .current,
                days
            )
        }

        static func postAccessibilityLabel(author: String, content: String, urgent: Bool) -> String {
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
            postList
            composer
        }
        .themedSurface()
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 440, minHeight: 620, idealHeight: 680)
        #endif
        .themedSheetBackground()
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(verbatim: geohash.isEmpty ? "\(Strings.boardName) @ #mesh" : "\(Strings.boardName) @ #\(geohash)")
                    .bitchatFont(size: 18)
                Spacer()
                SheetCloseButton { dismiss() }
                    .accessibilityLabel(Strings.closeHint)
            }
            Text(Strings.description)
                .bitchatFont(size: 12)
                .foregroundColor(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .themedSurface()
    }

    private var postList: some View {
        Group {
            if posts.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Strings.emptyTitle)
                            .bitchatFont(size: 13, weight: .semibold)
                        Text(Strings.emptySubtitle)
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            } else {
                List {
                    ForEach(posts, id: \.postID) { post in
                        postRow(post)
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

    private func postRow(_ post: BoardPostPacket) -> some View {
        let isOwn = board.isOwnPost(post)
        let author = post.authorNickname.trimmedOrNilIfEmpty ?? "anon"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if post.isUrgent {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.bitchatSystem(size: 11))
                        .foregroundColor(palette.alertRed)
                    Text(Strings.urgentBadge)
                        .bitchatFont(size: 11, weight: .semibold)
                        .foregroundColor(palette.alertRed)
                }
                Text(verbatim: "@\(author)")
                    .bitchatFont(size: 12, weight: .semibold)
                Text(timestampText(forMs: post.createdAt))
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.secondary)
                Spacer()
                if isOwn {
                    Button {
                        board.deletePost(post)
                    } label: {
                        Image(systemName: "trash")
                            .font(.bitchatSystem(size: 12))
                            .foregroundColor(palette.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Strings.deleteAction)
                }
            }
            Text(post.content)
                .bitchatFont(size: 14)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.postAccessibilityLabel(author: author, content: post.content, urgent: post.isUrgent))
        .accessibilityActions {
            if isOwn {
                Button(Strings.deleteAction) { board.deletePost(post) }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isOwn {
                Button(role: .destructive) {
                    board.deletePost(post)
                } label: {
                    Label(Strings.deleteAction, systemImage: "trash")
                }
            }
        }
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
        guard let content = draft.trimmedOrNilIfEmpty else { return }
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

    private func timestampText(forMs ms: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let now = Date()
        if let days = Calendar.current.dateComponents([.day], from: date, to: now).day, days < 7 {
            let rel = Self.relativeFormatter.string(from: date, to: now) ?? ""
            return rel.isEmpty ? "" : "\(rel) ago"
        }
        return Self.absDateFormatter.string(from: date)
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
}
