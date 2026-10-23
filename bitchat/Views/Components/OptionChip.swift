//
// OptionChip.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// One option in a multi-choice settings row — the appearance picker's theme
/// chips, the panic gesture's mode chips. Shared so every such row is the
/// same control rather than a lookalike.
struct OptionChip: View {
    private let title: Text
    private let isSelected: Bool
    private let action: () -> Void
    @ThemedPalette private var palette

    init(_ title: Text, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            title
                .bitchatFont(size: 13, weight: isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? palette.accent : palette.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? palette.accent.opacity(0.15) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
