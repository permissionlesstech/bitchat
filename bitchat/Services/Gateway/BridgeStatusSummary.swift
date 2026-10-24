//
// BridgeStatusSummary.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// One-line mesh bridge status for the settings pane.
enum BridgeStatusSummary {
    static func formatted(
        enabled: Bool,
        cell: String?,
        bridgedCount: Int,
        nearbyOnly: Bool
    ) -> String {
        if !enabled {
            return String(
                localized: "app_info.settings.bridge.status.off",
                defaultValue: "bridge off — only radio-range mesh traffic",
                comment: "Bridge status line when the mesh bridge toggle is off"
            )
        }
        let cellPart = cell.map {
            String(
                format: String(
                    localized: "app_info.settings.bridge.status.cell",
                    defaultValue: "rendezvous #%@",
                    comment: "Bridge status fragment showing rendezvous cell; %@ is geohash"
                ),
                locale: .current,
                $0
            )
        } ?? String(
            localized: "app_info.settings.bridge.status.no_cell",
            defaultValue: "no rendezvous cell",
            comment: "Bridge status fragment when no cell is active"
        )
        let peoplePart = String(
            format: String(
                localized: "app_info.settings.bridge.status.people",
                defaultValue: "%lld people via bridge",
                comment: "Bridge status fragment counting bridged participants; %lld is count"
            ),
            locale: .current,
            bridgedCount
        )
        let composePart = nearbyOnly
            ? String(
                localized: "app_info.settings.bridge.status.compose_nearby",
                defaultValue: "compose: nearby only",
                comment: "Bridge status fragment when outgoing mesh messages stay on radio"
            )
            : String(
                localized: "app_info.settings.bridge.status.compose_bridged",
                defaultValue: "compose: bridged",
                comment: "Bridge status fragment when outgoing mesh messages cross the bridge"
            )
        return [cellPart, peoplePart, composePart].joined(separator: " · ")
    }
}
