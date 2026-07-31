//
// RootTabView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)
import CoreBluetooth
import SwiftUI
import BitFoundation

/// iOS-only bottom tab shell wrapping the existing chat root.
///
/// macOS keeps presenting `ContentView` directly from `BitchatApp`: a bottom
/// tab bar is not the right chrome for a desktop window, and the people/groups
/// sheet already covers that navigation there.
struct RootTabView: View {
    enum Tab: Hashable {
        case chat
        case profile
        case groups
    }

    @State private var selection: Tab = .chat
    @ThemedPalette private var palette

    var body: some View {
        TabView(selection: $selection) {
            ContentView()
                .tabItem {
                    Label("chat", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(Tab.chat)

            ProfileTabView(onOpenChat: { selection = .chat })
                .tabItem {
                    Label("profile", systemImage: "person.crop.circle")
                }
                .tag(Tab.profile)

            GroupsTabView(onOpenChat: { selection = .chat })
                .tabItem {
                    Label("groups", systemImage: "person.3")
                }
                .tag(Tab.groups)
        }
        .tint(palette.primary)
    }
}

// MARK: - Profile

/// Identity surface: the nickname the mesh announces, plus the radio state
/// that decides whether anyone can hear it.
struct ProfileTabView: View {
    let onOpenChat: () -> Void

    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var peerListModel: PeerListModel

    @FocusState private var isNicknameFieldFocused: Bool
    @ThemedPalette private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TabHeader(title: "profile")

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nicknameField
                    Divider().background(palette.divider)
                    radioStatus
                    Divider().background(palette.divider)
                    aboutButton
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(palette.background)
    }

    private var nicknameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("nickname")
                .bitchatFont(size: 12)
                .foregroundColor(palette.secondary)

            HStack(spacing: 0) {
                Text("@")
                    .bitchatFont(size: 16)
                    .foregroundColor(palette.secondary)

                // Same commit path as the chat header: `setNickname` on every
                // keystroke, validate-and-save on blur/submit. Writing the
                // published property directly would skip persistence and the
                // mesh announce.
                TextField(
                    "content.input.nickname_placeholder",
                    text: Binding(
                        get: { appChromeModel.nickname },
                        set: { appChromeModel.setNickname($0) }
                    )
                )
                .textFieldStyle(.plain)
                .bitchatFont(size: 16)
                .foregroundColor(palette.primary)
                .focused($isNicknameFieldFocused)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .onChange(of: isNicknameFieldFocused) { isFocused in
                    if !isFocused {
                        appChromeModel.validateAndSaveNickname()
                    }
                }
                .onSubmit {
                    appChromeModel.validateAndSaveNickname()
                }
            }

            Text("this is the name nearby peers see")
                .bitchatFont(size: 11)
                .foregroundColor(palette.secondary)
        }
    }

    private var radioStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("bluetooth")
                .bitchatFont(size: 12)
                .foregroundColor(palette.secondary)

            HStack(spacing: 6) {
                Circle()
                    .fill(isRadioUsable ? palette.primary : palette.alertRed)
                    .frame(width: 8, height: 8)

                Text(bluetoothDescription)
                    .bitchatFont(size: 14)
                    .foregroundColor(isRadioUsable ? palette.primary : palette.alertRed)
            }

            Text("\(peerListModel.connectedMeshPeerCount) peers connected")
                .bitchatFont(size: 11)
                .foregroundColor(palette.secondary)
        }
    }

    private var isRadioUsable: Bool {
        appChromeModel.bluetoothState == .poweredOn
    }

    private var bluetoothDescription: String {
        switch appChromeModel.bluetoothState {
        case .poweredOn: return "on"
        case .poweredOff: return "off"
        case .unauthorized: return "not authorized"
        // The simulator reports this: there is no radio to attach to, so the
        // mesh stays empty no matter how many peers are actually nearby.
        case .unsupported: return "unsupported on this device"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    private var aboutButton: some View {
        Button {
            // The app-info sheet is attached to the chat root, where its
            // topology and panic-wipe providers are wired. Presenting a local
            // copy here would silently drop both, and presenting from a
            // non-visible tab is unreliable — so move to the chat tab first
            // and let that switch land before flipping the sheet flag.
            onOpenChat()
            Task { @MainActor in
                appChromeModel.isAppInfoPresented = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("about bitchat")
            }
            .bitchatFont(size: 14)
            .foregroundColor(palette.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Groups

/// Full-screen view of the private groups this device belongs to. Reuses the
/// existing `GroupChatList` row rendering from the people sheet rather than
/// duplicating it, and adds the empty state the sheet version omits.
struct GroupsTabView: View {
    let onOpenChat: () -> Void

    @EnvironmentObject private var peerListModel: PeerListModel
    @ThemedPalette private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TabHeader(title: "groups")

            if peerListModel.groupRows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    GroupChatList(
                        groups: peerListModel.groupRows,
                        onTapGroup: { peerID in
                            peerListModel.startConversation(with: peerID)
                            // The conversation opens in the chat root, so
                            // follow the user there instead of leaving them
                            // on a list that did not visibly change.
                            onOpenChat()
                        }
                    )
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(palette.background)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "person.3")
                .font(.bitchatSystem(size: 28))
                .foregroundColor(palette.secondary)
            Text("no groups yet")
                .bitchatFont(size: 14)
                .foregroundColor(palette.primary)
            Text("private groups you join appear here")
                .bitchatFont(size: 12)
                .foregroundColor(palette.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shared chrome

/// Minimal header matching the chat root's hairline-under-title shape.
private struct TabHeader: View {
    let title: String

    @ThemedPalette private var palette

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("bitchat/")
                    .bitchatFont(size: 16, weight: .bold)
                    .foregroundColor(palette.primary)
                Text(title)
                    .bitchatFont(size: 16)
                    .foregroundColor(palette.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider().background(palette.divider)
        }
    }
}
#endif
