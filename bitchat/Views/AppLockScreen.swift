//
// AppLockScreen.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Full-screen gate shown while the app lock is engaged. Covers everything
/// (the timelines underneath must not be readable or tappable), triggers
/// the system prompt on appear, and keeps a manual retry button for the
/// case where the prompt was dismissed.
struct AppLockScreen: View {
    @ObservedObject var model: AppLockModel
    @ThemedPalette private var palette

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()

            VStack(spacing: 16) {
                Text(verbatim: "bitchat/")
                    .bitchatFont(size: 24, weight: .medium)
                    .foregroundColor(palette.primary)

                Image(systemName: "lock.fill")
                    .font(.bitchatSystem(size: 28))
                    .foregroundColor(palette.secondary)

                Text(String(localized: "app_lock.locked", defaultValue: "bitchat is locked", comment: "Headline of the app-lock screen"))
                    .bitchatFont(size: 14)
                    .foregroundColor(palette.secondary)

                Button(action: { model.requestUnlock() }) {
                    Text(String(localized: "app_lock.unlock", defaultValue: "unlock", comment: "Button on the app-lock screen that triggers the system authentication prompt"))
                        .bitchatFont(size: 14, weight: .semibold)
                        .foregroundColor(palette.primary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(palette.primary.opacity(0.12))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(model.isAuthenticating)
            }
        }
        .onAppear {
            model.requestUnlock()
        }
        .accessibilityAddTraits(.isModal)
    }
}
