//
// SheetCloseButton.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// The close "X" every sheet and header shares. One glyph size and weight
/// everywhere (the sheets had drifted across 12/13/14pt), a 32pt visual box
/// so existing header metrics don't move, and a hit target extended to 44pt
/// per platform guidelines. Tint comes from the environment, so callers keep
/// their own foreground color.
struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .bitchatFont(size: 13, weight: .semibold)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "common.close", comment: "Accessibility label for close buttons"))
    }
}
