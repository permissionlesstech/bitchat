//
// BridgePeopleList.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// The people-sheet section for participants visible across the mesh bridge:
/// same place, beyond radio range. Display-only in v1 — bridged identities
/// are per-cell rendezvous keys with no DM route yet.
struct BridgePeopleList: View {
    @ObservedObject private var bridgeService = BridgeService.shared
    @ThemedPalette private var palette
    @Environment(\.appTheme) private var theme

    private enum Strings {
        static let sectionTitle = String(localized: "bridge_people.section_title", defaultValue: "across the bridge", comment: "Section header in the people sheet for participants reachable via the mesh bridge")
        static let rowHint = String(localized: "bridge_people.accessibility.row_hint", defaultValue: "In your area, connected through the bridge", comment: "Accessibility hint for a person listed in the bridge section of the people sheet")
    }

    var body: some View {
        if bridgeService.isEnabled && !bridgeService.bridgedParticipants.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "network")
                        .font(.bitchatSystem(size: 10))
                        .foregroundColor(Color.cyan.opacity(0.9))
                    Text(verbatim: Strings.sectionTitle)
                        .bitchatFont(size: 11, weight: .semibold)
                        .foregroundColor(palette.secondary)
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 4)

                ForEach(bridgeService.bridgedParticipants) { person in
                    HStack(spacing: 4) {
                        Image(systemName: "network")
                            .font(.bitchatSystem(size: 10))
                            .foregroundColor(Color.cyan.opacity(0.75))
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
