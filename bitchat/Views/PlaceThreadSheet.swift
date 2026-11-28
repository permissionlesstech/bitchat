//
// PlaceThreadSheet.swift
// bitchat
//
// Thread sheet for a Place Feed kind-1 root post, displaying chronological
// NIP-10 replies, NIP-25 emoji reactions, and a NIP-13 PoW-mined reply composer.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct PlaceThreadSheet: View {
    let rootNote: LocationNotesManager.Note
    let geohash: String
    let senderNickname: String
    let isTeleported: Bool
    @ObservedObject var manager: LocationNotesManager

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ThemedPalette private var palette

    @State private var replyDraft = ""
    /// Optional nested reply target inside the thread (nil replies directly to rootNote).
    @State private var replyTarget: LocationNotesManager.Note?

    private var replies: [LocationNotesManager.Note] {
        manager.replies(forRootID: rootNote.id)
    }

    private var maxDraftLines: Int {
        dynamicTypeSize.isAccessibilitySize ? 5 : 3
    }

    private var sendEnabled: Bool {
        let trimmed = replyDraft.trimmed
        return !trimmed.isEmpty && trimmed.utf8.count <= BoardWireConstants.contentMaxBytes && !manager.isSending
    }

    private var replyCountHeader: String {
        if replies.count == 1 {
            return String(localized: "place_feed.thread.replies_one", defaultValue: "1 reply", comment: "Header count when a Place Feed thread has 1 reply")
        }
        return String(
            format: String(localized: "place_feed.thread.replies_many", defaultValue: "%lld replies", comment: "Header count when a Place Feed thread has multiple replies"),
            locale: .current,
            replies.count
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ThemedSheetHeader(
                title: String(localized: "place_feed.thread.title", defaultValue: "Thread", comment: "Title of the Place Feed thread sheet"),
                subtitle: "#\(geohash)",
                onClose: { dismiss() }
            )

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Root post card
                    PlaceFeedPostCard(
                        item: NoticeItem(note: rootNote),
                        isOwn: manager.isOwnNote(rootNote),
                        replyCount: replies.count,
                        reactions: manager.reactions(forNoteID: rootNote.id),
                        onOpenThread: { replyTarget = nil },
                        onToggleReaction: { emoji in
                            manager.toggleReaction(emoji: emoji, on: rootNote)
                        },
                        onDelete: {
                            if manager.delete(note: rootNote) {
                                dismiss()
                            }
                        }
                    )

                    // Section divider / reply count
                    if !replies.isEmpty {
                        ThemedSectionLabel(text: replyCountHeader.uppercased())
                            .padding(.horizontal, 4)
                            .padding(.top, 2)

                        ForEach(replies) { reply in
                            replyRow(reply)
                        }
                    } else {
                        Text(String(localized: "place_feed.thread.no_replies", defaultValue: "No replies yet — start the conversation.", comment: "Empty state inside a Place Feed thread with zero replies"))
                            .bitchatFont(size: 13)
                            .foregroundColor(palette.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 28)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            composer
        }
        .themedSurface()
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 560, idealHeight: 660)
        #endif
        .themedSheetBackground()
    }

    private func replyRow(_ reply: LocationNotesManager.Note) -> some View {
        let isOwn = manager.isOwnNote(reply)
        let authorColor = isOwn
            ? PeerColorContrast.selfColor(isDark: colorScheme == .dark)
            : Color(peerSeed: reply.pubkey, isDark: colorScheme == .dark)
        let reactions = manager.reactions(forNoteID: reply.id)
        let parentReply = reply.replyToEventID.flatMap { parentID in
            replies.first(where: { $0.id == parentID })
        }

        return HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(palette.divider)
                .frame(width: 2)
                .padding(.leading, 8)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(verbatim: "@\(reply.shortAuthorName)")
                        .bitchatFont(size: 13, weight: .semibold)
                        .foregroundColor(authorColor)
                        .lineLimit(1)
                    Text(verbatim: "#\(reply.authorSuffix)")
                        .bitchatFont(size: 11)
                        .foregroundColor(palette.secondary)
                        .lineLimit(1)
                    Text(verbatim: "·")
                        .bitchatFont(size: 11)
                        .foregroundColor(palette.secondary)
                    Text(PlaceFeedTimestamp.text(for: reply.createdAt))
                        .bitchatFont(size: 11)
                        .foregroundColor(palette.secondary)
                        .lineLimit(1)
                    if reply.isTeleported {
                        Image(systemName: "globe")
                            .font(.system(size: 10))
                            .foregroundColor(palette.accentBlue)
                    }
                    if reply.hasVerifiedPoW {
                        Image(systemName: "bolt.shield.fill")
                            .font(.system(size: 10))
                            .foregroundColor(palette.secondary)
                    }
                    Spacer(minLength: 4)
                    if isOwn {
                        Button {
                            manager.delete(note: reply)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(palette.secondary)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "board.action.delete", defaultValue: "delete", comment: "Delete own reply"))
                    }
                }

                if let parentReply {
                    Text(
                        String(
                            format: String(localized: "place_feed.composer.replying_to", defaultValue: "Replying to @%@", comment: "Indicator showing which author a nested reply targets"),
                            locale: .current,
                            parentReply.shortAuthorName
                        )
                    )
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.accent)
                }

                Text(reply.content)
                    .bitchatFont(size: 14)
                    .foregroundColor(palette.primary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Button {
                        replyTarget = reply
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrowshape.turn.up.left")
                                .font(.system(size: 11, weight: .medium))
                            Text(String(localized: "place_feed.action.reply", defaultValue: "Reply", comment: "Reply to a comment in a thread"))
                                .bitchatFont(size: 11, weight: .medium)
                        }
                        .foregroundColor(palette.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(palette.secondary.opacity(0.08))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    ForEach(reactions) { reaction in
                        Button {
                            manager.toggleReaction(emoji: reaction.emoji, on: reply)
                        } label: {
                            HStack(spacing: 3) {
                                Text(verbatim: reaction.emoji)
                                    .font(.system(size: 11))
                                Text(verbatim: "\(reaction.count)")
                                    .bitchatFont(size: 11, weight: .semibold)
                            }
                            .foregroundColor(reaction.includesCurrentUser ? palette.accent : palette.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                reaction.includesCurrentUser
                                    ? palette.accent.opacity(0.16)
                                    : palette.secondary.opacity(0.08)
                            )
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Menu {
                        ForEach(MessageInteractionCodec.quickReactionPalette, id: \.self) { emoji in
                            Button {
                                manager.toggleReaction(emoji: emoji, on: reply)
                            } label: {
                                Text(verbatim: emoji)
                            }
                        }
                    } label: {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(palette.secondary)
                            .frame(width: 24, height: 22)
                            .background(palette.secondary.opacity(0.08))
                            .clipShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .accessibilityLabel(String(localized: "place_feed.action.react", defaultValue: "React", comment: "React to a thread reply"))

                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: palette.cardRadius, style: .continuous)
                    .stroke(palette.cardBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: palette.cardRadius, style: .continuous))
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let target = replyTarget {
                HStack(spacing: 6) {
                    Text(
                        String(
                            format: String(localized: "place_feed.composer.replying_to", defaultValue: "Replying to @%@", comment: "Indicator showing which author a nested reply targets"),
                            locale: .current,
                            target.shortAuthorName
                        )
                    )
                    .bitchatFont(size: 11, weight: .medium)
                    .foregroundColor(palette.accent)
                    Spacer()
                    Button {
                        replyTarget = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(palette.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "common.cancel", defaultValue: "Cancel", comment: "Clear nested reply target"))
                }
                .padding(.horizontal, 12)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    String(localized: "place_feed.composer.reply_placeholder", defaultValue: "Write a reply…", comment: "Placeholder text for the Place Feed thread reply composer"),
                    text: $replyDraft,
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

                Button(action: submitReply) {
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
                .accessibilityLabel(String(localized: "place_feed.action.reply", defaultValue: "Reply", comment: "Submit reply button"))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .padding(.top, 8)
        .themedChromePanel(edge: .bottom)
    }

    private func submitReply() {
        guard let content = replyDraft.trimmedOrNilIfEmpty else { return }
        let target = replyTarget ?? rootNote
        let reference = NostrProtocol.ThreadReference(
            rootEventID: rootNote.id,
            replyEventID: target.id == rootNote.id ? nil : target.id,
            replyAuthorPubkey: target.pubkey
        )
        manager.sendFeedPost(
            content: content,
            nickname: senderNickname,
            expiresAt: nil,
            urgent: false,
            teleported: isTeleported,
            replyTo: reference
        )
        replyDraft = ""
        replyTarget = nil
    }
}
