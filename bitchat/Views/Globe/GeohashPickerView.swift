//
// GeohashPickerView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Full-screen 3D globe for choosing a geohash channel to teleport to. The cell under
/// the crosshair is the selection; zooming changes precision, and the +/- buttons step
/// precision while framing the cell.
struct GeohashPickerView: View {
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @StateObject private var state: GlobeState
    @State private var world: GlobeWorldData?
    @Environment(\.colorScheme) private var colorScheme
    @ThemedPalette private var palette

    private enum Strings {
        static let instruction = String(localized: "geohash_picker.instruction", defaultValue: "drag to spin · pinch to zoom · tap to focus", comment: "Hint at the top of the globe geohash picker explaining its gestures")
        static let noSelection = String(localized: "geohash_picker.no_selection", defaultValue: "select location", comment: "Shown in the globe geohash picker before a geohash is under the crosshair")
        static let select = String(localized: "geohash_picker.select", defaultValue: "select", comment: "Button in the globe geohash picker that teleports to the geohash under the crosshair")
        static let selectHint = String(localized: "geohash_picker.accessibility.select", defaultValue: "select geohash", comment: "Accessibility label for the globe picker's select button")
        static let decreasePrecision = String(localized: "geohash_picker.accessibility.decrease_precision", defaultValue: "decrease precision", comment: "Accessibility label for the globe picker button that zooms out to a larger geohash cell")
        static let increasePrecision = String(localized: "geohash_picker.accessibility.increase_precision", defaultValue: "increase precision", comment: "Accessibility label for the globe picker button that zooms in to a smaller geohash cell")
    }

    /// - Parameters:
    ///   - initialGeohash: cell to fly to; when empty, the coarsest of
    ///     `nearbyGeohashes` is used, else a wide view of the world.
    init(
        initialGeohash: String?,
        nearbyGeohashes: [String] = [],
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onCancel = onCancel
        let target = Self.initialTarget(initialGeohash: initialGeohash, nearbyGeohashes: nearbyGeohashes)
        _state = StateObject(wrappedValue: GlobeState(
            targetLat: target.lat,
            targetLon: target.lon,
            initialPrecision: target.precision,
            startZoomedOut: true
        ))
    }

    /// Where the intro flies to: the given geohash, else the coarsest nearby channel,
    /// else a wide view at precision 2.
    static func initialTarget(initialGeohash: String?, nearbyGeohashes: [String]) -> (lat: Double, lon: Double, precision: Int) {
        let initial = (initialGeohash ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let focus = Geohash.isValidGeohash(initial)
            ? initial
            : nearbyGeohashes.filter(Geohash.isValidGeohash).min { $0.count < $1.count }
        guard let focus else { return (20, 0, 2) }
        let center = Geohash.decodeCenter(focus)
        return (center.lat, center.lon, min(max(focus.count, 1), GlobeMath.maxPrecision))
    }

    var body: some View {
        ZStack {
            palette.background
                .ignoresSafeArea()

            if let world {
                GlobeView(state: state, colors: globeColors, world: world)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomControls
            }
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
        .task {
            guard world == nil else { return }
            world = await Task.detached(priority: .userInitiated) { GlobeWorldData.bundled }.value
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        AppTopBar {
            Text(Strings.instruction)
                .bitchatFont(size: 12.5, weight: .medium)
                .foregroundColor(palette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } trailing: {
            SheetCloseButton(action: onCancel)
                .foregroundColor(palette.primary)
        }
    }

    private var bottomControls: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: hasSelection ? "#\(state.selectedGeohash)" : Strings.noSelection)
                    .bitchatFont(size: 16, weight: .bold)
                    .foregroundColor(palette.primary)
                    .lineLimit(1)
                if hasSelection {
                    Text(verbatim: "\(GeohashCoverage.level(forLength: state.precision).displayName) · \(GeohashCoverage.string(forPrecision: state.precision))")
                        .bitchatFont(size: 11)
                        .foregroundColor(palette.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 6)

            HStack(spacing: 0) {
                precisionButton(systemImage: "minus", label: Strings.decreasePrecision) {
                    state.animatePrecision(state.precision - 1)
                }
                Rectangle()
                    .fill(palette.divider)
                    .frame(width: 1, height: 18)
                precisionButton(systemImage: "plus", label: Strings.increasePrecision) {
                    state.animatePrecision(state.precision + 1)
                }
            }
            .background(palette.cardBackground)
            .overlay(
                Capsule()
                    .stroke(palette.cardBorder, lineWidth: 1)
            )
            .clipShape(Capsule())

            Button {
                guard hasSelection else { return }
                onSelect(state.selectedGeohash)
            } label: {
                Text(verbatim: Strings.select.capitalized)
                    .bitchatFont(size: 13, weight: .semibold)
                    .foregroundColor(palette.accentForeground)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(palette.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!hasSelection)
            .opacity(hasSelection ? 1 : 0.4)
            .accessibilityLabel(Strings.selectHint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .themedChromePanel(edge: .bottom)
    }

    private func precisionButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(palette.primary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var hasSelection: Bool { !state.selectedGeohash.isEmpty }

    // MARK: - Globe palette

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
