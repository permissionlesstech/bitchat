//
// SettingsCard.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// The padded card every setting sits in (moved look from
/// LocationChannelsSheet's toggle sections).
struct SettingsCard<Content: View>: View {
    private let content: () -> Content
    @ThemedPalette private var palette

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(12)
            .background(palette.secondary.opacity(0.12))
            .cornerRadius(8)
    }
}
