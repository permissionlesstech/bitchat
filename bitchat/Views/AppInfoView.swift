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
                Button("Done") {
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
                        
                        Text("secure mesh chat")
                            .font(.system(size: 16, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                    
                    // Features
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader("Features")
                        
                        FeatureRow(icon: "wifi.slash", title: "Offline Communication",
                                  description: "Works without internet using Bluetooth mesh networking")
                        
                        FeatureRow(icon: "lock.shield", title: "End-to-End Encryption",
                                  description: "All messages encrypted with Curve25519 + AES-GCM")
                        
                        FeatureRow(icon: "antenna.radiowaves.left.and.right", title: "Extended Range",
                                  description: "Messages relay through peers, reaching 300m+")
                        
                        FeatureRow(icon: "star.fill", title: "Favorites System",
                                  description: "Store-and-forward messages for favorites indefinitely")
                        
                        FeatureRow(icon: "at", title: "Mentions",
                                  description: "Use @nickname to notify specific users")
                        
                        FeatureRow(icon: "number", title: "Channels",
                                  description: "Create #channels for topic-based conversations")
                        
                        FeatureRow(icon: "lock.fill", title: "Password Channels",
                                  description: "Secure channels with passwords and AES encryption")
                    }
                    
                    // Privacy
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader("Privacy")
                        
                        FeatureRow(icon: "eye.slash", title: "No Tracking",
                                  description: "No servers, accounts, or data collection")
                        
                        FeatureRow(icon: "shuffle", title: "Ephemeral Identity",
                                  description: "New peer ID generated each session")
                        
                        FeatureRow(icon: "hand.raised.fill", title: "Panic Mode",
                                  description: "Triple-tap logo to instantly clear all data")
                    }
                    
                    // How to Use
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader("How to Use")
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("• Set your nickname in the header")
                            Text("• Swipe left or tap channel name for sidebar")
                            Text("• Tap a peer to start a private chat")
                            Text("• Use @nickname to mention someone")
                            Text("• Use #channelname to create/join channels")
                            Text("• Triple-tap the logo for panic mode")
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
                            Text("/stats - show relay statistics")
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
                            Text("Protocol: Custom binary over BLE")
                            Text("Encryption: Curve25519 + AES-256-GCM")
                            Text("Range: ~100m direct, 300m+ with relay")
                            Text("Store & Forward: 12h for all, ∞ for favorites")
                            Text("Battery: Adaptive scanning based on level")
                            Text("Platform: Universal (iOS, iPadOS, macOS)")
                            Text("Channels: Password-protected with key commitments")
                            Text("Storage: Keychain for passwords, encrypted retention")
                        }
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(textColor)
                    }
                    
                    // Version
                    HStack {
                        Spacer()
                        Text("Version 1.0.0")
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
                        
                        Text("secure mesh chat")
                            .font(.system(size: 16, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                    
                    // Features
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader("Features")
                        
                        FeatureRow(icon: "wifi.slash", title: "Offline Communication",
                                  description: "Works without internet using Bluetooth mesh networking")
                        
                        FeatureRow(icon: "lock.shield", title: "End-to-End Encryption",
                                  description: "All messages encrypted with Curve25519 + AES-GCM")
                        
                        FeatureRow(icon: "antenna.radiowaves.left.and.right", title: "Extended Range",
                                  description: "Messages relay through peers, reaching 300m+")
                        
                        FeatureRow(icon: "star.fill", title: "Favorites System",
                                  description: "Store-and-forward messages for favorites indefinitely")
                        
                        FeatureRow(icon: "at", title: "Mentions",
                                  description: "Use @nickname to notify specific users")
                        
                        FeatureRow(icon: "number", title: "Channels",
                                  description: "Create #channels for topic-based conversations")
                        
                        FeatureRow(icon: "lock.fill", title: "Password Channels",
                                  description: "Secure channels with passwords and AES encryption")
                    }
                    
                    // Privacy
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader("Privacy")
                        
                        FeatureRow(icon: "eye.slash", title: "No Tracking",
                                  description: "No servers, accounts, or data collection")
                        
                        FeatureRow(icon: "shuffle", title: "Ephemeral Identity",
                                  description: "New peer ID generated each session")
                        
                        FeatureRow(icon: "hand.raised.fill", title: "Panic Mode",
                                  description: "Triple-tap logo to instantly clear all data")
                    }
                    
                    // How to Use
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader("How to Use")
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("• Set your nickname in the header")
                            Text("• Swipe left or tap channel name for sidebar")
                            Text("• Tap a peer to start a private chat")
                            Text("• Use @nickname to mention someone")
                            Text("• Use #channelname to create/join channels")
                            Text("• Triple-tap the logo for panic mode")
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
                            Text("Protocol: Custom binary over BLE")
                            Text("Encryption: Curve25519 + AES-256-GCM")
                            Text("Range: ~100m direct, 300m+ with relay")
                            Text("Store & Forward: 12h for all, ∞ for favorites")
                            Text("Battery: Adaptive scanning based on level")
                            Text("Platform: Universal (iOS, iPadOS, macOS)")
                            Text("Channels: Password-protected with key commitments")
                            Text("Storage: Keychain for passwords, encrypted retention")
                        }
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(textColor)
                    }
                    
                    // Version
                    HStack {
                        Spacer()
                        Text("Version 1.0.0")
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
                    Button("Done") {
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
