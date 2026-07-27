//
// BridgePeopleList.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Shared section header for the people sheet: a small glyph + label pair,
/// identical shape for every section (#mesh, across the bridge, …).
struct PeopleSectionHeader: View {
    @ThemedPalette private var palette
    let icon: String
    let iconColor: Color
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.bitchatSystem(size: 10))
                .foregroundColor(iconColor)
            Text(verbatim: title)
                .bitchatFont(size: 11, weight: .semibold)
                .foregroundColor(palette.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The people-sheet section for participants visible across the mesh bridge:
/// same place, beyond radio range. Display-only in v1 — bridged identities
/// are per-cell rendezvous keys with no DM route yet.
struct BridgePeopleList: View {
    @ObservedObject private var bridgeService = BridgeService.shared
    @ThemedPalette private var palette

    private enum Strings {
        static let sectionTitle = String(localized: "bridge_people.section_title", defaultValue: "across the bridge", comment: "Section header in the people sheet for participants reachable via the mesh bridge")
        static let rowHint = String(localized: "bridge_people.accessibility.row_hint", defaultValue: "In your area, connected through the bridge", comment: "Accessibility hint for a person listed in the bridge section of the people sheet")
    }

    var body: some View {
        // Not gated on the toggle: bridged people arrive over passive radio
        // (a serving neighbor's carriers) even while this device's own
        // bridge is off — whoever is visible in the timeline belongs in the
        // sheet.
        if !bridgeService.bridgedParticipants.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PeopleSectionHeader(
                    icon: "network",
                    iconColor: Color.cyan.opacity(0.9),
                    title: Strings.sectionTitle
                )

                ForEach(bridgeService.bridgedParticipants) { person in
                    HStack(spacing: 4) {
                        Text(person.displayName)
                            .bitchatFont(size: 14)
                            .foregroundColor(palette.primary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(Strings.rowHint)
                }
            }
        }
    }
}
