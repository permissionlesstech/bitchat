//
// RecentChatPreview.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Builds the one-line snippet shown under a name in the "chats" section.
///
/// Media messages carry their payload as `"[image] <filename>"` — the marker
/// is part of the message content, not decoration added by the view (see
/// `MimeType.Category.messagePrefix` and `BitchatMessage.mediaAttachment`).
/// Rendering that content verbatim in a list row would put an opaque
/// on-disk filename in front of the reader, which says nothing about the
/// conversation. Keeping the marker and dropping the filename is what makes
/// the row readable, and it matches how the thread itself presents the
/// message.
///
/// Framework-free on purpose: this is the part of the row with rules worth
/// pinning, and it stays testable without a view or a view model.
enum RecentChatPreview {
    /// Long enough to distinguish two conversations at a glance, short
    /// enough that the row never wraps at the narrowest sheet width.
    static let maxLength = 80

    /// A snippet for `content`, or nil when there is nothing worth showing.
    ///
    /// Nil rather than empty string: an absent preview and a preview of ""
    /// are different states, and the caller decides whether to reserve the
    /// line. Whitespace-only content is treated as absent, since a row of
    /// blank space reads as a rendering bug.
    static func snippet(for content: String) -> String? {
        if let marker = mediaMarker(for: content) {
            return marker
        }

        // Newlines and runs of spaces would otherwise render as a ragged gap
        // mid-row; a multi-line message has to become one line to fit at all.
        let collapsed = content
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return truncated(collapsed)
    }

    /// The bare marker for a media message (`[image]`, `[voice]`, `[file]`),
    /// or nil when the content is not media.
    ///
    /// Matched against the shared `messagePrefix` rather than a literal, so
    /// adding a category cannot leave this behind still emitting a filename.
    static func mediaMarker(for content: String) -> String? {
        for category in mediaCategories {
            let prefix = category.messagePrefix
            guard content.hasPrefix(prefix) else { continue }
            // `messagePrefix` ends with a space; the marker is what precedes
            // it. A prefix with no filename after it is still that kind of
            // message, so this does not require a non-empty remainder.
            return String(prefix.dropLast())
        }
        return nil
    }

    /// Every category `mediaAttachment` can classify, plus `.file`, which it
    /// does not resolve to an attachment but which still arrives as content
    /// with a prefix — and so would otherwise fall through to the text path
    /// and print its filename.
    private static let mediaCategories: [MimeType.Category] = [.audio, .image, .file]

    private static func truncated(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        // Cut on a word boundary when one is close to the limit, so the
        // snippet does not end mid-word for the sake of four characters.
        let hardCut = text.prefix(maxLength)
        let cut: Substring
        if let lastSpace = hardCut.lastIndex(of: " "),
           hardCut.distance(from: lastSpace, to: hardCut.endIndex) < 12 {
            cut = hardCut[hardCut.startIndex..<lastSpace]
        } else {
            cut = hardCut
        }
        return cut + "…"
    }
}
