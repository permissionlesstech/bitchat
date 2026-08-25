import Testing
import Foundation
import BitFoundation
@testable import bitchat

struct BitchatMessageMediaTests {
    @Test func mediaAttachment_resolvesIncomingFileTransfers() {
        let message = BitchatMessage(
            sender: "alice",
            content: "[file] notes.pdf",
            timestamp: Date(),
            isRelay: false
        )

        guard case .file(let url) = message.mediaAttachment(for: "bob") else {
            Issue.record("expected a file attachment")
            return
        }
        #expect(url.lastPathComponent == "notes.pdf")
        #expect(url.path.contains("files/incoming"))
    }

    @Test func mediaAttachment_resolvesOutgoingFileTransfers() {
        let message = BitchatMessage(
            sender: "bob",
            content: "[file] notes.pdf",
            timestamp: Date(),
            isRelay: false
        )

        guard case .file(let url) = message.mediaAttachment(for: "bob") else {
            Issue.record("expected a file attachment")
            return
        }
        #expect(url.path.contains("files/outgoing"))
    }

    @Test func mediaAttachment_doesNotTreatFilePrefixAsImage() {
        let message = BitchatMessage(
            sender: "alice",
            content: "[file] notes.pdf",
            timestamp: Date(),
            isRelay: false
        )
        if case .image = message.mediaAttachment(for: "bob") {
            Issue.record("file transfers must not render as images")
        }
    }

    @Test func mediaAttachment_rejectsPathTraversalInFileName() {
        let traversal = BitchatMessage(
            sender: "alice",
            content: "[file] ../../../prekeys/bundles.json",
            timestamp: Date(),
            isRelay: false
        )
        if traversal.mediaAttachment(for: "bob") != nil {
            Issue.record("traversal names must not become file attachments")
        }

        let parent = BitchatMessage(
            sender: "alice",
            content: "[file] ..",
            timestamp: Date(),
            isRelay: false
        )
        if parent.mediaAttachment(for: "bob") != nil {
            Issue.record("parent directory names must not become file attachments")
        }
    }
}
