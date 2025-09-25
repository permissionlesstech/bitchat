import SwiftUI
import CoreLocation
#if os(iOS)
import UIKit
#else
import AppKit
#endif
struct LocationChannelsSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var manager = LocationChannelManager.shared
    @ObservedObject private var bookmarks = GeohashBookmarksStore.shared
    @ObservedObject private var network = NetworkActivationService.shared
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    @State private var customGeohash: String = ""
    @State private var customError: String? = nil

    private var backgroundColor: Color { colorScheme == .dark ? .black : .white }

    private enum Strings {
        static let title: LocalizedStringKey = "location_channels.title"
        static let description: LocalizedStringKey = "location_channels.description"
        static let requestPermissions: LocalizedStringKey = "location_channels.action.request_permissions"
        static let permissionDenied: LocalizedStringKey = "location_channels.permission_denied"
        static let openSettings: LocalizedStringKey = "location_channels.action.open_settings"
        static let loadingNearby: LocalizedStringKey = "location_channels.loading_nearby"
        static let teleport: LocalizedStringKey = "location_channels.action.teleport"
        static let bookmarked: LocalizedStringKey = "location_channels.bookmarked_section_title"
        static let removeAccess: LocalizedStringKey = "location_channels.action.remove_access"
        static let torTitle: LocalizedStringKey = "location_channels.tor.title"
        static let torSubtitle: LocalizedStringKey = "location_channels.tor.subtitle"
        static let toggleOn: LocalizedStringKey = "common.toggle.on"
        static let toggleOff: LocalizedStringKey = "common.toggle.off"

        static let invalidGeohash = L10n.string(
            "location_channels.error.invalid_geohash",
            comment: "Error shown when a custom geohash is invalid"
        )

        static func meshTitle(_ count: Int) -> String {
            let label = L10n.string(
                "location_channels.mesh_label",
                comment: "Label for the mesh channel row"
            )
            return rowTitle(label: label, count: count)
        }

        static func levelTitle(for level: GeohashChannelLevel, count: Int) -> String {
            return rowTitle(label: level.displayName, count: count)
        }

        static func bookmarkTitle(geohash: String, count: Int) -> String {
            return rowTitle(label: "#\(geohash)", count: count)
        }

        static func subtitlePrefix(geohash: String, coverage: String) -> String {
            L10n.format(
                "location_channels.subtitle_prefix",
                comment: "Subtitle prefix showing geohash and coverage",
                geohash,
                coverage
            )
        }

        static func subtitle(prefix: String, name: String?) -> String {
            guard let name, !name.isEmpty else { return prefix }
            return L10n.format(
                "location_channels.subtitle_with_name",
                comment: "Subtitle combining prefix and resolved location name",
                prefix,
                name
            )
        }

        private static func rowTitle(label: String, count: Int) -> String {
            let format = NSLocalizedString(
                "location_channels.row_title",
                comment: "List row title with participant count"
            )
            return NSString.localizedStringWithFormat(format as NSString, label, count) as String
        }
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text(Strings.title)
                        .font(.bitchatSystem(size: 18, design: .monospaced))
                    Spacer()
                    closeButton
                }
                Text(Strings.description)
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)

                Group {
                    switch manager.permissionState {
                    case LocationChannelManager.PermissionState.notDetermined:
                        Button(action: { manager.enableLocationChannels() }) {
                            Text(Strings.requestPermissions)
                                .font(.bitchatSystem(size: 12, design: .monospaced))
                                .foregroundColor(standardGreen)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(standardGreen.opacity(0.12))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    case LocationChannelManager.PermissionState.denied, LocationChannelManager.PermissionState.restricted:
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Strings.permissionDenied)
                                .font(.bitchatSystem(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                            Button(Strings.openSettings) { openSystemLocationSettings() }
                            .buttonStyle(.plain)
                        }
                    case LocationChannelManager.PermissionState.authorized:
                        EmptyView()
                    }
                }

                channelList
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
        .background(backgroundColor)
        .onAppear {
            // Refresh channels when opening
            if manager.permissionState == LocationChannelManager.PermissionState.authorized {
                manager.refreshChannels()
            }
            // Begin periodic refresh while sheet is open
            manager.beginLiveRefresh()
            // Geohash sampling is now managed by ChatViewModel globally
        }
        .onDisappear {
            manager.endLiveRefresh()
        }
        .onChange(of: manager.permissionState) { newValue in
            if newValue == LocationChannelManager.PermissionState.authorized {
                manager.refreshChannels()
            }
        }
        .onChange(of: manager.availableChannels) { _ in }
    }

    private var closeButton: some View {
        Button(action: { isPresented = false }) {
            Image(systemName: "xmark")
                .font(.bitchatSystem(size: 13, weight: .semibold, design: .monospaced))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }

    private var channelList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                channelRow(title: Strings.meshTitle(meshCount()), subtitlePrefix: Strings.subtitlePrefix(geohash: "bluetooth", coverage: bluetoothRangeString()), isSelected: isMeshSelected, titleColor: standardBlue, titleBold: meshCount() > 0) {
                    manager.select(ChannelID.mesh)
                    isPresented = false
                }
                .padding(.vertical, 6)

                let nearby = manager.availableChannels.filter { $0.level != .building }
                if !nearby.isEmpty {
                    ForEach(nearby) { channel in
                        sectionDivider
                        let coverage = coverageString(forPrecision: channel.geohash.count)
                        let nameBase = locationName(for: channel.level)
                        let namePart = nameBase.map { formattedNamePrefix(for: channel.level) + $0 }
                        let participantCount = viewModel.geohashParticipantCount(for: channel.geohash)
                        let subtitlePrefix = Strings.subtitlePrefix(geohash: channel.geohash, coverage: coverage)
                        let highlight = participantCount > 0
                        channelRow(
                            title: Strings.levelTitle(for: channel.level, count: participantCount),
                            subtitlePrefix: subtitlePrefix,
                            subtitleName: namePart,
                            isSelected: isSelected(channel),
                            titleBold: highlight,
                            trailingAccessory: {
                                Button(action: { bookmarks.toggle(channel.geohash) }) {
                                    Image(systemName: bookmarks.isBookmarked(channel.geohash) ? "bookmark.fill" : "bookmark")
                                        .font(.bitchatSystem(size: 14))
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, 8)
                            }
                        ) {
                            manager.markTeleported(for: channel.geohash, false)
                            manager.select(ChannelID.location(channel))
                            isPresented = false
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    sectionDivider
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(Strings.loadingNearby)
                            .font(.bitchatSystem(size: 12, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                }

                sectionDivider
                customTeleportSection
                    .padding(.vertical, 8)

                let bookmarkedList = bookmarks.bookmarks
                if !bookmarkedList.isEmpty {
                    sectionDivider
                    bookmarkedSection(bookmarkedList)
                        .padding(.vertical, 8)
                }

                if manager.permissionState == LocationChannelManager.PermissionState.authorized {
                    sectionDivider
                    torToggleSection
                        .padding(.top, 12)
                    Button(action: {
                        openSystemLocationSettings()
                    }) {
                        Text(Strings.removeAccess)
                            .font(.bitchatSystem(size: 12, design: .monospaced))
                            .foregroundColor(Color(red: 0.75, green: 0.1, blue: 0.1))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .background(backgroundColor)
        }
        .background(backgroundColor)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(dividerColor)
            .frame(height: 1)
    }

    private var dividerColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }

    private var customTeleportSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text("#")
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(.secondary)
                TextField("geohash", text: $customGeohash)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.asciiCapable)
                    #endif
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .onChange(of: customGeohash) { newValue in
                        let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
                        let filtered = newValue
                            .lowercased()
                            .replacingOccurrences(of: "#", with: "")
                            .filter { allowed.contains($0) }
                        if filtered.count > 12 {
                            customGeohash = String(filtered.prefix(12))
                        } else if filtered != newValue {
                            customGeohash = filtered
                        }
                    }
                let normalized = customGeohash
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .replacingOccurrences(of: "#", with: "")
                let isValid = validateGeohash(normalized)
                Button(action: {
                    let gh = normalized
                    guard isValid else { customError = Strings.invalidGeohash; return }
                    let level = levelForLength(gh.count)
                    let ch = GeohashChannel(level: level, geohash: gh)
                    manager.markTeleported(for: ch.geohash, true)
                    manager.select(ChannelID.location(ch))
                    isPresented = false
                }) {
                    HStack(spacing: 6) {
                        Text(Strings.teleport)
                            .font(.bitchatSystem(size: 14, design: .monospaced))
                        Image(systemName: "face.dashed")
                            .font(.bitchatSystem(size: 14))
                    }
                }
                .buttonStyle(.plain)
                .font(.bitchatSystem(size: 14, design: .monospaced))
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(6)
                .opacity(isValid ? 1.0 : 0.4)
                .disabled(!isValid)
            }
            if let err = customError {
                Text(err)
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(.red)
            }
        }
    }

    private func bookmarkedSection(_ entries: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Strings.bookmarked)
                .font(.bitchatSystem(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
            LazyVStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, gh in
                    let level = levelForLength(gh.count)
                    let channel = GeohashChannel(level: level, geohash: gh)
                    let coverage = coverageString(forPrecision: gh.count)
                    let subtitle = Strings.subtitlePrefix(geohash: gh, coverage: coverage)
                    let name = bookmarks.bookmarkNames[gh]
                    let participantCount = viewModel.geohashParticipantCount(for: gh)
                    channelRow(
                        title: Strings.bookmarkTitle(geohash: gh, count: participantCount),
                        subtitlePrefix: subtitle,
                        subtitleName: name.map { formattedNamePrefix(for: level) + $0 },
                        isSelected: isSelected(channel),
                        trailingAccessory: {
                            Button(action: { bookmarks.toggle(gh) }) {
                                Image(systemName: bookmarks.isBookmarked(gh) ? "bookmark.fill" : "bookmark")
                                    .font(.bitchatSystem(size: 14))
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 8)
                        }
                    ) {
                        let inRegional = manager.availableChannels.contains { $0.geohash == gh }
                        if !inRegional && !manager.availableChannels.isEmpty {
                            manager.markTeleported(for: gh, true)
                        } else {
                            manager.markTeleported(for: gh, false)
                        }
                        manager.select(ChannelID.location(channel))
                        isPresented = false
                    }
                    .padding(.vertical, 6)
                    .onAppear { bookmarks.resolveNameIfNeeded(for: gh) }

                    if index < entries.count - 1 {
                        sectionDivider
                    }
                }
            }
        }
    }


    private func isSelected(_ channel: GeohashChannel) -> Bool {
        if case .location(let ch) = manager.selectedChannel {
            return ch == channel
        }
        return false
    }

    private var isMeshSelected: Bool {
        if case .mesh = manager.selectedChannel { return true }
        return false
    }

    @ViewBuilder
    private func channelRow(
        title: String,
        subtitlePrefix: String,
        subtitleName: String? = nil,
        subtitleNameBold: Bool = false,
        isSelected: Bool,
        titleColor: Color? = nil,
        titleBold: Bool = false,
        @ViewBuilder trailingAccessory: () -> some View = { EmptyView() },
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading) {
                // Render title with smaller font for trailing count in parentheses
                let parts = splitTitleAndCount(title)
                HStack(spacing: 4) {
                    Text(parts.base)
                            .font(.bitchatSystem(size: 14, design: .monospaced))
                            .fontWeight(titleBold ? .bold : .regular)
                            .foregroundColor(titleColor ?? Color.primary)
                        if let count = parts.countSuffix, !count.isEmpty {
                            Text(count)
                                .font(.bitchatSystem(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                let subtitleFull = Strings.subtitle(prefix: subtitlePrefix, name: subtitleName)
                Text(subtitleFull)
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
                Spacer()
                if isSelected {
                    Text("✔︎")
                        .font(.bitchatSystem(size: 16, design: .monospaced))
                        .foregroundColor(standardGreen)
                }
                trailingAccessory()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    // Split a title like "#mesh [3 people]" into base and suffix "[3 people]"
    private func splitTitleAndCount(_ s: String) -> (base: String, countSuffix: String?) {
        guard let idx = s.lastIndex(of: "[") else { return (s, nil) }
        let prefix = String(s[..<idx]).trimmingCharacters(in: .whitespaces)
        let suffix = String(s[idx...])
        return (prefix, suffix)
    }

    // MARK: - Helpers for counts
    private func meshCount() -> Int {
        // Count mesh-connected OR mesh-reachable peers (exclude self)
        let myID = viewModel.meshService.myPeerID
        return viewModel.allPeers.reduce(0) { acc, peer in
            if peer.id != myID && (peer.isConnected || peer.isReachable) { return acc + 1 }
            return acc
        }
    }

    private func validateGeohash(_ s: String) -> Bool {
        let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
        guard !s.isEmpty, s.count <= 12 else { return false }
        return s.allSatisfy { allowed.contains($0) }
    }

    private func levelForLength(_ len: Int) -> GeohashChannelLevel {
        switch len {
        case 0...2: return .region
        case 3...4: return .province
        case 5: return .city
        case 6: return .neighborhood
        case 7: return .block
        case 8: return .building
        default: return .block
        }
    }
}

// MARK: - TOR Toggle & Standardized Colors
extension LocationChannelsSheet {
    private var torToggleBinding: Binding<Bool> {
        Binding(
            get: { network.userTorEnabled },
            set: { network.setUserTorEnabled($0) }
        )
    }

    private var torToggleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: torToggleBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Strings.torTitle)
                        .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                    Text(Strings.torSubtitle)
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(IRCToggleStyle(accent: standardGreen, onLabel: Strings.toggleOn, offLabel: Strings.toggleOff))
        }
        .padding(12)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(8)
    }

    private var standardGreen: Color {
        (colorScheme == .dark) ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    private var standardBlue: Color {
        Color(red: 0.0, green: 0.478, blue: 1.0)
    }
}

private struct IRCToggleStyle: ToggleStyle {
    let accent: Color
    let onLabel: LocalizedStringKey
    let offLabel: LocalizedStringKey

    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack(spacing: 12) {
                configuration.label
                Spacer()
                Text(configuration.isOn ? onLabel : offLabel)
                    .textCase(.uppercase)
                    .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(configuration.isOn ? accent : .secondary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(accent.opacity(configuration.isOn ? 0.18 : 0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(accent.opacity(configuration.isOn ? 0.35 : 0.15), lineWidth: 1)
                    )
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Coverage helpers
extension LocationChannelsSheet {
    private func coverageString(forPrecision len: Int) -> String {
        // Approximate max cell dimension at equator for a given geohash length.
        // Values sourced from common geohash dimension tables.
        let maxMeters: Double = {
            switch len {
            case 2: return 1_250_000
            case 3: return 156_000
            case 4: return 39_100
            case 5: return 4_890
            case 6: return 1_220
            case 7: return 153
            case 8: return 38.2
            case 9: return 4.77
            case 10: return 1.19
            default:
                if len <= 1 { return 5_000_000 }
                // For >10, scale down conservatively by ~1/4 each char
                let over = len - 10
                return 1.19 * pow(0.25, Double(over))
            }
        }()

        let usesMetric: Bool = {
            if #available(iOS 16.0, macOS 13.0, *) {
                return Locale.current.measurementSystem == .metric
            } else {
                return Locale.current.usesMetricSystem
            }
        }()
        if usesMetric {
            let km = maxMeters / 1000.0
            return "~\(formatDistance(km)) km"
        } else {
            let miles = maxMeters / 1609.344
            return "~\(formatDistance(miles)) mi"
        }
    }

    private func formatDistance(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f", value.rounded()) }
        if value >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.1f", value)
    }

    private func bluetoothRangeString() -> String {
        let usesMetric: Bool = {
            if #available(iOS 16.0, macOS 13.0, *) {
                return Locale.current.measurementSystem == .metric
            } else {
                return Locale.current.usesMetricSystem
            }
        }()
        // Approximate Bluetooth LE range for typical mobile devices; environment dependent
        return usesMetric ? "~10–50 m" : "~30–160 ft"
    }

    private func locationName(for level: GeohashChannelLevel) -> String? {
        manager.locationNames[level]
    }

    private func formattedNamePrefix(for level: GeohashChannelLevel) -> String {
        switch level {
        case .region:
            return ""
        default:
            return "~"
        }
    }
}

// MARK: - Open Settings helper
private func openSystemLocationSettings() {
    #if os(iOS)
    if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
    }
    #else
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
        NSWorkspace.shared.open(url)
    } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
        NSWorkspace.shared.open(url)
    }
    #endif
}
