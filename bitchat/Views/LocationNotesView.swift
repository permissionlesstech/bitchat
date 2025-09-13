import SwiftUI

struct LocationNotesView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @StateObject private var manager: LocationNotesManager
    let geohash: String
    let onNotesCountChanged: ((Int) -> Void)?

    @Environment(\.colorScheme) var colorScheme
    @ObservedObject private var locationManager = LocationChannelManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    init(geohash: String, onNotesCountChanged: ((Int) -> Void)? = nil) {
        let gh = geohash.lowercased()
        self.geohash = gh
        self.onNotesCountChanged = onNotesCountChanged
        _manager = StateObject(wrappedValue: LocationNotesManager(geohash: gh))
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            input
        }
        .background(backgroundColor)
        .foregroundColor(textColor)
        .onDisappear { manager.cancel() }
        .onChange(of: geohash) { newValue in
            manager.setGeohash(newValue)
        }
        .onAppear { onNotesCountChanged?(manager.notes.count) }
        .onChange(of: manager.notes.count) { newValue in
            onNotesCountChanged?(newValue)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    let c = manager.notes.count
                    Text("\(c) \(c == 1 ? "note" : "notes") ")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                    Text("@ #\(geohash)")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                }
                if let buildingName = locationManager.locationNames[.building], !buildingName.isEmpty {
                    Text(buildingName)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                } else if let blockName = locationManager.locationNames[.block], !blockName.isEmpty {
                    Text(blockName)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                }
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .frame(height: 44)
        .padding(.horizontal, 12)
        .background(backgroundColor.opacity(0.95))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(manager.notes) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(note.displayName)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                            Text(timestampText(for: note.createdAt))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(secondaryTextColor.opacity(0.8))
                        }
                        Text(note.content)
                            .font(.system(size: 14, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
        }
        .background(backgroundColor)
    }

    private var input: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("add a note for this place", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .lineLimit(3, reservesSpace: true)
                .padding(.horizontal, 12)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : textColor)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.trailing, 12)
        }
        .frame(minHeight: 44)
        .padding(.vertical, 8)
        .background(backgroundColor.opacity(0.95))
    }

    private func send() {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        manager.send(content: content, nickname: viewModel.nickname)
        draft = ""
    }

    // MARK: - Timestamp Formatting
    private func timestampText(for date: Date) -> String {
        let now = Date()
        if let days = Calendar.current.dateComponents([.day], from: date, to: now).day, days < 7 {
            // Relative (minute/hour/day), no seconds
            let rel = Self.relativeFormatter.string(from: date, to: now) ?? ""
            return rel.isEmpty ? "" : "\(rel) ago"
        } else {
            // Absolute date (MMM d or MMM d, yyyy if different year)
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
