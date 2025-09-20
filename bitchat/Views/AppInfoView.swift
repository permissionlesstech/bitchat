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
        static let tagline = String(localized: "appinfo.tagline")
        
        enum Features {
            static let title = String(localized: "appinfo.features.title")
            static let offlineComm = ("wifi.slash", String(localized: "appinfo.feature.offline_comm"), String(localized: "appinfo.feature.offline_comm_desc"))
            static let encryption = ("lock.shield", String(localized: "appinfo.feature.encryption"), String(localized: "appinfo.feature.encryption_desc"))
            static let extendedRange = ("antenna.radiowaves.left.and.right", String(localized: "appinfo.feature.extended_range"), String(localized: "appinfo.feature.extended_range_desc"))
            static let mentions = ("at", String(localized: "appinfo.feature.mentions"), String(localized: "appinfo.feature.mentions_desc"))
            static let favorites = ("star.fill", String(localized: "appinfo.feature.favorites"), String(localized: "appinfo.feature.favorites_desc"))
            static let geohash = ("number", String(localized: "appinfo.feature.geohash"), String(localized: "appinfo.feature.geohash_desc"))
        }
        
        enum Privacy {
            static let title = String(localized: "appinfo.privacy.title")
            static let noTracking = ("eye.slash", String(localized: "appinfo.privacy.no_tracking"), String(localized: "appinfo.privacy.no_tracking_desc"))
            static let ephemeral = ("shuffle", String(localized: "appinfo.privacy.ephemeral"), String(localized: "appinfo.privacy.ephemeral_desc"))
            static let panic = ("hand.raised.fill", String(localized: "appinfo.privacy.panic"), String(localized: "appinfo.privacy.panic_desc"))
        }
        
        enum HowToUse {
            static let title = String(localized: "appinfo.howtouse.title")
        }
        
        enum Warning {
            static let title = String(localized: "appinfo.warning.title")
            static let message = String(localized: "appinfo.warning.message")
        }
    }
    
    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // Custom header for macOS
            HStack {
                Spacer()
                Button(action: {
                    dismiss()
                }) {
                    Text(String(localized: "nav.done"))
                        .accessibilityLabel(String(localized: "accessibility.button.done"))
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
                    Button(action: {
                        dismiss()
                    }) {
                        Text(String(localized: "nav.close"))
                            .accessibilityLabel(String(localized: "accessibility.button.close"))
                    }
                    .buttonStyle(.plain)
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
                
                FeatureRow(icon: "wifi.slash", 
                          title: String(localized: "appinfo.features.offline.title"),
                          description: String(localized: "appinfo.features.offline.desc"))
                
                FeatureRow(icon: "lock.shield",
                          title: String(localized: "appinfo.features.encryption.title"),
                          description: String(localized: "appinfo.features.encryption.desc"))
                
                FeatureRow(icon: Strings.Features.extendedRange.0,
                          title: String(localized: "appinfo.features.extended_range.title"),
                          description: String(localized: "appinfo.features.extended_range.desc"))
                
                FeatureRow(icon: Strings.Features.favorites.0,
                          title: String(localized: "appinfo.features.favorites.title"),
                          description: String(localized: "appinfo.features.favorites.desc"))
                
                FeatureRow(icon: Strings.Features.geohash.0,
                          title: String(localized: "appinfo.features.geohash.title"),
                          description: String(localized: "appinfo.features.geohash.desc"))
                
                FeatureRow(icon: Strings.Features.mentions.0,
                          title: String(localized: "appinfo.features.mentions.title"),
                          description: String(localized: "appinfo.features.mentions.desc"))
            }
            
            // Privacy
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(String(localized: "appinfo.privacy.title"))
                
                FeatureRow(icon: Strings.Privacy.noTracking.0,
                          title: String(localized: "appinfo.privacy.no_tracking.title"),
                          description: String(localized: "appinfo.privacy.no_tracking.desc"))
                
                FeatureRow(icon: Strings.Privacy.ephemeral.0,
                          title: String(localized: "appinfo.privacy.ephemeral.title"),
                          description: String(localized: "appinfo.privacy.ephemeral.desc"))
                
                FeatureRow(icon: Strings.Privacy.panic.0,
                          title: String(localized: "appinfo.privacy.panic.title"),
                          description: String(localized: "appinfo.privacy.panic.desc"))
            }
            
            // How to Use
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(String(localized: "appinfo.howto.title"))
                
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "appinfo.howto.set_nickname"))
                    Text(String(localized: "appinfo.howto.tap_mesh"))
                    Text(String(localized: "appinfo.howto.open_sidebar"))
                    Text(String(localized: "appinfo.howto.start_dm"))
                    Text(String(localized: "appinfo.howto.clear_chat"))
                    Text(String(localized: "appinfo.howto.commands"))
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
