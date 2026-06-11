import SwiftUI

struct AppInfoView: View {
    @Environment(\.dismiss) var dismiss
    @ThemedPalette private var palette
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.matrix.rawValue

    private var selectedTheme: AppTheme {
        AppTheme(rawValue: appThemeRawValue) ?? .matrix
    }

    private var backgroundColor: Color { palette.background }

    private var textColor: Color { palette.primary }

    private var secondaryTextColor: Color { palette.secondary }
    
    // MARK: - Constants
    private enum Strings {
        static let appName: LocalizedStringKey = "app_info.app_name"
        static let tagline: LocalizedStringKey = "app_info.tagline"
        static let appearanceTitle: LocalizedStringKey = "app_info.appearance.title"

        enum Features {
            static let title: LocalizedStringKey = "app_info.features.title"
            static let offlineComm = AppInfoFeatureInfo(
                icon: "wifi.slash",
                title: "app_info.features.offline.title",
                description: "app_info.features.offline.description"
            )
            static let encryption = AppInfoFeatureInfo(
                icon: "lock.shield",
                title: "app_info.features.encryption.title",
                description: "app_info.features.encryption.description"
            )
            static let extendedRange = AppInfoFeatureInfo(
                icon: "antenna.radiowaves.left.and.right",
                title: "app_info.features.extended_range.title",
                description: "app_info.features.extended_range.description"
            )
            static let mentions = AppInfoFeatureInfo(
                icon: "at",
                title: "app_info.features.mentions.title",
                description: "app_info.features.mentions.description"
            )
            static let favorites = AppInfoFeatureInfo(
                icon: "star.fill",
                title: "app_info.features.favorites.title",
                description: "app_info.features.favorites.description"
            )
            static let geohash = AppInfoFeatureInfo(
                icon: "number",
                title: "app_info.features.geohash.title",
                description: "app_info.features.geohash.description"
            )
        }

        enum Privacy {
            static let title: LocalizedStringKey = "app_info.privacy.title"
            static let noTracking = AppInfoFeatureInfo(
                icon: "eye.slash",
                title: "app_info.privacy.no_tracking.title",
                description: "app_info.privacy.no_tracking.description"
            )
            static let ephemeral = AppInfoFeatureInfo(
                icon: "shuffle",
                title: "app_info.privacy.ephemeral.title",
                description: "app_info.privacy.ephemeral.description"
            )
            static let panic = AppInfoFeatureInfo(
                icon: "hand.raised.fill",
                title: "app_info.privacy.panic.title",
                description: "app_info.privacy.panic.description"
            )
        }

        enum HowToUse {
            static let title: LocalizedStringKey = "app_info.how_to_use.title"
            static let instructions: [LocalizedStringKey] = [
                "app_info.how_to_use.set_nickname",
                "app_info.how_to_use.change_channels",
                "app_info.how_to_use.open_sidebar",
                "app_info.how_to_use.start_dm",
                "app_info.how_to_use.clear_chat",
                "app_info.how_to_use.commands"
            ]
        }

    }
    
    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // Custom header for macOS
            HStack {
                Spacer()
                Button("app_info.done") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(textColor)
                .padding()
            }
            .themedSurface(opacity: 0.95)

            ScrollView {
                infoContent
            }
            .themedSheetBackground()
        }
        .frame(width: 600, height: 700)
        #else
        NavigationView {
            ScrollView {
                infoContent
            }
            .themedSheetBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .bitchatFont(size: 13, weight: .semibold)
                            .foregroundColor(textColor)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("app_info.close")
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
                    .bitchatFont(size: 32, weight: .bold)
                    .foregroundColor(textColor)
                
                Text(Strings.tagline)
                    .bitchatFont(size: 16)
                    .foregroundColor(secondaryTextColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)

            // Appearance — single row: label left, theme chips right
            HStack(spacing: 12) {
                SectionHeader(Strings.appearanceTitle)
                Spacer()
                ForEach(AppTheme.allCases) { theme in
                    Button {
                        appThemeRawValue = theme.rawValue
                    } label: {
                        Text(theme.displayNameKey)
                            .bitchatFont(size: 13, weight: selectedTheme == theme ? .semibold : .regular)
                            .foregroundColor(selectedTheme == theme ? palette.accent : secondaryTextColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selectedTheme == theme ? palette.accent.opacity(0.15) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedTheme == theme ? .isSelected : [])
                }
            }

            // How to Use
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.HowToUse.title)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(Strings.HowToUse.instructions.enumerated()), id: \.offset) { _, instruction in
                        Text(instruction)
                    }
                }
                .bitchatFont(size: 14)
                .foregroundColor(textColor)
            }

            // Features
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.Features.title)

                FeatureRow(info: Strings.Features.offlineComm)

                FeatureRow(info: Strings.Features.encryption)

                FeatureRow(info: Strings.Features.extendedRange)

                FeatureRow(info: Strings.Features.favorites)

                FeatureRow(info: Strings.Features.geohash)

                FeatureRow(info: Strings.Features.mentions)
            }

            // Privacy
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.Privacy.title)

                FeatureRow(info: Strings.Privacy.noTracking)

                FeatureRow(info: Strings.Privacy.ephemeral)

                FeatureRow(info: Strings.Privacy.panic)
            }
        }
        .padding()
    }
}

struct AppInfoFeatureInfo {
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey
}

struct SectionHeader: View {
    let title: LocalizedStringKey
    @ThemedPalette private var palette

    private var textColor: Color { palette.primary }

    init(_ title: LocalizedStringKey) {
        self.title = title
    }
    
    var body: some View {
        Text(title)
            .bitchatFont(size: 16, weight: .bold)
            .foregroundColor(textColor)
            .padding(.top, 8)
    }
}

struct FeatureRow: View {
    let info: AppInfoFeatureInfo
    @ThemedPalette private var palette

    private var textColor: Color { palette.primary }

    private var secondaryTextColor: Color { palette.secondary }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: info.icon)
                .font(.bitchatSystem(size: 20))
                .foregroundColor(textColor)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title)
                    .bitchatFont(size: 14, weight: .semibold)
                    .foregroundColor(textColor)
                
                Text(info.description)
                    .bitchatFont(size: 12)
                    .foregroundColor(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
    }
}

#Preview("Default") {
    AppInfoView()
}

#Preview("Dynamic Type XXL") {
    AppInfoView()
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}

#Preview("Dynamic Type XS") {
    AppInfoView()
        .environment(\.sizeCategory, .extraSmall)
}
