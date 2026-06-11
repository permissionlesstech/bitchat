import SwiftUI

struct LocationNotesView: View {
    @StateObject private var manager: LocationNotesManager
    let geohash: String
    let senderNickname: String
    let onNotesCountChanged: ((Int) -> Void)?

    @ThemedPalette private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    init(
        geohash: String,
        senderNickname: String,
        onNotesCountChanged: ((Int) -> Void)? = nil,
        manager: LocationNotesManager? = nil
    ) {
        let gh = geohash.lowercased()
        self.geohash = gh
        self.senderNickname = senderNickname
        self.onNotesCountChanged = onNotesCountChanged
        _manager = StateObject(wrappedValue: manager ?? LocationNotesManager(geohash: gh))
    }

    private var backgroundColor: Color { palette.background }
    private var accentGreen: Color { palette.accent }
    private var maxDraftLines: Int { dynamicTypeSize.isAccessibilitySize ? 5 : 3 }

    private enum Strings {
        static let closeAccessibility = String(localized: "common.close", comment: "Accessibility label for close buttons")
        static let description: LocalizedStringKey = "location_notes.description"
        static let loadingRecent: LocalizedStringKey = "location_notes.loading_recent"
        static let relaysPaused: LocalizedStringKey = "location_notes.relays_paused"
        static let noRelaysNearby: LocalizedStringKey = "location_notes.no_relays_nearby"
        static let retry: LocalizedStringKey = "location_notes.action.retry"
        static let relaysRetryHint: LocalizedStringKey = "location_notes.relays_retry_hint"
        static let loadingNotes: LocalizedStringKey = "location_notes.loading_notes"
        static let emptyTitle: LocalizedStringKey = "location_notes.empty_title"
        static let emptySubtitle: LocalizedStringKey = "location_notes.empty_subtitle"
        static let dismissError: LocalizedStringKey = "location_notes.action.dismiss"
        static let addPlaceholder: LocalizedStringKey = "location_notes.placeholder"
    }

    var body: some View {
#if os(macOS)
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    headerSection
                    notesContent
                }
            }
            .themedSurface()
            inputSection
        }
        .frame(minWidth: 420, idealWidth: 440, minHeight: 620, idealHeight: 680)
        .themedSheetBackground()
        .onDisappear { manager.cancel() }
        .onChange(of: geohash) { newValue in
            manager.setGeohash(newValue)
        }
        .onAppear { onNotesCountChanged?(manager.notes.count) }
        .onChange(of: manager.notes.count) { newValue in
            onNotesCountChanged?(newValue)
        }
#else
        NavigationView {
            VStack(spacing: 0) {
                headerSection
                ScrollView {
                    notesContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                inputSection
            }
            .themedSurface()
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            #else
            .navigationTitle("")
            #endif
        }
        .themedSheetBackground()
        .onDisappear { manager.cancel() }
        .onChange(of: geohash) { newValue in
            manager.setGeohash(newValue)
        }
        .onAppear { onNotesCountChanged?(manager.notes.count) }
        .onChange(of: manager.notes.count) { newValue in
            onNotesCountChanged?(newValue)
        }
#endif
    }

    private var closeButton: some View {
        Button(action: { dismiss() }) {
            Image(systemName: "xmark")
                .bitchatFont(size: 13, weight: .semibold)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Strings.closeAccessibility)
    }

    private var headerSection: some View {
        let count = manager.notes.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(headerTitle(for: count))
                    .bitchatFont(size: 18)
                Spacer()
                closeButton
            }
            if let building = locationChannelsModel.locationName(for: .building), !building.isEmpty {
                Text(building)
                    .bitchatFont(size: 12)
                    .foregroundColor(accentGreen)
            } else if let block = locationChannelsModel.locationName(for: .block), !block.isEmpty {
                Text(block)
                    .bitchatFont(size: 12)
                    .foregroundColor(accentGreen)
            }
            Text(Strings.description)
                .bitchatFont(size: 12)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if manager.state == .noRelays {
                Text(Strings.relaysPaused)
                    .bitchatFont(size: 11)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .themedSurface()
    }

    private func headerTitle(for count: Int) -> String {
        String(
            format: String(localized: "location_notes.header", comment: "Header displaying the geohash and localized note count"),
            locale: .current,
            "\(geohash) ± 1", count
        )
    }

    private var notesContent: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if manager.state == .noRelays {
                noRelaysRow
            } else if manager.state == .loading && !manager.initialLoadComplete {
                loadingRow
            } else if manager.notes.isEmpty {
                emptyRow
            } else {
                ForEach(manager.notes) { note in
                    noteRow(note)
                }
            }

            if let error = manager.errorMessage, manager.state != .noRelays {
                errorRow(message: error)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func noteRow(_ note: LocationNotesManager.Note) -> some View {
        let baseName = note.displayName.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? note.displayName
        let ts = timestampText(for: note.createdAt)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: "@\(baseName)")
                    .bitchatFont(size: 12, weight: .semibold)
                if !ts.isEmpty {
                    Text(ts)
                        .bitchatFont(size: 11)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            Text(note.content)
                .bitchatFont(size: 14)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var noRelaysRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Strings.noRelaysNearby)
                .bitchatFont(size: 13, weight: .semibold)
            Text(Strings.relaysRetryHint)
                .bitchatFont(size: 12)
                .foregroundColor(.secondary)
            Button(Strings.retry) { manager.refresh() }
                .bitchatFont(size: 12)
                .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(Strings.loadingNotes)
                .bitchatFont(size: 12)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Strings.emptyTitle)
                .bitchatFont(size: 13, weight: .semibold)
            Text(Strings.emptySubtitle)
                .bitchatFont(size: 12)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func errorRow(message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .bitchatFont(size: 12)
                Text(message)
                    .bitchatFont(size: 12)
                Spacer()
            }
            Button(Strings.dismissError) { manager.clearError() }
                .bitchatFont(size: 12)
                .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    private var inputSection: some View {
        HStack(alignment: .top, spacing: 10) {
            TextField(Strings.addPlaceholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .bitchatFont(size: 14)
                .lineLimit(maxDraftLines, reservesSpace: true)
                .padding(.vertical, 6)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.bitchatSystem(size: 20))
                    .foregroundColor(sendButtonEnabled ? accentGreen : .secondary)
            }
            .padding(.top, 2)
            .buttonStyle(.plain)
            .disabled(!sendButtonEnabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .themedSurface()
        .overlay(Divider(), alignment: .top)
    }

    private func send() {
        guard let content = draft.trimmedOrNilIfEmpty else { return }
        manager.send(content: content, nickname: senderNickname)
        draft = ""
    }

    private var sendButtonEnabled: Bool {
        !draft.trimmed.isEmpty && manager.state != .noRelays
    }

    // MARK: - Timestamp Formatting
    private func timestampText(for date: Date) -> String {
        let now = Date()
        if let days = Calendar.current.dateComponents([.day], from: date, to: now).day, days < 7 {
            let rel = Self.relativeFormatter.string(from: date, to: now) ?? ""
            return rel.isEmpty ? "" : "\(rel) ago"
        } else {
            let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
            let fmt = sameYear ? Self.absDateFormatter : Self.absDateYearFormatter
            return fmt.string(from: date)
        }
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

    private static let absDateYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d, y")
        return f
    }()
}
