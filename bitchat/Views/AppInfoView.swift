import SwiftUI

/// The sheet behind the "bitchat/" logo: a segmented Settings/Info surface.
/// Settings gathers every user preference (appearance, voice, connectivity
/// toggles, panic wipe); Info keeps the about content (how-to, features,
/// privacy, symbols legend).
struct AppInfoView: View {
    @Environment(\.dismiss) var dismiss
    @ThemedPalette private var palette
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.matrix.rawValue
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @ObservedObject private var bridgeService = BridgeService.shared

    /// Supplies the mesh topology map data. Nil (previews, missing wiring)
    /// hides the topology row entirely.
    var topologyProvider: (@MainActor () -> MeshTopologyDisplayModel)?
    /// Wipes all local data. Nil (previews, missing wiring) hides the danger
    /// zone entirely.
    var onPanicWipe: (@MainActor () -> Void)?

    @State private var showTopology = false
    @State private var liveVoiceEnabled = PTTSettings.liveVoiceEnabled
    @State private var locationNotesEnabled = LocationNotesSettings.enabled
    @ObservedObject private var locationManager = LocationChannelManager.shared
    /// Sticky across opens: first-ever open lands on Info (the gentler
    /// introduction), and afterwards the sheet reopens wherever it was left.
    @AppStorage("appInfo.selectedPane") private var selectedPane: Pane = .info
    @State private var showPanicConfirmation = false

    private enum Pane: String {
        case settings
        case info
    }

    private var selectedTheme: AppTheme {
        AppTheme(rawValue: appThemeRawValue) ?? .matrix
    }

    private var textColor: Color { palette.primary }

    private var secondaryTextColor: Color { palette.secondary }

    // MARK: - Constants
    private enum Strings {
        static let appName: LocalizedStringKey = "app_info.app_name"
        static let tagline: LocalizedStringKey = "app_info.tagline"
        static let appearanceTitle: LocalizedStringKey = "app_info.appearance.title"

        /// New keys carry their English copy inline (defaultValue) until the
        /// i18n pass lands them in the catalog; moved keys keep their homes.
        enum Settings {
            static let tabPickerLabel = String(localized: "app_info.tab.picker_label", defaultValue: "view", comment: "Accessibility label for the segmented control switching between the settings and info panes of the app info sheet")
            static let tabSettings = String(localized: "app_info.tab.settings", defaultValue: "settings", comment: "Segmented control label for the settings pane of the app info sheet")
            static let tabInfo = String(localized: "app_info.tab.info", defaultValue: "info", comment: "Segmented control label for the info pane of the app info sheet")

            static let connectivityTitle = String(localized: "app_info.settings.connectivity.title", defaultValue: "CONNECTIVITY", comment: "Section header (uppercase) for the connectivity toggles: mesh bridge, internet gateway, tor routing")

            static let bridgeTitle = String(localized: "app_info.settings.bridge.title", defaultValue: "mesh bridge", comment: "Title of the mesh bridge toggle in settings")
            static let bridgeSubtitle = String(localized: "app_info.settings.bridge.subtitle", defaultValue: "joins nearby mesh islands over the internet: what you say in the mesh channel also reaches people in your area beyond radio range, and their messages appear here marked with the network glyph. while you have internet, your device also carries bridge and location-channel traffic for phones around you that have none.", comment: "Subtitle explaining what the mesh bridge toggle does")
            static func bridgeCell(_ cell: String) -> String {
                String(
                    format: String(localized: "app_info.settings.bridge.cell", defaultValue: "rendezvous cell: %@", comment: "Caption under the mesh bridge toggle showing the geohash cell the bridge is meeting on"),
                    locale: .current,
                    cell
                )
            }
            static let bridgeNoCell = String(localized: "app_info.settings.bridge.no_cell", defaultValue: "no rendezvous cell yet — needs location access or a nearby bridge peer", comment: "Caption under the mesh bridge toggle when the bridge is on but has no geohash cell to meet on")

            // Moved from LocationChannelsSheet; keys unchanged. (The former
            // internet-gateway toggle is gone: the bridge switch drives all
            // internet sharing, including geohash-channel gatewaying.)
            static let torTitle: LocalizedStringKey = "location_channels.tor.title"
            static let torSubtitle: LocalizedStringKey = "location_channels.tor.subtitle"
            static let toggleOn: LocalizedStringKey = "common.toggle.on"
            static let toggleOff: LocalizedStringKey = "common.toggle.off"

            static let dangerTitle = String(localized: "app_info.settings.danger.title", defaultValue: "DANGER ZONE", comment: "Section header (uppercase) for destructive actions in settings")
            static let panicButton = String(localized: "app_info.settings.danger.panic_button", defaultValue: "panic wipe", comment: "Button in the settings danger zone that erases all local data after confirmation")
            static let panicNote = String(localized: "app_info.settings.danger.panic_note", defaultValue: "erases all messages, keys, and identity. triple-tapping the bitchat/ logo does the same, instantly.", comment: "Caption under the panic wipe button explaining what it does and the triple-tap shortcut")
            static let panicConfirmTitle = String(localized: "app_info.settings.danger.panic_confirm_title", defaultValue: "wipe all data?", comment: "Title of the confirmation dialog before a panic wipe")
            static let panicConfirmAction = String(localized: "app_info.settings.danger.panic_confirm_action", defaultValue: "wipe everything", comment: "Destructive confirmation button that performs the panic wipe")
        }

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
            static let bridge = AppInfoFeatureInfo(
                icon: "network",
                resolvedTitle: String(localized: "app_info.features.bridge.title", defaultValue: "mesh bridging", comment: "Feature row title for the mesh bridge in the app info sheet"),
                resolvedDescription: String(localized: "app_info.features.bridge.description", defaultValue: "links nearby mesh islands through the internet so one crowd isn't split by radio range", comment: "Feature row description for the mesh bridge in the app info sheet")
            )
        }

        enum Legend {
            static let title: LocalizedStringKey = "app_info.legend.title"
            /// Every glyph the peer lists and headers use, in one place —
            /// nothing else in the app defines them. A nil color renders in
            /// the theme's primary text color.
            static let items: [(icon: String, color: Color?, text: String)] = [
                ("antenna.radiowaves.left.and.right", nil, String(localized: "app_info.legend.mesh_connected")),
                ("point.3.filled.connected.trianglepath.dotted", nil, String(localized: "app_info.legend.mesh_relayed")),
                ("globe", nil, String(localized: "app_info.legend.nostr")),
                ("network", Color.cyan, String(localized: "app_info.legend.bridged", defaultValue: "message arrived across a mesh bridge", comment: "Symbols legend entry for the cyan network glyph shown on messages carried across a mesh bridge")),
                ("person", nil, String(localized: "app_info.legend.offline")),
                ("mappin.and.ellipse", nil, String(localized: "app_info.legend.location_nearby")),
                ("face.dashed", nil, String(localized: "app_info.legend.teleported")),
                ("lock.fill", nil, String(localized: "app_info.legend.encrypted")),
                ("lock.slash", nil, String(localized: "app_info.legend.encryption_failed")),
                ("checkmark.seal.fill", nil, String(localized: "app_info.legend.verified")),
                ("star.fill", nil, String(localized: "app_info.legend.favorite")),
                ("envelope.fill", nil, String(localized: "app_info.legend.unread")),
                ("nosign", nil, String(localized: "app_info.legend.blocked"))
            ]
        }

        enum Voice {
            static let title: LocalizedStringKey = "app_info.voice.title"
            // The live-voice title/description keys are referenced inline at
            // the toggle (they ride the shared settingToggle now).
        }

        enum Location {
            static let notes = AppInfoFeatureInfo(
                icon: "mappin.and.ellipse",
                title: "app_info.location.notes.title",
                description: "app_info.location.notes.description"
            )
        }

        enum Network {
            static let title: LocalizedStringKey = "app_info.network.title"
            static let topology = AppInfoFeatureInfo(
                icon: "point.3.connected.trianglepath.dotted",
                title: "app_info.network.topology.title",
                description: "app_info.network.topology.description"
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
            /// The instruction strings flowed into one comma-separated
            /// paragraph. The translations carry their legacy bullet-list
            /// prefix ("• "), so it is stripped here.
            static var paragraph: String {
                [
                    String(localized: "app_info.how_to_use.set_nickname"),
                    String(localized: "app_info.how_to_use.change_channels"),
                    String(localized: "app_info.how_to_use.open_sidebar"),
                    String(localized: "app_info.how_to_use.start_dm"),
                    String(localized: "app_info.how_to_use.clear_chat"),
                    String(localized: "app_info.how_to_use.commands")
                ]
                .map { $0.hasPrefix("• ") ? String($0.dropFirst(2)) : $0 }
                .joined(separator: ", ")
            }
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

            VStack(spacing: 0) {
                panePicker

                ScrollView {
                    paneContent
                }
            }
            .themedSheetBackground()
        }
        .frame(width: 600, height: 700)
        .sheet(isPresented: $showTopology) {
            if let topologyProvider {
                MeshTopologyView(provider: topologyProvider)
            }
        }
        #else
        NavigationView {
            VStack(spacing: 0) {
                panePicker

                ScrollView {
                    paneContent
                }
            }
            .themedSheetBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    SheetCloseButton { dismiss() }
                        .foregroundColor(textColor)
                }
            }
        }
        .sheet(isPresented: $showTopology) {
            if let topologyProvider {
                MeshTopologyView(provider: topologyProvider)
            }
        }
        #endif
    }

    // MARK: - Pane switching

    private var panePicker: some View {
        Picker(Strings.Settings.tabPickerLabel, selection: $selectedPane) {
            Text(Strings.Settings.tabInfo).tag(Pane.info)
            Text(Strings.Settings.tabSettings).tag(Pane.settings)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .settings:
            settingsContent
        case .info:
            infoContent
        }
    }

    // MARK: - Settings pane

    @ViewBuilder
    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 24) {
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

            // Voice — same card + IRC pill as every other toggle setting.
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(Strings.Voice.title)

                settingsCard {
                    settingToggle(
                        title: Text("app_info.voice.live.title"),
                        subtitle: Text("app_info.voice.live.description"),
                        isOn: Binding(
                            get: { liveVoiceEnabled },
                            set: { newValue in
                                liveVoiceEnabled = newValue
                                PTTSettings.liveVoiceEnabled = newValue
                            }
                        )
                    )
                }
            }

            // Connectivity: mesh bridge, internet gateway, tor routing
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(verbatim: Strings.Settings.connectivityTitle)

                settingsCard {
                    settingToggle(
                        title: Text(Strings.Settings.bridgeTitle),
                        subtitle: Text(Strings.Settings.bridgeSubtitle),
                        isOn: bridgeToggleBinding
                    )
                    // Where the bridge meets: the geohash rendezvous cell, or
                    // a hint about why there isn't one yet (no location and no
                    // bridge peer advertising a cell).
                    if bridgeService.isEnabled {
                        Text(bridgeService.activeCell.map(Strings.Settings.bridgeCell) ?? Strings.Settings.bridgeNoCell)
                            .bitchatFont(size: 11)
                            .foregroundColor(secondaryTextColor)
                    }
                }

                settingsCard {
                    settingToggle(
                        title: Text(Strings.Settings.torTitle),
                        subtitle: Text(Strings.Settings.torSubtitle),
                        isOn: torToggleBinding
                    )
                }

                // Location notes / dead drops (merged from main's flat
                // layout into the shared card + pill style). Turning it on
                // may need the location prompt; the permission control below
                // covers the denied path.
                settingsCard {
                    settingToggle(
                        title: Strings.Location.notes.title,
                        subtitle: Strings.Location.notes.description,
                        isOn: Binding(
                            get: { locationNotesEnabled },
                            set: { newValue in
                                locationNotesEnabled = newValue
                                LocationNotesSettings.enabled = newValue
                                if newValue {
                                    locationManager.enableLocationChannels()
                                }
                            }
                        )
                    )
                }

                // Location powers the channels list and the bridge cell, so
                // its control lives with the other connectivity settings.
                // Platform reality shapes the three states: the app may only
                // prompt while never-asked; granted/denied both flip in the
                // system permission screen.
                switch locationChannelsModel.permissionState {
                case .authorized:
                    Button(action: SystemSettings.location.open) {
                        Text("location_channels.action.remove_access")
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.alertRed)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                case .notDetermined:
                    Button(action: { locationChannelsModel.enableLocationChannels() }) {
                        Text("location_channels.action.request_permissions")
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(palette.accent.opacity(0.12))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                case .denied, .restricted:
                    settingsCard {
                        Text("location_channels.permission_denied")
                            .bitchatFont(size: 11)
                            .foregroundColor(secondaryTextColor)
                        Button("location_channels.action.open_settings", action: SystemSettings.location.open)
                            .buttonStyle(.plain)
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.accent)
                    }
                }
            }

            // Danger zone
            if onPanicWipe != nil {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(verbatim: Strings.Settings.dangerTitle)

                    Button(action: { showPanicConfirmation = true }) {
                        Text(Strings.Settings.panicButton)
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.alertRed)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog(
                        Strings.Settings.panicConfirmTitle,
                        isPresented: $showPanicConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(Strings.Settings.panicConfirmAction, role: .destructive) {
                            onPanicWipe?()
                        }
                        Button("common.cancel", role: .cancel) {}
                    }

                    Text(Strings.Settings.panicNote)
                        .bitchatFont(size: 11)
                        .foregroundColor(secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding()
    }

    private var bridgeToggleBinding: Binding<Bool> {
        Binding(
            get: { bridgeService.isEnabled },
            set: { bridgeService.setEnabled($0) }
        )
    }

    private var torToggleBinding: Binding<Bool> {
        Binding(
            get: { locationChannelsModel.userTorEnabled },
            set: { locationChannelsModel.setUserTorEnabled($0) }
        )
    }

    /// The padded card every connectivity setting sits in (moved look from
    /// LocationChannelsSheet's toggle sections).
    private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(12)
            .background(palette.secondary.opacity(0.12))
            .cornerRadius(8)
    }

    /// A title+subtitle row driving an IRC-style on/off pill — the one
    /// toggle style every setting uses.
    private func settingToggle(title: Text, subtitle: Text, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .bitchatFont(size: 12, weight: .semibold)
                    .foregroundColor(textColor)
                subtitle
                    .bitchatFont(size: 11)
                    .foregroundColor(secondaryTextColor)
            }
        }
        .toggleStyle(IRCToggleStyle(accent: palette.accent, onLabel: Strings.Settings.toggleOn, offLabel: Strings.Settings.toggleOff))
    }

    // MARK: - Info pane

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

            // How to Use
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.HowToUse.title)

                Text(verbatim: Strings.HowToUse.paragraph)
                    .bitchatFont(size: 14)
                    .foregroundColor(textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Network diagnostics
            if topologyProvider != nil {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader(Strings.Network.title)

                    Button {
                        showTopology = true
                    } label: {
                        HStack(spacing: 0) {
                            FeatureRow(info: Strings.Network.topology)
                            Image(systemName: "chevron.right")
                                .font(.bitchatSystem(size: 12))
                                .foregroundColor(secondaryTextColor)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("app_info.network.topology.hint"))
                }
            }

            // Features
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.Features.title)

                FeatureRow(info: Strings.Features.offlineComm)

                FeatureRow(info: Strings.Features.encryption)

                FeatureRow(info: Strings.Features.extendedRange)

                FeatureRow(info: Strings.Features.bridge)

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

            // Symbols legend
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(Strings.Legend.title)

                ForEach(Strings.Legend.items, id: \.icon) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(item.color ?? textColor)
                            .frame(width: 30)

                        Text(item.text)
                            .bitchatFont(size: 13)
                            .foregroundColor(secondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding()
    }
}

struct AppInfoFeatureInfo {
    let icon: String
    let title: Text
    let description: Text

    /// Catalog-backed strings (existing keys).
    init(icon: String, title: LocalizedStringKey, description: LocalizedStringKey) {
        self.icon = icon
        self.title = Text(title)
        self.description = Text(description)
    }

    /// Pre-resolved strings — new keys that carry their English defaultValue
    /// inline until the i18n pass adds them to the catalog.
    init(icon: String, resolvedTitle: String, resolvedDescription: String) {
        self.icon = icon
        self.title = Text(resolvedTitle)
        self.description = Text(resolvedDescription)
    }
}

struct SectionHeader: View {
    private let title: Text
    @ThemedPalette private var palette

    private var textColor: Color { palette.primary }

    init(_ title: LocalizedStringKey) {
        self.title = Text(title)
    }

    /// For pre-resolved strings (new keys with inline defaultValue).
    init(verbatim title: String) {
        self.title = Text(title)
    }

    var body: some View {
        title
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
                info.title
                    .bitchatFont(size: 14, weight: .semibold)
                    .foregroundColor(textColor)

                info.description
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
        .environmentObject(LocationChannelsModel())
}

#Preview("Dynamic Type XXL") {
    AppInfoView()
        .environmentObject(LocationChannelsModel())
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}

#Preview("Dynamic Type XS") {
    AppInfoView()
        .environmentObject(LocationChannelsModel())
        .environment(\.sizeCategory, .extraSmall)
}
