import SwiftUI

struct LocationNotesView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @StateObject private var manager: LocationNotesManager
    let geohash: String
    let onNotesCountChanged: ((Int) -> Void)?

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var locationManager = LocationChannelManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    init(geohash: String, onNotesCountChanged: ((Int) -> Void)? = nil) {
        let gh = geohash.lowercased()
        self.geohash = gh
        self.onNotesCountChanged = onNotesCountChanged
        _manager = StateObject(wrappedValue: LocationNotesManager(geohash: gh))
    }

    private var backgroundColor: Color { colorScheme == .dark ? .black : .white }
    private var accentGreen: Color { colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0) }
    private var maxDraftLines: Int { dynamicTypeSize.isAccessibilitySize ? 5 : 3 }

    var body: some View {
#if os(macOS)
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    headerSection
                    notesContent
                }
            }
            .background(backgroundColor)
            inputSection
        }
        .frame(minWidth: 420, idealWidth: 440, minHeight: 620, idealHeight: 680)
        .background(backgroundColor)
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
            .background(backgroundColor)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            #else
            .navigationTitle("")
            #endif
        }
       #if os(iOS)
        .presentationDetents([.large])
        #endif
        .background(backgroundColor)
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
                .font(.bitchatSystem(size: 13, weight: .semibold, design: .monospaced))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }

    private var headerSection: some View {
        let count = manager.notes.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("#\(geohash) • \(count) \(count == 1 ? "note" : "notes")")
                    .font(.bitchatSystem(size: 18, design: .monospaced))
                Spacer()
                closeButton
            }
            if let building = locationManager.locationNames[.building], !building.isEmpty {
                Text(building)
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(accentGreen)
            } else if let block = locationManager.locationNames[.block], !block.isEmpty {
                Text(block)
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(accentGreen)
            }
            Text("add short permanent notes to this location for other visitors to find.")
                .font(.bitchatSystem(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if manager.state == .loading && !manager.initialLoadComplete {
                Text("loading recent notes…")
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            } else if manager.state == .noRelays {
                Text("geo relays unavailable; notes paused")
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(backgroundColor)
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
                Text("@\(baseName)")
                    .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                if !ts.isEmpty {
                    Text(ts)
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            Text(note.content)
                .font(.bitchatSystem(size: 14, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var noRelaysRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("no geo relays nearby")
                .font(.bitchatSystem(size: 13, weight: .semibold, design: .monospaced))
            Text("notes rely on geo relays. check connection and try again.")
                .font(.bitchatSystem(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
            Button("retry") { manager.refresh() }
                .font(.bitchatSystem(size: 12, design: .monospaced))
                .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("loading notes…")
                .font(.bitchatSystem(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("no notes yet")
                .font(.bitchatSystem(size: 13, weight: .semibold, design: .monospaced))
            Text("be the first to add one for this spot.")
                .font(.bitchatSystem(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func errorRow(message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                Text(message)
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                Spacer()
            }
            Button("dismiss") { manager.clearError() }
                .font(.bitchatSystem(size: 12, design: .monospaced))
                .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    private var inputSection: some View {
        HStack(alignment: .top, spacing: 10) {
            TextField("add a note for this place", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.bitchatSystem(size: 14, design: .monospaced))
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
        .background(backgroundColor)
        .overlay(Divider(), alignment: .top)
    }

    private func send() {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        manager.send(content: content, nickname: viewModel.nickname)
        draft = ""
    }

    private var sendButtonEnabled: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && manager.state != .noRelays
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
