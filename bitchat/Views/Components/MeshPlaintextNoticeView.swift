//
// MeshPlaintextNoticeView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Dismissible banner reminding people that #mesh is a plaintext broadcast (#1064).
struct MeshPlaintextNoticeView: View {
    var onDismiss: () -> Void
    @ThemedPalette private var palette

    private enum Strings {
        static let title = String(
            localized: "security.mesh_plaintext.title",
            defaultValue: "mesh is a public broadcast",
            comment: "Title of the dismissible notice above the mesh composer"
        )
        static let body = String(
            localized: "security.mesh_plaintext.body",
            defaultValue: "anything you type in #mesh can be read by every device within radio range. for private conversation, open someone from the people list or switch to a location channel.",
            comment: "Body of the dismissible notice explaining mesh is unencrypted"
        )
        static let dismiss = String(
            localized: "security.mesh_plaintext.dismiss",
            defaultValue: "dismiss",
            comment: "Button that hides the mesh plaintext notice until reinstall"
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "megaphone")
                .font(.bitchatSystem(size: 12))
                .foregroundColor(palette.alertRed)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: Strings.title)
                    .bitchatFont(size: 12, weight: .semibold)
                    .foregroundColor(palette.primary)
                Text(verbatim: Strings.body)
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Text(verbatim: Strings.dismiss)
                    .bitchatFont(size: 11, weight: .semibold)
                    .foregroundColor(palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Strings.dismiss)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.alertRed.opacity(0.08))
    }
}
