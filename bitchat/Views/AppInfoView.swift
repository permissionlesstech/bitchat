import SwiftUI

struct AppInfoView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    
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
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    VStack(alignment: .center, spacing: 8) {
                        Text("bitchat*")
                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                            .foregroundColor(textColor)
                        
                        Text("mesh sidegroupchat")
                            .font(.system(size: 16, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                    
                    // Features
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader("FEATURES")
                        
                        FeatureRow(icon: "wifi.slash", title: "offline communication",
                                  description: "works without internet using Bluetooth mesh networking")
                        
                        FeatureRow(icon: "lock.shield", title: "end-to-end encryption",
                                  description: "private messages encrypted with noise protocol")
                        
                        FeatureRow(icon: "antenna.radiowaves.left.and.right", title: "extended range",
                                  description: "messages relay through peers, increasing the distance")
                        
                        FeatureRow(icon: "star.fill", title: "favorites",
                                  description: "store-and-forward messages for favorite people")
                        
                        FeatureRow(icon: "at", title: "mentions",
                                  description: "use @nickname to notify specific people")
                        
                        FeatureRow(icon: "number", title: "channels",
                                  description: "create #channels for topic-based conversations")
                        
                        FeatureRow(icon: "lock.fill", title: "private channels",
                                  description: "secure channels with passwords and noise encryption")
                    }
                    
                    // Privacy
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader("Privacy")
                        
                        FeatureRow(icon: "eye.slash", title: "no tracking",
                                  description: "no servers, accounts, or data collection")
                        
                        FeatureRow(icon: "shuffle", title: "ephemeral identity",
                                  description: "new peer ID generated each session")
                        
                        FeatureRow(icon: "hand.raised.fill", title: "panic mode",
                                  description: "triple-tap logo to instantly clear all data")
                    }
                    
                    // How to Use
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader("How to Use")
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("• set your nickname by tapping it")
                            Text("• swipe left for sidebar")
                            Text("• tap a peer to start a private chat")
                            Text("• use @nickname to mention someone")
                            Text("• use #channelname to create/join channels")
                            Text("• triple-tap the logo for panic mode")
                        }
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(textColor)
                    }
                    
                    // Commands
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader("Commands")
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("/j #channel - join or create a channel")
                            Text("/m @name - send private message")
                            Text("/w - see who's online")
                            Text("/channels - show all discovered channels")
                            Text("/block @name - block a peer")
                            Text("/block - list blocked peers")
                            Text("/unblock @name - unblock a peer")
                            Text("/clear - clear current chat")
                            Text("/hug @name - send someone a hug")
                            Text("/slap @name - slap with a trout")
                        }
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(textColor)
                    }
                    
                    // Technical Details
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader("Technical Details")
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("protocol: custom binary over BLE")
                            Text("encryption: noise protocol")
                            Text("range: ~30m direct, 300m+ with relay")
                            Text("store & forward: 12h for all, ∞ for favorites")
                            Text("battery: Adaptive scanning based on level")
                            Text("platform: Universal (iOS, iPadOS, macOS)")
                            Text("channels: Password-protected with key commitments")
                            Text("storage: Keychain for passwords, encrypted retention")
                        }
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(textColor)
                    }
                    
                    // Version
                    HStack {
                        Spacer()
                        Text("VERSION 1.0.0")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                        Spacer()
                    }
                    .padding(.top)
                }
                .padding()
            }
            .background(backgroundColor)
        }
        .frame(width: 600, height: 700)
        #else
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    VStack(alignment: .center, spacing: 8) {
                        Text("bitchat*")
                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                            .foregroundColor(textColor)
                        
                        Text("mesh sidegroupchat")
                            .font(.system(size: 16, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                    
                    // Features
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader("Features")
                        
                        FeatureRow(icon: "wifi.slash", title: "offline communication",
                                  description: "works without internet using Bluetooth mesh networking")
                        
                        FeatureRow(icon: "lock.shield", title: "end-to-end encryption",
                                  description: "private messages and channels encrypted with noise protocol")
                        
                        FeatureRow(icon: "antenna.radiowaves.left.and.right", title: "Extended Range",
                                  description: "messages relay through peers, increasing the distance")
                        
                        FeatureRow(icon: "star.fill", title: "favorites",
                                  description: "store-and-forward messages for favorite people")
                        
                        FeatureRow(icon: "at", title: "mentions",
                                  description: "use @nickname to notify specific people")
                        
                        FeatureRow(icon: "number", title: "channels",
                                  description: "create #channels for topic-based conversations")
                        
                        FeatureRow(icon: "lock.fill", title: "private channels",
                                  description: "secure channels with passwords and noise encryption")
                    }
                    
                    // Privacy
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader("Privacy")
                        
                        FeatureRow(icon: "eye.slash", title: "no tracking",
                                  description: "no servers, accounts, or data collection")
                        
                        FeatureRow(icon: "shuffle", title: "ephemeral identity",
                                  description: "new peer ID generated each session")
                        
                        FeatureRow(icon: "hand.raised.fill", title: "panic mode",
                                  description: "triple-tap logo to instantly clear all data")
                    }
                    
                    // How to Use
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader("How to Use")
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("• set your nickname by tapping it")
                            Text("• swipe left for sidebar")
                            Text("• tap a peer to start a private chat")
                            Text("• use @nickname to mention someone")
                            Text("• use #channelname to create/join channels")
                            Text("• triple-tap the logo for panic mode")
                        }
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(textColor)
                    }
                    
                    // Commands
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader("Commands")
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("/j #channel - join or create a channel")
                            Text("/m @name - send private message")
                            Text("/w - see who's online")
                            Text("/channels - show all discovered channels")
                            Text("/block @name - block a peer")
                            Text("/block - list blocked peers")
                            Text("/unblock @name - unblock a peer")
                            Text("/clear - clear current chat")
                            Text("/hug @name - send someone a hug")
                            Text("/slap @name - slap with a trout")
                        }
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(textColor)
                    }
                    
                    // Technical Details
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader("Technical Details")
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("protocol: custom binary over BLE")
                            Text("encryption: noise protocol")
                            Text("range: ~30m direct, 300m+ with relay")
                            Text("store & forward: 12h for all, ∞ for favorites")
                            Text("battery: adaptive scanning based on level")
                            Text("platform: universal (iOS, iPadOS, macOS)")
                            Text("channels: password-protected with key commitments")
                            Text("storage: keychain for passwords, encrypted retention")
                        }
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(textColor)
                    }
                    
                    // Version
                    HStack {
                        Spacer()
                        Text("VERSION 1.0.0")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                        Spacer()
                    }
                    .padding(.top)
                }
                .padding()
            }
            .background(backgroundColor)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("DONE") {
                        dismiss()
                    }
                    .foregroundColor(textColor)
                }
            }
        }
        #endif
    }
}

struct SectionHeader: View {
    let title: String
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    init(_ title: String) {
        self.title = title
    }
    
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 16, weight: .bold, design: .monospaced))
            .foregroundColor(textColor)
            .padding(.top, 8)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(textColor)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                
                Text(description)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
    }
}

#Preview {
    AppInfoView()
}
