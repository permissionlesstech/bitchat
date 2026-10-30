//
// GroupListStore.swift
// bitchat
//
// Persistence for each group's shared checklist, as protected JSON next to
// the group metadata. Owned by `GroupStore`, so leaving a group or the panic
// wipe drops its list along with its key.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Combine
import Foundation

@MainActor
final class GroupListStore: ObservableObject {
    @Published private(set) var lists: [Data: GroupList] = [:]

    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        loadFromDisk()
    }

    func list(forGroupID groupID: Data) -> GroupList {
        lists[groupID] ?? GroupList()
    }

    /// Joins a received delta into the group's list. Returns whether any row
    /// changed, so callers only announce real edits.
    @discardableResult
    func merge(_ delta: GroupListDelta, intoGroupID groupID: Data) -> Bool {
        var list = list(forGroupID: groupID)
        guard list.merge(delta) else { return false }
        lists[groupID] = list
        persist()
        return true
    }

    /// Runs a local edit against the group's list and keeps the result when
    /// it produced a delta to broadcast.
    func edit(groupID: Data, _ change: (inout GroupList) -> GroupListDelta?) -> GroupListDelta? {
        var list = list(forGroupID: groupID)
        guard let delta = change(&list) else { return nil }
        lists[groupID] = list
        persist()
        return delta
    }

    func remove(groupID: Data) {
        guard lists.removeValue(forKey: groupID) != nil else { return }
        persist()
    }

    /// Drops lists for groups that are no longer held (e.g. a group whose
    /// key did not survive in the keychain).
    func prune(keeping groupIDs: Set<Data>) {
        let before = lists.count
        lists = lists.filter { groupIDs.contains($0.key) }
        if lists.count != before { persist() }
    }

    func wipe() {
        lists.removeAll()
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Internals

    private func persist() {
        guard let fileURL else { return }
        do {
            if lists.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(lists)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtection)
            #endif
            try data.write(to: fileURL, options: options)
        } catch {
            SecureLogger.error("Failed to persist group lists: \(error)", category: .session)
        }
    }

    private func loadFromDisk() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([Data: GroupList].self, from: data) else {
            return
        }
        lists = stored.filter { $0.key.count == BitchatGroup.groupIDLength }
    }
}
