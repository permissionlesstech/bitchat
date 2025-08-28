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
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    @State private var customGeohash: String = ""
    @State private var customError: String? = nil

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Text("#location channels")
                    .font(.system(size: 18, design: .monospaced))
                Text("chat with people near you using geohash channels. only a coarse geohash is shared, never exact gps.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)

                Group {
                    switch manager.permissionState {
                    case LocationChannelManager.PermissionState.notDetermined:
                        Button(action: { manager.enableLocationChannels() }) {
                            Text("get location and my geohashes")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(standardGreen)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(standardGreen.opacity(0.12))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    case LocationChannelManager.PermissionState.denied, LocationChannelManager.PermissionState.restricted:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("location permission denied. enable in settings to use location channels.")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                            Button("open settings") { openSystemLocationSettings() }
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("close") { isPresented = false }
                        .font(.system(size: 14, design: .monospaced))
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("close") { isPresented = false }
                        .font(.system(size: 14, design: .monospaced))
                }
            }
            #endif
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
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

    private var channelList: some View {
        List {
            // Mesh option first (no bookmark)
            channelRow(title: meshTitleWithCount(), subtitlePrefix: "#bluetooth • \(bluetoothRangeString())", isSelected: isMeshSelected, titleColor: standardBlue, titleBold: meshCount() > 0) {
                manager.select(ChannelID.mesh)
                isPresented = false
            }

            // Nearby options
            if !manager.availableChannels.isEmpty {
                ForEach(manager.availableChannels) { channel in
                    let coverage = coverageString(forPrecision: channel.geohash.count)
                    let nameBase = locationName(for: channel.level)
                    let namePart = nameBase.map { formattedNamePrefix(for: channel.level) + $0 }
                    let subtitlePrefix = "#\(channel.geohash) • \(coverage)"
                    let highlight = viewModel.geohashParticipantCount(for: channel.geohash) > 0
                    channelRow(
                        title: geohashTitleWithCount(for: channel),
                        subtitlePrefix: subtitlePrefix,
                        subtitleName: namePart,
                        isSelected: isSelected(channel),
                        titleBold: highlight,
                        trailingAccessory: {
                            Button(action: { bookmarks.toggle(channel.geohash) }) {
                                Image(systemName: bookmarks.isBookmarked(channel.geohash) ? "bookmark.fill" : "bookmark")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 8)
                        }
                    ) {
                        // Selecting a suggested nearby channel is not a teleport. Persist this.
                        manager.markTeleported(for: channel.geohash, false)
                        manager.select(ChannelID.location(channel))
                        isPresented = false
                    }
                }
            } else {
                HStack {
                    ProgressView()
                    Text("finding nearby channels…")
                        .font(.system(size: 12, design: .monospaced))
                }
            }

            // Custom geohash teleport
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 2) {
                    Text("#")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.secondary)
                    TextField("geohash", text: $customGeohash)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.asciiCapable)
                        #endif
                        .font(.system(size: 14, design: .monospaced))
                        .onChange(of: customGeohash) { newValue in
                            // Allow only geohash base32 characters, strip '#', limit length
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
                    let normalized = customGeohash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "#", with: "")
                    let isValid = validateGeohash(normalized)
                    Button(action: {
                        let gh = normalized
                        guard isValid else { customError = "invalid geohash"; return }
                        let level = levelForLength(gh.count)
                        let ch = GeohashChannel(level: level, geohash: gh)
                        // Mark this selection as a manual teleport
                        manager.markTeleported(for: ch.geohash, true)
                        manager.select(ChannelID.location(ch))
                        isPresented = false
                    }) {
                        HStack(spacing: 6) {
                            Text("teleport")
                                .font(.system(size: 14, design: .monospaced))
                            Image(systemName: "face.dashed")
                                .font(.system(size: 14))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(6)
                    .opacity(isValid ? 1.0 : 0.4)
                    .disabled(!isValid)
                }
                if let err = customError {
                    Text(err)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.red)
                }
            }

            // Bookmarked geohashes
            if !bookmarks.bookmarks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("bookmarked")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .listRowSeparator(.hidden)
                ForEach(bookmarks.bookmarks, id: \.self) { gh in
                    let level = levelForLength(gh.count)
                    let channel = GeohashChannel(level: level, geohash: gh)
                    let coverage = coverageString(forPrecision: gh.count)
                    let subtitle = "#\(gh) • \(coverage)"
                    let name = bookmarks.bookmarkNames[gh]
                    channelRow(
                        title: geohashHashTitleWithCount(gh),
                        subtitlePrefix: subtitle,
                        subtitleName: name.map { formattedNamePrefix(for: level) + $0 },
                        isSelected: isSelected(channel),
                        trailingAccessory: {
                            Button(action: { bookmarks.toggle(gh) }) {
                                Image(systemName: bookmarks.isBookmarked(gh) ? "bookmark.fill" : "bookmark")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 8)
                        }
                    ) {
                        // For bookmarked selection, mark teleported based on regional membership
                        let inRegional = manager.availableChannels.contains { $0.geohash == gh }
                        if !inRegional && !manager.availableChannels.isEmpty {
                            manager.markTeleported(for: gh, true)
                        } else {
                            manager.markTeleported(for: gh, false)
                        }
                        manager.select(ChannelID.location(channel))
                        isPresented = false
                    }
                    .onAppear { bookmarks.resolveNameIfNeeded(for: gh) }
                }
            }

            // Footer action inside the list
            if manager.permissionState == LocationChannelManager.PermissionState.authorized {
                Button(action: {
                    openSystemLocationSettings()
                }) {
                    Text("remove location access")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(red: 0.75, green: 0.1, blue: 0.1))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.08))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
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
                            .font(.system(size: 14, design: .monospaced))
                            .fontWeight(titleBold ? .bold : .regular)
                            .foregroundColor(titleColor ?? Color.primary)
                        if let count = parts.countSuffix, !count.isEmpty {
                            Text(count)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                let subtitleFull: String = {
                    if let name = subtitleName, !name.isEmpty {
                        return subtitlePrefix + " • " + name
                    }
                    return subtitlePrefix
                }()
                Text(subtitleFull)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
                Spacer()
                if isSelected {
                    Text("✔︎")
                        .font(.system(size: 16, design: .monospaced))
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
    private func meshTitleWithCount() -> String {
        // Count currently connected mesh peers (excluding self)
        let meshCount = meshCount()
        let noun = meshCount == 1 ? "person" : "people"
        return "mesh [\(meshCount) \(noun)]"
    }

    private func meshCount() -> Int {
        // Count mesh-connected OR mesh-reachable peers (exclude self)
        let myID = viewModel.meshService.myPeerID
        return viewModel.allPeers.reduce(0) { acc, peer in
            if peer.id != myID && (peer.isConnected || peer.isReachable) { return acc + 1 }
            return acc
        }
    }

    private func geohashTitleWithCount(for channel: GeohashChannel) -> String {
        // Main list: keep level labels (block/neighborhood/city/province/region)
        let count = viewModel.geohashParticipantCount(for: channel.geohash)
        let noun = count == 1 ? "person" : "people"
        return "\(channel.level.displayName.lowercased()) [\(count) \(noun)]"
    }

    private func geohashHashTitleWithCount(_ geohash: String) -> String {
        // Bookmarked list: show the #geohash as the main label
        let count = viewModel.geohashParticipantCount(for: geohash)
        let noun = count == 1 ? "person" : "people"
        return "#\(geohash) [\(count) \(noun)]"
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
        default: return .block
        }
    }
}

// MARK: - Standardized Colors
extension LocationChannelsSheet {
    private var standardGreen: Color {
        (colorScheme == .dark) ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    private var standardBlue: Color {
        Color(red: 0.0, green: 0.478, blue: 1.0)
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
