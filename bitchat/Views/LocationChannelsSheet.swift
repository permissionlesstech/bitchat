import SwiftUI

#if os(iOS)
import UIKit
struct LocationChannelsSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var manager = LocationChannelManager.shared

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
                        VStack(alignment: .leading, spacing: 8) {
                            Button("enable location channels") {
                                manager.enableLocationChannels()
                            }
                            .buttonStyle(.plain)
                        }
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
                        channelList
                    }
                }
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
        .presentationDetents([.medium, .large])
        .onAppear {
            // Refresh channels when opening
            if manager.permissionState == LocationChannelManager.PermissionState.authorized {
                manager.refreshChannels()
            }
            // Begin periodic refresh while sheet is open
            manager.beginLiveRefresh()
        }
        .onDisappear { manager.endLiveRefresh() }
        .onChange(of: manager.permissionState) { newValue in
            if newValue == LocationChannelManager.PermissionState.authorized {
                manager.refreshChannels()
            }
        }
    }

    private var channelList: some View {
        List {
            // Mesh option first
            channelRow(title: "#mesh", subtitle: "bluetooth", isSelected: isMeshSelected) {
                manager.select(ChannelID.mesh)
                isPresented = false
            }

            // Nearby options
            if !manager.availableChannels.isEmpty {
                ForEach(manager.availableChannels) { channel in
                    channelRow(title: channel.level.displayName.lowercased(), subtitle: "#\(channel.geohash)", isSelected: isSelected(channel)) {
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

            // Footer action inside the list
            if manager.permissionState == LocationChannelManager.PermissionState.authorized {
                Button(action: {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }) {
                    HStack {
                        Text("remove location permission")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(Color(red: 0.75, green: 0.1, blue: 0.1))
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
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
                    Text(title)
                        .font(.system(size: 14, design: .monospaced))
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
}

#endif
