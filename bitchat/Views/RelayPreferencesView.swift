//
// RelayPreferencesView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// View for managing Nostr relay preferences and privacy settings
struct RelayPreferencesView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var relayManager: NostrRelayManager
    
    @State private var newTrustedRelay: String = ""
    @State private var showingAddRelayAlert = false
    
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
        #if os(macOS)
        VStack(spacing: 0) {
            // Custom header for macOS
            HStack {
                Spacer()
                Button("DONE") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(textColor)
                .padding()
            }
            .background(backgroundColor.opacity(0.95))
            
            ScrollView {
                preferencesContent
            }
            .background(backgroundColor)
        }
        .frame(width: 600, height: 700)
        #else
        NavigationView {
            ScrollView {
                preferencesContent
            }
            .background(backgroundColor)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done") {
                        dismiss()
                    }
                    .foregroundColor(textColor)
                }
            }
        }
        #endif
    }
    
    @ViewBuilder
    private var preferencesContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Title
            Text("Nostr Relay Preferences")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(textColor)
                .padding(.top)
            
            // Relay Selection Mode
            VStack(alignment: .leading, spacing: 12) {
                Text("Relay Selection Mode")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                
                ForEach(NostrRelayManager.RelaySelectionMode.allCases, id: \.self) { mode in
                    HStack {
                        Button(action: {
                            relayManager.relaySelectionMode = mode
                        }) {
                            HStack {
                                Image(systemName: relayManager.relaySelectionMode == mode ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(relayManager.relaySelectionMode == mode ? textColor : secondaryTextColor)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.displayName)
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .foregroundColor(textColor)
                                    
                                    Text(mode.description)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(secondaryTextColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                
                                Spacer()
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.vertical, 4)
                }
            }
            
            // Current Relays
            VStack(alignment: .leading, spacing: 12) {
                Text("Current Relays")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                
                let availableRelays = relayManager.getAvailableRelays()
                if availableRelays.isEmpty {
                    Text("No relays available in current mode")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                        .italic()
                } else {
                    ForEach(availableRelays) { relay in
                        HStack {
                            Image(systemName: relay.isConnected ? "wifi" : "wifi.slash")
                                .foregroundColor(relay.isConnected ? textColor : secondaryTextColor)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(relay.url)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(textColor)
                                
                                Text(relay.category.displayName)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(secondaryTextColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(secondaryTextColor.opacity(0.1))
                                    .cornerRadius(4)
                            }
                            
                            Spacer()
                            
                            if relay.category == .trusted {
                                Button(action: {
                                    relayManager.removeTrustedRelay(relay.url)
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(Color.red)
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            
            // Trusted Relays Management
            VStack(alignment: .leading, spacing: 12) {
                Text("Trusted Relays")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                
                Text("Add your personal trusted relays for maximum privacy")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                
                HStack {
                    TextField("wss://your.trusted.relay", text: $newTrustedRelay)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    
                    Button("Add") {
                        if !newTrustedRelay.isEmpty {
                            relayManager.addTrustedRelay(newTrustedRelay)
                            newTrustedRelay = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newTrustedRelay.isEmpty)
                }
                
                if !relayManager.userTrustedRelays.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(relayManager.userTrustedRelays, id: \.self) { url in
                            HStack {
                                Text(url)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(textColor)
                                
                                Spacer()
                                
                                Button("Remove") {
                                    relayManager.removeTrustedRelay(url)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .foregroundColor(Color.red)
                            }
                        }
                    }
                }
            }
            
            // Privacy Information
            VStack(alignment: .leading, spacing: 8) {
                Text("Privacy Information")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                
                VStack(alignment: .leading, spacing: 4) {
                    InfoRow(icon: "shield.checkered", text: "Public relays are shared by many users")
                    InfoRow(icon: "lock.shield", text: "Private relays have restricted access")
                    InfoRow(icon: "star.fill", text: "Trusted relays are your personal choices")
                    InfoRow(icon: "eye.slash", text: "Fewer relays = less metadata exposure")
                }
            }
            .padding()
            .background(textColor.opacity(0.05))
            .cornerRadius(8)
            
            Spacer()
        }
        .padding()
    }
}

struct InfoRow: View {
    let icon: String
    let text: String
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(textColor)
                .font(.system(size: 12))
                .frame(width: 16)
            
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(textColor)
        }
    }
}

#Preview {
    RelayPreferencesView(relayManager: NostrRelayManager.shared)
}
