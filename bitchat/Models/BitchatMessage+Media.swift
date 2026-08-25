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
        case file(URL)
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
        guard let baseDirectory = Cache.shared.filesDir else { return nil }

        func url(for category: MimeType.Category) -> URL? {
            // Real transfers write `messagePrefix + lastPathComponent`. A
            // spoofed text bubble can still carry `[file] ../prekeys/…`;
            // ShareLink would then export whatever that path resolves to.
            guard content.hasPrefix(category.messagePrefix),
                  let rawFilename = String(content.dropFirst(category.messagePrefix.count)).trimmedOrNilIfEmpty,
                  let filename = (rawFilename as NSString).lastPathComponent.nilIfEmpty,
                  filename == rawFilename,
                  filename != ".",
                  filename != ".."
            else {
                return nil
            }

            let subdir = sender == nickname ? "\(category.mediaDir)/outgoing" : "\(category.mediaDir)/incoming"
            let directory = baseDirectory
                .appendingPathComponent(subdir, isDirectory: true)
                .standardizedFileURL
            let candidate = directory.appendingPathComponent(filename).standardizedFileURL
            guard candidate.deletingLastPathComponent().path == directory.path else {
                return nil
            }
            return candidate
        }

        if let url = url(for: .audio) {
            return .voice(url)
        }
        if let url = url(for: .image) {
            return .image(url)
        }
        if let url = url(for: .file) {
            return .file(url)
        }
        return nil
    }
}
