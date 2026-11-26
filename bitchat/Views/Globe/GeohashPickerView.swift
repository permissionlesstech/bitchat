//
// GeohashPickerView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Full-screen 3D globe for choosing a geohash channel to teleport to. The cell under
/// the crosshair is the selection; zooming changes precision. Live chat activity is
/// drawn as markers: tapping one flies to its channel, tapping a cluster zooms in and
/// lists its busiest channels.
struct GeohashPickerView: View {
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @StateObject private var state: GlobeState
    @StateObject private var activity: GeohashActivityMonitor
    @State private var world: GlobeWorldData?
    @State private var markerLayer = GlobeMarkerLayer()
    /// Geohashes of a tapped cluster, listed in the card until one is chosen.
    @State private var cluster: [String]?
    @State private var hasInteracted = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette

    private enum Strings {
        static let noSelection = String(localized: "geohash_picker.no_selection", defaultValue: "select location", comment: "Shown in the globe geohash picker before a geohash is under the crosshair")
        static let join = String(localized: "geohash_picker.join", defaultValue: "join", comment: "Button in the globe geohash picker that teleports to the geohash under the crosshair")
        static let live = String(localized: "geohash_picker.status.live", defaultValue: "live", comment: "Status chip in the globe geohash picker while activity from relays is streaming in")
        static let connecting = String(localized: "geohash_picker.status.connecting", defaultValue: "connecting", comment: "Status chip in the globe geohash picker while relays are connecting")
        static let offline = String(localized: "geohash_picker.status.offline", defaultValue: "offline", comment: "Status chip in the globe geohash picker when no relay could be reached")
        static let hintSpin = String(localized: "geohash_picker.hint.spin", defaultValue: "spin", comment: "Gesture hint in the globe geohash picker: drag to spin the globe")
        static let hintZoom = String(localized: "geohash_picker.hint.zoom", defaultValue: "zoom", comment: "Gesture hint in the globe geohash picker: pinch to zoom")
        static let hintTapDot = String(localized: "geohash_picker.hint.tap_dot", defaultValue: "tap a dot", comment: "Gesture hint in the globe geohash picker: tap an activity marker to fly to that chat")
        static let noActivity = String(localized: "geohash_picker.no_activity", defaultValue: "no recent activity", comment: "Shown in the globe geohash picker when nobody was active in the selected geohash recently")
        static let wholeGlobe = String(localized: "geohash_picker.accessibility.whole_globe", defaultValue: "show the whole globe", comment: "Accessibility label for the globe picker button that zooms out to the whole globe")
        static let decreasePrecision = String(localized: "geohash_picker.accessibility.decrease_precision", defaultValue: "decrease precision", comment: "Accessibility label for the globe picker button that zooms out to a larger geohash cell")
        static let increasePrecision = String(localized: "geohash_picker.accessibility.increase_precision", defaultValue: "increase precision", comment: "Accessibility label for the globe picker button that zooms in to a smaller geohash cell")
        static let close = String(localized: "common.close", comment: "Accessibility label for close buttons")

        static func precision(_ length: Int) -> String {
            String(
                format: String(localized: "geohash_picker.accessibility.precision", defaultValue: "geohash length %lld", comment: "Accessibility label for the globe picker's current geohash length; %lld is the number of characters"),
                locale: .current,
                length
            )
        }

        static func globeActivity(chats: Int, people: Int) -> String {
            String(
                format: String(localized: "geohash_picker.accessibility.globe_activity", defaultValue: "%1$lld active chats, %2$lld people online", comment: "Accessibility label for the globe picker's live status chip; %1$lld is the number of channels with chat in the last hour, %2$lld the estimated people online"),
                locale: .current,
                chats, people
            )
        }

        static func channelActivity(people: Int, messages: Int) -> String {
            String(
                format: String(localized: "geohash_picker.accessibility.channel_activity", defaultValue: "%1$lld people, %2$lld messages in the last hour", comment: "Accessibility label for a geohash channel's activity in the globe picker; %1$lld is people, %2$lld chat messages in the last hour"),
                locale: .current,
                people, messages
            )
        }

        static func clusterSummary(channels: Int, people: Int) -> String {
            String(
                format: String(localized: "geohash_picker.accessibility.cluster", defaultValue: "%1$lld channels, %2$lld people", comment: "Accessibility label for the header of a tapped cluster of channels in the globe picker; %1$lld is channels, %2$lld estimated people"),
                locale: .current,
                channels, people
            )
        }
    }

    /// - Parameters:
    ///   - initialGeohash: where the opening spin comes to rest; when empty, the
    ///     coarsest of `nearbyGeohashes`, else a default view. The picker always
    ///     opens on the whole globe (precision 1), so the world's activity is in view.
    ///   - isBlocked: hides blocked identities from activity counts, as the
    ///     channel sheet does.
    ///   - activityMonitor: injected for previews and tests.
    init(
        initialGeohash: String?,
        nearbyGeohashes: [String] = [],
        isBlocked: @escaping (String) -> Bool = { _ in false },
        activityMonitor: GeohashActivityMonitor? = nil,
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onCancel = onCancel
        let target = Self.initialTarget(initialGeohash: initialGeohash, nearbyGeohashes: nearbyGeohashes)
        _state = StateObject(wrappedValue: GlobeState(
            targetLat: target.lat,
            targetLon: target.lon,
            initialPrecision: 1,
            startZoomedOut: true
        ))
        _activity = StateObject(wrappedValue: activityMonitor ?? GeohashActivityMonitor(isBlocked: isBlocked))
    }

    /// Where the opening spin turns the globe: the given geohash, else the coarsest
    /// nearby channel, else a default view.
    static func initialTarget(initialGeohash: String?, nearbyGeohashes: [String]) -> (lat: Double, lon: Double) {
        let initial = (initialGeohash ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let focus = Geohash.isValidGeohash(initial)
            ? initial
            : nearbyGeohashes.filter(Geohash.isValidGeohash).min { $0.count < $1.count }
        guard let focus else { return (20, 0) }
        let center = Geohash.decodeCenter(focus)
        return (center.lat, center.lon)
    }

    var body: some View {
        ZStack {
            palette.background
                .ignoresSafeArea()

            if let world {
                GlobeView(
                    state: state,
                    colors: globeColors,
                    world: world,
                    activity: activity.snapshot.channels,
                    activityColors: activityColors,
                    markerLayer: markerLayer,
                    onMarkerTap: markerTapped,
                    onBackgroundTap: { setCluster(nil) }
                )
                .ignoresSafeArea()
                .accessibilityActions { busiestChannelActions }
                .transition(.opacity)
            }

            chrome
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
        .task {
            guard world == nil else { return }
            let loaded = await Task.detached(priority: .userInitiated) { GlobeWorldData.bundled }.value
            withAnimation(.easeOut(duration: 0.25)) { world = loaded }
        }
        .onAppear { activity.start() }
        .onDisappear { activity.stop() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { activity.start() } else if phase == .background { activity.stop() }
        }
        // Pull in the relays nearest wherever the globe comes to rest.
        .onChange(of: state.isInMotion) { moving in
            guard !moving else { return }
            activity.focus(latitude: state.centerLat, longitude: state.centerLon)
        }
        .onChange(of: state.isInteracting) { interacting in
            if interacting { dismissHints() }
        }
        .onChange(of: activity.snapshot) { snapshot in
            // Everyone in a listed cluster went quiet: fall back to the selection.
            if let cluster, !cluster.contains(where: { snapshot.channel($0) != nil }) {
                setCluster(nil)
            }
        }
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            HStack(alignment: .top) {
                Spacer(minLength: 0)
                ControlRail(
                    precision: state.precision,
                    canZoomOut: state.canZoomOut,
                    onWholeGlobe: showWholeGlobe,
                    onZoomIn: { stepPrecision(by: 1) },
                    onZoomOut: zoomOut,
                    strings: (Strings.wholeGlobe, Strings.increasePrecision, Strings.decreasePrecision, Strings.precision(state.precision))
                )
            }
            .padding(.top, 12)
            Spacer(minLength: 0)
            bottomPanel
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var topBar: some View {
        ZStack {
            StatusChip(
                status: activity.status,
                snapshot: activity.snapshot,
                accent: activityColors.active.color,
                labels: (Strings.live, Strings.connecting, Strings.offline),
                accessibilityLabel: Strings.globeActivity(chats: activity.snapshot.activeChats, people: activity.snapshot.totalOnline)
            )
            .padding(.horizontal, 56)

            HStack {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(palette.primary)
                        .frame(width: 44, height: 44)
                        .pickerSurface(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(PickerPressStyle())
                .accessibilityLabel(Strings.close)
                .keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            if !hasInteracted {
                GestureHints(
                    spin: Strings.hintSpin,
                    zoom: Strings.hintZoom,
                    tapDot: activity.snapshot.channels.isEmpty ? nil : Strings.hintTapDot
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            ZStack(alignment: .bottom) {
                if let channels = clusterChannels {
                    ClusterCard(
                        channels: channels,
                        colors: activityColors,
                        summary: Strings.clusterSummary(
                            channels: channels.count,
                            people: GeohashActivitySnapshot.estimateDistinctPeople(channels)
                        ),
                        close: Strings.close,
                        describe: describe,
                        onPick: { geohash in
                            setCluster(nil)
                            focusChannel(geohash)
                        },
                        onDismiss: { setCluster(nil) }
                    )
                    .transition(cardTransition)
                } else {
                    selectionCard
                        .transition(cardTransition)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pickerSurface(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.88), value: cluster)
        }
        .frame(maxWidth: 520)
    }

    private var cardTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)),
            removal: .opacity
        )
    }

    private var selectionCard: some View {
        let geohash = state.selectedGeohash
        let channel = activity.snapshot.channel(geohash)
        let busiest = activity.snapshot.busiestInside(geohash)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: geohash.isEmpty ? Strings.noSelection : "#\(geohash)")
                        .bitchatFont(size: 22, weight: .semibold)
                        .foregroundColor(palette.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(verbatim: "\(GeohashCoverage.level(forLength: state.precision).displayName) · \(GeohashCoverage.string(forPrecision: state.precision))")
                        .bitchatFont(size: 13)
                        .foregroundColor(palette.secondary)
                        .lineLimit(1)
                    Group {
                        if let channel {
                            ActivityStats(channel: channel, colors: activityColors, showsDot: true)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(describe(channel))
                        } else {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(palette.secondary.opacity(0.45))
                                    .frame(width: 6, height: 6)
                                Text(verbatim: Strings.noActivity)
                                    .bitchatFont(size: 13)
                                    .foregroundColor(palette.secondary)
                            }
                        }
                    }
                    .padding(.top, 3)
                }
                .accessibilityElement(children: .combine)

                Spacer(minLength: 4)

                JoinButton(title: Strings.join, tint: joinTint, foreground: joinForeground) {
                    join(geohash)
                }
                .disabled(geohash.isEmpty)
            }

            if let busiest {
                Divider()
                    .padding(.top, 14)
                    .padding(.bottom, 2)
                ChannelRow(
                    channel: busiest,
                    colors: activityColors,
                    leadingSymbol: "flame.fill",
                    accessibilityLabel: "#\(busiest.geohash), \(describe(busiest))"
                ) {
                    focusChannel(busiest.geohash)
                }
            }
        }
    }

    private var clusterChannels: [GeohashChannelActivity]? {
        guard let cluster else { return nil }
        let channels = cluster.compactMap(activity.snapshot.channel)
            .sorted { ($0.people, $0.messages) > ($1.people, $1.messages) }
        return channels.isEmpty ? nil : channels
    }

    /// VoiceOver cannot aim at markers, so the busiest chats are offered as actions.
    @ViewBuilder
    private var busiestChannelActions: some View {
        ForEach(activity.snapshot.channels.prefix(5)) { channel in
            Button("#\(channel.geohash), \(describe(channel))") { focusChannel(channel.geohash) }
        }
    }

    // MARK: - Actions

    private func describe(_ channel: GeohashChannelActivity) -> String {
        Strings.channelActivity(people: channel.people, messages: channel.messages)
    }

    private func setCluster(_ geohashes: [String]?) {
        guard cluster != geohashes else { return }
        cluster = geohashes
    }

    /// The gesture hints have done their job once the globe has been touched or a
    /// control used.
    private func dismissHints() {
        guard !hasInteracted else { return }
        withAnimation(.easeOut(duration: 0.3)) { hasInteracted = true }
    }

    private func markerTapped(_ marker: GlobeMarker) {
        dismissHints()
        Self.impact()
        guard marker.isCluster else {
            setCluster(nil)
            focusChannel(marker.primary.geohash)
            return
        }
        setCluster(marker.channels.map(\.geohash))
        let center = marker.centroid
        state.animateTo(lat: center.lat, lon: center.lon, zoom: min(state.zoom * 2.6, GlobeMath.maxZoom), duration: 0.6)
    }

    private func focusChannel(_ geohash: String) {
        guard Geohash.isValidGeohash(geohash) else { return }
        dismissHints()
        let center = Geohash.decodeCenter(geohash)
        let zoom = GlobeMath.zoomForPrecision(geohash.count, baseRadius: state.baseRadius, screenMin: state.screenMin)
        state.animateTo(lat: center.lat, lon: center.lon, zoom: zoom, precision: geohash.count, duration: 0.65)
    }

    private func stepPrecision(by delta: Int) {
        dismissHints()
        state.animatePrecision(state.precision + delta)
    }

    /// At level 1 there is no coarser precision, so zooming out shows the whole globe.
    private func zoomOut() {
        if state.precision > 1 {
            stepPrecision(by: -1)
        } else {
            showWholeGlobe()
        }
    }

    private func showWholeGlobe() {
        dismissHints()
        setCluster(nil)
        state.animateTo(lat: state.centerLat, lon: state.centerLon, zoom: GlobeMath.minZoom, precision: 1, duration: 0.7)
    }

    private func join(_ geohash: String) {
        guard !geohash.isEmpty else { return }
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        onSelect(geohash)
    }

    private static func impact() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    // MARK: - Palette

    private var joinTint: Color { palette.locationAccent }

    /// Matrix's dark-mode green is too bright for white text.
    private var joinForeground: Color {
        theme == .matrix && colorScheme == .dark ? .black : .white
    }

    private var activityColors: GlobeActivityColors {
        if colorScheme == .dark {
            return GlobeActivityColors(
                quiet: GlobeRGB(red: 0.45, green: 0.68, blue: 0.95),
                active: GlobeRGB(red: 0.19, green: 0.82, blue: 0.35),
                hot: GlobeRGB(red: 1.0, green: 0.55, blue: 0.0),
                quietText: .white.opacity(0.92),
                selection: .white
            )
        }
        return GlobeActivityColors(
            quiet: GlobeRGB(red: 0.20, green: 0.45, blue: 0.80),
            active: GlobeRGB(red: 0.10, green: 0.62, blue: 0.27),
            hot: GlobeRGB(red: 0.96, green: 0.42, blue: 0.0),
            quietText: Color(red: 0.08, green: 0.16, blue: 0.30),
            selection: Color(red: 0.05, green: 0.1, blue: 0.06)
        )
    }

    /// Fixed land/ocean tones shared with the Android picker; the accent follows the
    /// theme's location color.
    private var globeColors: GlobeColors {
        let accent = palette.locationAccent
        if colorScheme == .dark {
            let onSurface = Color(red: 0.961, green: 0.961, blue: 0.961)
            let onSurfaceVariant = Color(red: 0.604, green: 0.651, blue: 0.604)
            return GlobeColors(
                accent: accent,
                land: Color(red: 0.086, green: 0.141, blue: 0.106),
                coastline: accent.opacity(0.45),
                border: onSurfaceVariant.opacity(0.5),
                oceanCenter: Color(red: 0.039, green: 0.078, blue: 0.063),
                oceanEdge: Color(red: 0.008, green: 0.024, blue: 0.016),
                atmosphere: accent,
                graticule: onSurface.opacity(0.055),
                grid: onSurfaceVariant.opacity(0.6),
                label: onSurfaceVariant,
                labelHalo: palette.background,
                star: onSurface
            )
        } else {
            let onSurface = Color(red: 0.075, green: 0.102, blue: 0.075)
            let onSurfaceVariant = Color(red: 0.298, green: 0.341, blue: 0.298)
            return GlobeColors(
                accent: accent,
                land: Color(red: 0.737, green: 0.824, blue: 0.753),
                coastline: accent.opacity(0.5),
                border: onSurfaceVariant.opacity(0.6),
                oceanCenter: Color(red: 0.918, green: 0.949, blue: 0.925),
                oceanEdge: Color(red: 0.831, green: 0.886, blue: 0.843),
                atmosphere: accent,
                graticule: onSurface.opacity(0.08),
                grid: onSurfaceVariant.opacity(0.7),
                label: onSurfaceVariant,
                labelHalo: palette.background,
                star: onSurfaceVariant
            )
        }
    }
}

// MARK: - Components

/// Live status: a breathing dot while relays stream, then active chats and people online.
private struct StatusChip: View {
    let status: GeohashActivityMonitor.Status
    let snapshot: GeohashActivitySnapshot
    let accent: Color
    let labels: (live: String, connecting: String, offline: String)
    let accessibilityLabel: String

    @ThemedPalette private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 10) {
            switch status {
            case .connecting:
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: labels.connecting)
                    .bitchatFont(size: 13, weight: .medium)
                    .foregroundColor(palette.secondary)
            case .offline:
                Image(systemName: "wifi.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(palette.alertRed)
                Text(verbatim: labels.offline)
                    .bitchatFont(size: 13, weight: .medium)
                    .foregroundColor(palette.secondary)
            case .live:
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                    .background(
                        Circle()
                            .fill(accent.opacity(0.35))
                            .scaleEffect(breathe ? 2.2 : 1)
                            .opacity(breathe ? 0 : 1)
                    )
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { breathe = true }
                    }
                Text(verbatim: labels.live)
                    .bitchatFont(size: 13, weight: .semibold)
                    .foregroundColor(palette.primary)
                if snapshot.activeChats > 0 || snapshot.totalOnline > 0 {
                    Rectangle()
                        .fill(palette.secondary.opacity(0.35))
                        .frame(width: 1, height: 14)
                    stat("bubble.left.and.bubble.right.fill", snapshot.activeChats)
                    stat("person.2.fill", snapshot.totalOnline)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .pickerSurface(Capsule())
        .animation(.easeInOut(duration: 0.2), value: status)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status == .live ? "\(labels.live), \(accessibilityLabel)" : (status == .connecting ? labels.connecting : labels.offline))
    }

    private func stat(_ symbol: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(palette.secondary)
            Text(verbatim: GlobeMarker.compactCount(value))
                .bitchatFont(size: 13, weight: .semibold)
                .foregroundColor(palette.primary)
                .monospacedDigit()
        }
    }
}

/// Map-style control stack: whole globe, then zoom in, the current geohash length,
/// and zoom out.
private struct ControlRail: View {
    let precision: Int
    let canZoomOut: Bool
    let onWholeGlobe: () -> Void
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let strings: (wholeGlobe: String, zoomIn: String, zoomOut: String, precision: String)

    @ThemedPalette private var palette

    var body: some View {
        VStack(spacing: 10) {
            button("globe", strings.wholeGlobe, enabled: canZoomOut, action: onWholeGlobe)
                .pickerSurface(Circle())

            VStack(spacing: 0) {
                button("plus", strings.zoomIn, enabled: precision < GlobeMath.maxPrecision, action: onZoomIn)
                Text(verbatim: "\(precision)")
                    .bitchatFont(size: 13, weight: .semibold)
                    .monospacedDigit()
                    .foregroundColor(palette.secondary)
                    .frame(width: 44, height: 22)
                    .accessibilityLabel(strings.precision)
                button("minus", strings.zoomOut, enabled: canZoomOut, action: onZoomOut)
            }
            .pickerSurface(Capsule())
        }
    }

    private func button(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(palette.primary.opacity(enabled ? 1 : 0.3))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PickerPressStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

private struct GestureHints: View {
    let spin: String
    let zoom: String
    let tapDot: String?

    @ThemedPalette private var palette

    var body: some View {
        HStack(spacing: 16) {
            hint("hand.draw", spin)
            hint("hand.pinch", zoom)
            if let tapDot { hint("hand.tap", tapDot) }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .pickerSurface(Capsule())
        .accessibilityElement(children: .combine)
    }

    private func hint(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
            Text(verbatim: label)
                .bitchatFont(size: 12)
        }
        .foregroundColor(palette.secondary)
    }
}

/// People and messages per hour, with the marker's heat dot.
private struct ActivityStats: View {
    let channel: GeohashChannelActivity
    let colors: GlobeActivityColors
    let showsDot: Bool

    @ThemedPalette private var palette

    var body: some View {
        HStack(spacing: 10) {
            if showsDot {
                Circle()
                    .fill(colors.fill(messages: channel.messages).color)
                    .frame(width: 8, height: 8)
            }
            stat("person.fill", GlobeMarker.compactCount(channel.people))
            if channel.messages > 0 {
                stat("bubble.left.fill", "\(GlobeMarker.compactCount(channel.messages))/h")
            }
        }
    }

    private func stat(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(palette.secondary)
            Text(verbatim: value)
                .bitchatFont(size: 13, weight: .medium)
                .foregroundColor(palette.primary)
                .monospacedDigit()
        }
    }
}

private struct ChannelRow: View {
    let channel: GeohashChannelActivity
    let colors: GlobeActivityColors
    var leadingSymbol: String?
    let accessibilityLabel: String
    let action: () -> Void

    @ThemedPalette private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let leadingSymbol {
                        Image(systemName: leadingSymbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(colors.fill(messages: channel.messages).color)
                    } else {
                        Circle()
                            .fill(colors.fill(messages: channel.messages).color)
                            .frame(width: 10, height: 10)
                    }
                }
                .frame(width: 18)
                Text(verbatim: "#\(channel.geohash)")
                    .bitchatFont(size: 16, weight: .medium)
                    .foregroundColor(palette.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                ActivityStats(channel: channel, colors: colors, showsDot: false)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(palette.secondary.opacity(0.7))
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}

/// A tapped cluster: its channels, busiest first.
private struct ClusterCard: View {
    let channels: [GeohashChannelActivity]
    let colors: GlobeActivityColors
    let summary: String
    let close: String
    let describe: (GeohashChannelActivity) -> String
    let onPick: (String) -> Void
    let onDismiss: () -> Void

    @ThemedPalette private var palette

    private static let maxRows = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(colors.active.color)
                    Text(verbatim: GlobeMarker.compactCount(channels.count))
                        .bitchatFont(size: 15, weight: .semibold)
                        .foregroundColor(palette.primary)
                }
                HStack(spacing: 5) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(palette.secondary)
                    Text(verbatim: GlobeMarker.compactCount(GeohashActivitySnapshot.estimateDistinctPeople(channels)))
                        .bitchatFont(size: 15, weight: .semibold)
                        .foregroundColor(palette.primary)
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(palette.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(close)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(summary)

            let rows = Array(channels.prefix(Self.maxRows))
            ForEach(Array(rows.enumerated()), id: \.element.geohash) { index, channel in
                if index > 0 {
                    Divider().padding(.leading, 34)
                }
                ChannelRow(
                    channel: channel,
                    colors: colors,
                    accessibilityLabel: "#\(channel.geohash), \(describe(channel))"
                ) {
                    onPick(channel.geohash)
                }
            }
        }
    }
}

private struct JoinButton: View {
    let title: String
    let tint: Color
    let foreground: Color
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(verbatim: title)
                    .bitchatFont(size: 16, weight: .semibold)
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundColor(foreground)
            .padding(.leading, 20)
            .padding(.trailing, 16)
            .frame(height: 48)
            .background(Capsule().fill(tint))
            .contentShape(Capsule())
        }
        .buttonStyle(PickerPressStyle())
        .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Styling

/// Shrinks slightly while pressed, like system floating controls.
private struct PickerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// List-row highlight while pressed.
private struct RowPressStyle: ButtonStyle {
    @ThemedPalette private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.primary.opacity(configuration.isPressed ? 0.08 : 0))
            )
    }
}

/// Floating surface for the picker's chrome: Liquid Glass (or a material below
/// OS 26) under the glass theme; an opaque panel with a hairline under matrix,
/// where translucency would muddy the terminal look.
private struct PickerSurface<S: Shape>: ViewModifier {
    let shape: S

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @ThemedPalette private var palette

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme.usesGlassChrome {
            content
                .modifier(GlassPanel(shape: shape))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.12), radius: 12, x: 0, y: 4)
        } else {
            content
                .background(shape.fill(palette.background))
                .overlay(shape.stroke(palette.primary.opacity(colorScheme == .dark ? 0.28 : 0.2), lineWidth: 1))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.12), radius: 14, x: 0, y: 4)
        }
    }
}

private extension View {
    func pickerSurface<S: Shape>(_ shape: S) -> some View {
        modifier(PickerSurface(shape: shape))
    }
}
