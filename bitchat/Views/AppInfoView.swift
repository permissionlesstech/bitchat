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
    // Keep brand and icon names only; all text is localized via keys.
    private enum Strings {
        static let appName = "bitchat" // brand (not localized)
        enum Icons {
            static let offlineComm = "wifi.slash"
            static let encryption = "lock.shield"
            static let extendedRange = "antenna.radiowaves.left.and.right"
            static let mentions = "at"
            static let favorites = "star.fill"
            static let geohash = "number"
            static let noTracking = "eye.slash"
            static let ephemeral = "shuffle"
            static let panic = "hand.raised.fill"
        }
    }
    
    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // Custom header for macOS
            HStack {
                Spacer()
                Button(String(localized: "common.done")) {
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
                    Button(String(localized: "common.close")) {
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
                
                Text(String(localized: "appinfo.tagline"))
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)
            
            // Features
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(String(localized: "appinfo.features.title"))
                
                FeatureRow(icon: Strings.Icons.offlineComm, 
                          title: String(localized: "appinfo.features.offline.title"),
                          description: String(localized: "appinfo.features.offline.desc"))
                
                FeatureRow(icon: Strings.Icons.encryption,
                          title: String(localized: "appinfo.features.encryption.title"),
                          description: String(localized: "appinfo.features.encryption.desc"))
                
                FeatureRow(icon: Strings.Icons.extendedRange,
                          title: String(localized: "appinfo.features.extended_range.title"),
                          description: String(localized: "appinfo.features.extended_range.desc"))
                
                FeatureRow(icon: Strings.Icons.favorites,
                          title: String(localized: "appinfo.features.favorites.title"),
                          description: String(localized: "appinfo.features.favorites.desc"))
                
                FeatureRow(icon: Strings.Icons.geohash,
                          title: String(localized: "appinfo.features.geohash.title"),
                          description: String(localized: "appinfo.features.geohash.desc"))
                
                FeatureRow(icon: Strings.Icons.mentions,
                          title: String(localized: "appinfo.features.mentions.title"),
                          description: String(localized: "appinfo.features.mentions.desc"))
            }
            
            // Privacy
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(String(localized: "appinfo.privacy.title"))
                
                FeatureRow(icon: Strings.Icons.noTracking,
                          title: String(localized: "appinfo.privacy.no_tracking.title"),
                          description: String(localized: "appinfo.privacy.no_tracking.desc"))
                
                FeatureRow(icon: Strings.Icons.ephemeral,
                          title: String(localized: "appinfo.privacy.ephemeral.title"),
                          description: String(localized: "appinfo.privacy.ephemeral.desc"))
                
                FeatureRow(icon: Strings.Icons.panic,
                          title: String(localized: "appinfo.privacy.panic.title"),
                          description: String(localized: "appinfo.privacy.panic.desc"))
            }
            
            // How to Use
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(String(localized: "appinfo.howto.title"))
                
                VStack(alignment: .leading, spacing: 8) {
                    Group {
                        Text(String(localized: "appinfo.howto.bullet.nickname"))
                        Text(String(localized: "appinfo.howto.bullet.mesh"))
                        Text(String(localized: "appinfo.howto.bullet.sidebar"))
                        Text(String(localized: "appinfo.howto.bullet.dm"))
                        Text(String(localized: "appinfo.howto.bullet.clear"))
                        Text(String(localized: "appinfo.howto.bullet.commands"))
                    }
                }
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(textColor)
            }
            
            // Warning
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(String(localized: "appinfo.warning.title"))
                    .foregroundColor(Color.red)
                
                Text(String(localized: "appinfo.warning.message"))
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
