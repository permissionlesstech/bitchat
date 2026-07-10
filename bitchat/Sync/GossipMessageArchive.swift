//
// GossipMessageArchive.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

/// Disk persistence for the gossip-sync public message store, so the recent
/// public history a device carries survives app restarts. This is what lets
/// a phone act as a town crier: walk between two mesh partitions (or relaunch
/// hours later) and sync the room's backlog to whoever missed it.
///
/// Contents are signed public broadcasts — already visible to anyone in radio
/// range — so file protection (no additional sealing) is the right at-rest
/// posture. Wiped on panic.
final class GossipMessageArchive {
    private let fileURL: URL?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    /// Raw binary packets, decoded and freshness-filtered by the caller.
    func load() -> [Data] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let packets = try? JSONDecoder().decode([Data].self, from: data) else {
            return []
        }
        return packets
    }

    func save(_ packets: [Data]) {
        guard let fileURL else { return }
        guard !packets.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(packets)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtection)
            #endif
            try data.write(to: fileURL, options: options)
        } catch {
            SecureLogger.error("Failed to persist gossip archive: \(error)", category: .sync)
        }
    }

    func wipe() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Panic-wipe hook for callers that don't hold the live instance.
    static func wipeDefault() {
        GossipMessageArchive().wipe()
    }

    private static func defaultFileURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return base
            .appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent("public-messages.json")
    }
}
