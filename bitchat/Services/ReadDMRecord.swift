//
// ReadDMRecord.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// DMs this device has read, kept across launches so a DM that a Nostr
/// lookback delivers again is not marked unread. Message IDs only, capped,
/// oldest dropped first.
struct ReadDMRecord {
    static let defaultsKey = "readDMIDs"
    static let defaultCap = 2_000

    private let defaults: UserDefaults
    private let cap: Int
    private var ordered: [String]
    private var members: Set<String>

    init(defaults: UserDefaults, cap: Int = ReadDMRecord.defaultCap) {
        self.defaults = defaults
        self.cap = cap
        let stored = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        ordered = Array(stored.suffix(cap))
        members = Set(ordered)
    }

    func contains(_ messageID: String) -> Bool {
        members.contains(messageID)
    }

    mutating func record(_ messageID: String) {
        guard members.insert(messageID).inserted else { return }
        ordered.append(messageID)
        if ordered.count > cap {
            members.remove(ordered.removeFirst())
        }
        save()
    }

    mutating func removeAll() {
        ordered.removeAll()
        members.removeAll()
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(ordered) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
