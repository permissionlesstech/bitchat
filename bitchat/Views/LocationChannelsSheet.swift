import SwiftUI

#if os(iOS)
import UIKit
struct LocationChannelsSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var manager = LocationChannelManager.shared
    @EnvironmentObject var viewModel: ChatViewModel
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
                                .foregroundColor(Color.green)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Color.green.opacity(0.12))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    case LocationChannelManager.PermissionState.denied, LocationChannelManager.PermissionState.restricted:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("location permission denied. enable in settings to use location channels.")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                            Button("open settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("close") { isPresented = false }
                        .font(.system(size: 14, design: .monospaced))
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            // Refresh channels when opening
            if manager.permissionState == LocationChannelManager.PermissionState.authorized {
                manager.refreshChannels()
            }
            // Begin periodic refresh while sheet is open
            manager.beginLiveRefresh()
            // Begin multi-channel sampling for counts
            let ghs = manager.availableChannels.map { $0.geohash }
            viewModel.beginGeohashSampling(for: ghs)
        }
        .onDisappear {
            manager.endLiveRefresh()
            viewModel.endGeohashSampling()
        }
        .onChange(of: manager.permissionState) { newValue in
            if newValue == LocationChannelManager.PermissionState.authorized {
                manager.refreshChannels()
            }
        }
        .onChange(of: manager.availableChannels) { newValue in
            // Keep sampling list in sync with available channels as they refresh live
            let ghs = newValue.map { $0.geohash }
            viewModel.beginGeohashSampling(for: ghs)
        }
    }

    private var channelList: some View {
        List {
            // Mesh option first
            channelRow(title: meshTitleWithCount(), subtitle: "#bluetooth", isSelected: isMeshSelected) {
                manager.select(ChannelID.mesh)
                isPresented = false
            }

            // Nearby options
            if !manager.availableChannels.isEmpty {
                ForEach(manager.availableChannels) { channel in
                    channelRow(title: geohashTitleWithCount(for: channel), subtitle: "#\(channel.geohash)", isSelected: isSelected(channel)) {
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
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(.system(size: 14, design: .monospaced))
                        .keyboardType(.asciiCapable)
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
                    Button("teleport") {
                        let gh = normalized
                        guard isValid else { customError = "invalid geohash"; return }
                        let level = levelForLength(gh.count)
                        let ch = GeohashChannel(level: level, geohash: gh)
                        manager.select(ChannelID.location(ch))
                        isPresented = false
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

            // Footer action inside the list
            if manager.permissionState == LocationChannelManager.PermissionState.authorized {
                Button(action: {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
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

    private func channelRow(title: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading) {
                    // Render title with smaller font for trailing count in parentheses
                    let parts = splitTitleAndCount(title)
                    HStack(spacing: 4) {
                        Text(parts.base)
                            .font(.system(size: 14, design: .monospaced))
                        if let count = parts.countSuffix, !count.isEmpty {
                            Text(count)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if isSelected {
                    Text("✔︎")
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundColor(.green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        let myID = viewModel.meshService.myPeerID
        let meshCount = viewModel.allPeers.reduce(0) { acc, peer in
            if peer.id != myID && peer.isConnected { return acc + 1 }
            return acc
        }
        let noun = meshCount == 1 ? "person" : "people"
        return "#mesh [\(meshCount) \(noun)]"
    }

    private func geohashTitleWithCount(for channel: GeohashChannel) -> String {
        // Use ViewModel's 5-minute activity counts; may be 0 for non-selected channels
        let count = viewModel.geohashParticipantCount(for: channel.geohash)
        let noun = count == 1 ? "person" : "people"
        return "\(channel.level.displayName.lowercased()) [\(count) \(noun)]"
    }

    private func validateGeohash(_ s: String) -> Bool {
        let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
        guard !s.isEmpty, s.count <= 12 else { return false }
        return s.allSatisfy { allowed.contains($0) }
    }

    private func levelForLength(_ len: Int) -> GeohashChannelLevel {
        switch len {
        case 0...2: return .country
        case 3...4: return .region
        case 5: return .city
        case 6: return .neighborhood
        case 7: return .block
        default: return .street
        }
    }
}

#endif
