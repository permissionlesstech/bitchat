//
// ChatSearchBar.swift
// bitchat
//
// Compact in-chat search and match-navigation bar shared across DMs,
// private groups, Nearby (#mesh), and Places (#geohash).
// This is free and unencumbered software released into the public domain.
//

import SwiftUI

struct ChatSearchBar: View {
    @ThemedPalette private var palette
    @Environment(\.appTheme) private var theme

    @Binding var query: String
    let matchCount: Int
    /// 0-based index into the chronological match list (`nil` when no matches).
    let activeMatchIndex: Int?
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(palette.secondary)

            TextField(
                String(localized: "chat.search.placeholder", defaultValue: "Search in chat", comment: "Placeholder in the in-chat search bar"),
                text: $query
            )
            .textFieldStyle(.plain)
            .bitchatFont(size: 14)
            .foregroundColor(palette.primary)
            .focused($isSearchFocused)
            .autocorrectionDisabled(true)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .submitLabel(.search)
            #endif
            .onSubmit {
                if matchCount > 0 {
                    onPrevious()
                }
            }

            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if matchCount > 0, let active = activeMatchIndex {
                    Text(verbatim: "\(active + 1)/\(matchCount)")
                        .bitchatFont(size: 12, weight: .medium)
                        .foregroundColor(palette.secondary)
                        .monospacedDigit()
                } else {
                    Text(String(localized: "chat.search.no_matches", defaultValue: "0", comment: "Short label when in-chat search has zero matches"))
                        .bitchatFont(size: 12, weight: .medium)
                        .foregroundColor(palette.secondary)
                }

                HStack(spacing: 2) {
                    Button(action: onPrevious) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(matchCount > 0 ? palette.primary : palette.secondary.opacity(0.4))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(matchCount == 0)
                    .accessibilityLabel(String(localized: "chat.search.previous", defaultValue: "Previous match", comment: "Button to jump to an older search match in chat"))

                    Button(action: onNext) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(matchCount > 0 ? palette.primary : palette.secondary.opacity(0.4))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(matchCount == 0)
                    .accessibilityLabel(String(localized: "chat.search.next", defaultValue: "Next match", comment: "Button to jump to a newer search match in chat"))
                }
            }

            Button(action: {
                query = ""
                onClose()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(palette.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "common.close", defaultValue: "Close", comment: "Dismisses the in-chat search bar"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            if theme.usesGlassChrome {
                RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous)
                            .stroke(palette.cardBorder, lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous)
                    .fill(palette.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous)
                            .stroke(palette.cardBorder, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear {
            isSearchFocused = true
        }
    }
}
