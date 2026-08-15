import BitFoundation
import Foundation
import Testing

@testable import bitchat

struct RecentChatPreviewTests {
    // MARK: - Media

    @Test
    func mediaPreviewsKeepTheMarkerAndDropTheFilename() {
        // The filename is an on-disk identifier the reader has never seen and
        // cannot act on. Showing it is the failure this exists to prevent.
        #expect(RecentChatPreview.snippet(for: "[image] 9F2A7C41-B0E3.jpg") == "[image]")
        #expect(RecentChatPreview.snippet(for: "[voice] 2026-08-15T09-12-44.m4a") == "[voice]")
        #expect(RecentChatPreview.snippet(for: "[file] quarterly-report.pdf") == "[file]")
    }

    @Test
    func aMediaPrefixWithNoFilenameIsStillThatKindOfMessage() {
        // Trailing space, nothing after it. Still media, not a text message
        // that happens to start with a bracket.
        #expect(RecentChatPreview.snippet(for: "[image] ") == "[image]")
    }

    @Test
    func everyMediaCategoryIsRecognisedFromItsSharedPrefix() {
        // Pinned against `MimeType.Category` itself rather than three
        // literals, so adding a category and forgetting this list fails here
        // instead of silently printing a filename in the sheet.
        for category in [MimeType.Category.audio, .image, .file] {
            let content = category.messagePrefix + "payload.bin"
            let expected = String(category.messagePrefix.dropLast())
            #expect(RecentChatPreview.snippet(for: content) == expected)
        }
    }

    @Test
    func textThatMerelyMentionsAMarkerIsNotTreatedAsMedia() {
        // Only a genuine prefix counts; the marker mid-sentence is just text.
        #expect(RecentChatPreview.snippet(for: "did you get the [image] i sent?")
            == "did you get the [image] i sent?")
        // No trailing space means it is not the media content format.
        #expect(RecentChatPreview.snippet(for: "[image]") == "[image]")
    }

    // MARK: - Text

    @Test
    func multiLineMessagesCollapseToASingleLine() {
        let content = "first line\n\nsecond line\t  third"
        #expect(RecentChatPreview.snippet(for: content) == "first line second line third")
    }

    @Test
    func whitespaceOnlyContentHasNoPreview() {
        #expect(RecentChatPreview.snippet(for: "") == nil)
        #expect(RecentChatPreview.snippet(for: "   \n\t  ") == nil)
    }

    @Test
    func longTextIsTruncatedWithAnEllipsis() throws {
        let content = String(repeating: "a", count: 200)
        let snippet = try #require(RecentChatPreview.snippet(for: content))

        #expect(snippet.hasSuffix("…"))
        // The ellipsis replaces content rather than extending past the bound.
        #expect(snippet.count <= RecentChatPreview.maxLength + 1)
    }

    @Test
    func truncationPrefersAWordBoundaryWhenOneIsNear() throws {
        // "…of the sentence" would otherwise be cut mid-word for the sake of
        // a few characters.
        let content = String(repeating: "word ", count: 30) + "final"
        let snippet = try #require(RecentChatPreview.snippet(for: content))

        #expect(snippet.hasSuffix("…"))
        let body = snippet.dropLast()
        #expect(!body.hasSuffix(" "))
        // Cutting on the boundary must not strand a partial "wor".
        #expect(body.split(separator: " ").allSatisfy { $0 == "word" })
    }

    @Test
    func textAtExactlyTheLimitIsNotTruncated() throws {
        let content = String(repeating: "b", count: RecentChatPreview.maxLength)
        let snippet = try #require(RecentChatPreview.snippet(for: content))

        #expect(snippet == content)
        #expect(!snippet.hasSuffix("…"))
    }

    @Test
    func aWordBoundaryFarFromTheLimitIsNotUsed() throws {
        // One short word then a very long token: cutting back to the boundary
        // would throw away almost the whole snippet, so the hard cut wins.
        let content = "hi " + String(repeating: "c", count: 200)
        let snippet = try #require(RecentChatPreview.snippet(for: content))

        #expect(snippet.hasSuffix("c…"))
    }
}
