//
// BitchatMessage+Media.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

extension BitchatMessage {
    enum Media {
        case voice(URL)
        case image(URL)
    }

    // Cache the directory lookup to avoid repeated FileManager calls during view rendering
    private struct Cache {
        let filesDir: URL?

        static let shared = Cache()
        private init() {
            do {
                let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let filesDir = base.appendingPathComponent("files", isDirectory: true)
                try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true, attributes: BLEIncomingFileStore.mediaProtectionAttributes)
                self.filesDir = filesDir
            } catch {
                filesDir = nil
            }
        }
    }

    func mediaAttachment(for nickname: String) -> Media? {
        // Files only travel over the mesh radio; geochats, geo DMs and
        // bridged messages (internet-relayed from a rendezvous) carry text
        // alone. A "[image] " line from such a sender names no file it sent
        // us, so it stays a text row.
        if let senderPeerID, senderPeerID.isGeoChat || senderPeerID.isGeoDM || senderPeerID.isBridge {
            return nil
        }
        guard let baseDirectory = Cache.shared.filesDir else { return nil }

        func url(for category: MimeType.Category) -> URL? {
            guard content.hasPrefix(category.messagePrefix),
                  let filename = String(content.dropFirst(category.messagePrefix.count)).trimmedOrNilIfEmpty,
                  Self.isSafeMediaFilename(filename)
            else {
                return nil
            }

            // Check outgoing first for sent messages, incoming for received
            let subdir = sender == nickname ? "\(category.mediaDir)/outgoing" : "\(category.mediaDir)/incoming"

            // Construct URL directly without fileExists check (avoids blocking disk I/O in view body)
            // Files are checked during playback/display, so missing files fail gracefully
            let directory = baseDirectory.appendingPathComponent(subdir, isDirectory: true)
            return directory.appendingPathComponent(filename)
        }

        if let url = url(for: .audio) {
            return .voice(url)
        }
        if let url = url(for: .image) {
            return .image(url)
        }
        return nil
    }

    /// Whether a media filename taken from message text is one plain path
    /// component. Anything else ("../outgoing/x.jpg", "a/b", "..") would
    /// resolve outside the media directory, so it is rejected, not repaired:
    /// sanitizing would still point the row at some other local file.
    static func isSafeMediaFilename(_ filename: String) -> Bool {
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.unicodeScalars.contains(where: { $0 == "/" || $0 == "\\" })
        else {
            return false
        }
        return (filename as NSString).lastPathComponent == filename
    }
}
