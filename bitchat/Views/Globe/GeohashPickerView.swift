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
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 20)
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
        HStack(spacing: 10) {
            Text(Strings.instruction)
                .bitchatFont(size: 12)
                .foregroundColor(palette.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .geohashPickerPanel()

            SheetCloseButton(action: onCancel)
                .foregroundColor(palette.primary)
                .frame(width: 40, height: 40)
                .geohashPickerPanel(cornerRadius: 20)
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Text(verbatim: hasSelection ? "#\(state.selectedGeohash)" : Strings.noSelection)
                    .bitchatFont(size: 14, weight: .medium)
                    .foregroundColor(palette.primary)
                if hasSelection {
                    Text(verbatim: "\(GeohashCoverage.level(forLength: state.precision).displayName) • \(GeohashCoverage.string(forPrecision: state.precision))")
                        .bitchatFont(size: 10)
                        .foregroundColor(palette.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .geohashPickerPanel()
            .accessibilityElement(children: .combine)

            HStack(spacing: 10) {
                precisionButton(systemImage: "minus", label: Strings.decreasePrecision) {
                    state.animatePrecision(state.precision - 1)
                }
                precisionButton(systemImage: "plus", label: Strings.increasePrecision) {
                    state.animatePrecision(state.precision + 1)
                }
                Button {
                    guard hasSelection else { return }
                    onSelect(state.selectedGeohash)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.bitchatSystem(size: 14, weight: .semibold))
                        Text(verbatim: Strings.select)
                            .bitchatFont(size: 12)
                    }
                    .foregroundColor(palette.primary)
                    .pickerCapsule(fill: palette.accentBlue.opacity(0.12))
                }
                .buttonStyle(.plain)
                .disabled(!hasSelection)
                .opacity(hasSelection ? 1 : 0.38)
                .accessibilityLabel(Strings.selectHint)
            }
        }
    }

    private func precisionButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.bitchatSystem(size: 16, weight: .semibold))
                .foregroundColor(palette.locationAccent)
                .pickerCapsule(fill: palette.locationAccent.opacity(0.12))
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

// MARK: - Styling

private struct GeohashPickerPanel: ViewModifier {
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme.usesGlassChrome {
            content.themedOverlayPanel()
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .background(shape.fill(palette.background.opacity(0.85)))
                .overlay(shape.stroke(palette.divider, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
        }
    }
}

private extension View {
    /// Floating translucent surface for the picker's hint, readout and close button.
    func geohashPickerPanel(cornerRadius: CGFloat = 12) -> some View {
        modifier(GeohashPickerPanel(cornerRadius: cornerRadius))
    }

    /// Pill button body sized like a standard 40pt-tall button.
    func pickerCapsule(fill: Color) -> some View {
        self
            .padding(.horizontal, 24)
            .frame(minHeight: 40)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
    }
}
