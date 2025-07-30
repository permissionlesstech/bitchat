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
        static let appName = "bitchat"
        static let tagline = "mesh sidegroupchat"
        
        enum Features {
            static let title = "FEATURES"
            static let offlineComm = ("wifi.slash", "offline communication", "works without internet using Bluetooth low energy")
            static let encryption = ("lock.shield", "end-to-end encryption", "private messages encrypted with noise protocol")
            static let extendedRange = ("antenna.radiowaves.left.and.right", "extended range", "messages relay through peers, going the distance")
            static let mentions = ("at", "mentions", "use @nickname to notify specific people")
            static let favorites = ("star.fill", "favorites", "get notified when your favorite people join")
            static let mutualFavorites = ("globe", "mutual favorites", "private message each other via nostr when out of mesh range")
        }
        
        enum Privacy {
            static let title = "PRIVACY"
            static let noTracking = ("eye.slash", "no tracking", "no servers, accounts, or data collection")
            static let ephemeral = ("shuffle", "ephemeral identity", "new peer ID generated regularly")
            static let panic = ("hand.raised.fill", "panic mode", "triple-tap logo to instantly clear all data")
        }
        
        enum HowToUse {
            static let title = "HOW TO USE"
            static let instructions = [
                "• set your nickname by tapping it",
                "• swipe left for sidebar",
                "• tap a peer to start a private chat",
                "• use @nickname to mention someone",
                "• triple-tap chat to clear"
            ]
        }
        
        enum Warning {
            static let title = "WARNING"
            static let message = "private message security has not yet been fully audited. do not use for critical situations until this warning disappears."
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
                
                FeatureRow(icon: Strings.Features.mutualFavorites.0,
                          title: Strings.Features.mutualFavorites.1,
                          description: Strings.Features.mutualFavorites.2)
                
                FeatureRow(icon: Strings.Features.mentions.0,
                          title: Strings.Features.mentions.1,
                          description: Strings.Features.mentions.2)
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
            
            // Warning
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(Strings.Warning.title)
                    .foregroundColor(Color.red)
                
                Text(Strings.Warning.message)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
            .padding(.bottom, 16)
            .padding(.horizontal)
            .background(Color.red.opacity(0.1))
            .cornerRadius(8)
            
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
