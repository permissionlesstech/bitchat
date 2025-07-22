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
    
    // MARK: - Constants
    private enum Strings {
        static let appName = "bitchat/"
        static let tagline = "mesh sidegroupchat"
        
        enum Features {
            static let title = "FEATURES"
            static let offlineComm = ("wifi.slash", "offline communication", "works without internet using Bluetooth mesh networking")
            static let encryption = ("lock.shield", "end-to-end encryption", "private messages encrypted with noise protocol")
            static let extendedRange = ("antenna.radiowaves.left.and.right", "extended range", "messages relay through peers, increasing the distance")
            static let favorites = ("star.fill", "favorites", "store-and-forward messages for favorite people")
            static let mentions = ("at", "mentions", "use @nickname to notify specific people")
            static let channels = ("number", "channels", "create #channels for topic-based conversations")
            static let privateChannels = ("lock.fill", "private channels", "secure channels with passwords and noise encryption")
        }
        
        enum Privacy {
            static let title = "PRIVACY"
            static let noTracking = ("eye.slash", "no tracking", "no servers, accounts, or data collection")
            static let ephemeral = ("shuffle", "ephemeral identity", "new peer ID generated each session")
            static let panic = ("hand.raised.fill", "panic mode", "triple-tap logo to instantly clear all data")
        }
        
        enum HowToUse {
            static let title = "HOW TO USE"
            static let instructions = [
                "• set your nickname by tapping it",
                "• swipe left for sidebar",
                "• tap a peer to start a private chat",
                "• use @nickname to mention someone",
                "• use #channelname to create/join channels",
                "• triple-tap \"bitchat\" for panic mode",
                "• triple-tap chat messages to clear current chat"
            ]
        }
        
        enum Commands {
            static let title = "COMMANDS"
            static let list = [
                "/j #channel - join or create a channel",
                "/m @name - send private message",
                "/w - see who's online",
                "/channels - show all discovered channels",
                "/block @name - block a peer",
                "/block - list blocked peers",
                "/unblock @name - unblock a peer",
                "/clear - clear current chat",
                "/hug @name - send someone a hug",
                "/slap @name - slap with a trout"
            ]
        }
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
                infoContent
            }
            .background(backgroundColor)
        }
        .frame(width: 600, height: 700)
        #else
        NavigationView {
            ScrollView {
                infoContent
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
    
    @ViewBuilder
    private var infoContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            VStack(alignment: .center, spacing: 8) {
                Text(Strings.appName)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundColor(textColor)
                
                Text(Strings.tagline)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)
            
            // Features
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.Features.title)
                
                FeatureRow(icon: Strings.Features.offlineComm.0, 
                          title: Strings.Features.offlineComm.1,
                          description: Strings.Features.offlineComm.2)
                
                FeatureRow(icon: Strings.Features.encryption.0,
                          title: Strings.Features.encryption.1,
                          description: Strings.Features.encryption.2)
                
                FeatureRow(icon: Strings.Features.extendedRange.0,
                          title: Strings.Features.extendedRange.1,
                          description: Strings.Features.extendedRange.2)
                
                FeatureRow(icon: Strings.Features.favorites.0,
                          title: Strings.Features.favorites.1,
                          description: Strings.Features.favorites.2)
                
                FeatureRow(icon: Strings.Features.mentions.0,
                          title: Strings.Features.mentions.1,
                          description: Strings.Features.mentions.2)
                
                FeatureRow(icon: Strings.Features.channels.0,
                          title: Strings.Features.channels.1,
                          description: Strings.Features.channels.2)
                
                FeatureRow(icon: Strings.Features.privateChannels.0,
                          title: Strings.Features.privateChannels.1,
                          description: Strings.Features.privateChannels.2)
            }
            
            // Privacy
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.Privacy.title)
                
                FeatureRow(icon: Strings.Privacy.noTracking.0,
                          title: Strings.Privacy.noTracking.1,
                          description: Strings.Privacy.noTracking.2)
                
                FeatureRow(icon: Strings.Privacy.ephemeral.0,
                          title: Strings.Privacy.ephemeral.1,
                          description: Strings.Privacy.ephemeral.2)
                
                FeatureRow(icon: Strings.Privacy.panic.0,
                          title: Strings.Privacy.panic.1,
                          description: Strings.Privacy.panic.2)
            }
            
            // How to Use
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.HowToUse.title)
                
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Strings.HowToUse.instructions, id: \.self) { instruction in
                        Text(instruction)
                    }
                }
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(textColor)
            }
            
            // Commands
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.Commands.title)
                
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Strings.Commands.list, id: \.self) { command in
                        Text(command)
                    }
                }
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(textColor)
            }
            
            .padding(.top)
        }
        .padding()
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
        Text(title)
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
