//
// BridgeSettingsCaption.swift
// bitchat
//
// Which line sits under the mesh bridge toggle.
//

import Foundation

/// The caption under the mesh bridge toggle. The people count is added only
/// when the rendezvous cell is known and someone is across the bridge, so a
/// quiet cell keeps the cell line it already had.
enum BridgeSettingsCaption: Equatable {
    case noCell
    case cell
    case cellAndPeople

    static func resolve(hasCell: Bool, people: Int) -> BridgeSettingsCaption {
        guard hasCell else { return .noCell }
        return people > 0 ? .cellAndPeople : .cell
    }
}
