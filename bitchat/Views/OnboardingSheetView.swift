//
// OnboardingSheetView.swift
// bitchat
//
// First-run welcome and quick setup for bitchat 2.0: explains Chats,
// Nearby, and Places, lets new users pick a nickname and Everyday vs.
// Stealth privacy mode, and optionally jump straight into adding a friend.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

enum OnboardingState {
    static let completedKey = "bitchat.onboarding.completed.v2"

    static func shouldPresent(
        in defaults: UserDefaults = .standard,
        isRunningTests: Bool = TestEnvironment.isRunningTests
    ) -> Bool {
        guard !isRunningTests else { return false }
        return !defaults.bool(forKey: completedKey)
    }

    static func markCompleted(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedKey)
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: completedKey)
    }
}

struct OnboardingSheetView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @Environment(\.dismiss) private var dismiss
    @ThemedPalette private var palette

    let onComplete: (_ openAddFriend: Bool) -> Void

    @State private var draftNickname = ""
    @State private var selectedMode: PrivacyMode = PrivacyModeSettings.mode

    var body: some View {
        VStack(spacing: 0) {
            ThemedSheetHeader(
                title: String(localized: "onboarding.title", defaultValue: "Welcome to bitchat", comment: "First-run onboarding sheet title"),
                subtitle: String(localized: "onboarding.subtitle", defaultValue: "Private messaging over Bluetooth mesh and Nostr.", comment: "First-run onboarding sheet subtitle"),
                onClose: { finish(openAddFriend: false) }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    overviewCard
                    nicknameCard
                    privacyModeCard
                    actionButtons
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .themedSheetBackground()
        .foregroundColor(palette.primary)
        .onAppear {
            draftNickname = appChromeModel.nickname
            selectedMode = PrivacyModeSettings.mode
        }
        .interactiveDismissDisabled(false)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 540)
        #endif
    }

    private var overviewCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 12) {
                onboardingFeatureRow(
                    icon: "bubble.left.and.bubble.right.fill",
                    tint: palette.accent,
                    title: String(localized: "onboarding.feature.chats.title", defaultValue: "Chats", comment: "Onboarding overview item title for Chats"),
                    detail: String(localized: "onboarding.feature.chats.detail", defaultValue: "End-to-end encrypted direct messages and private groups that work online or offline.", comment: "Onboarding overview item description for Chats")
                )

                Divider()
                    .background(palette.divider)

                onboardingFeatureRow(
                    icon: "antenna.radiowaves.left.and.right",
                    tint: palette.accentBlue,
                    title: String(localized: "onboarding.feature.nearby.title", defaultValue: "Nearby", comment: "Onboarding overview item title for Nearby"),
                    detail: String(localized: "onboarding.feature.nearby.detail", defaultValue: "Public Bluetooth mesh chat with people around you — no internet or accounts required.", comment: "Onboarding overview item description for Nearby")
                )

                Divider()
                    .background(palette.divider)

                onboardingFeatureRow(
                    icon: "globe.americas.fill",
                    tint: .purple,
                    title: String(localized: "onboarding.feature.places.title", defaultValue: "Places", comment: "Onboarding overview item title for Places"),
                    detail: String(localized: "onboarding.feature.places.detail", defaultValue: "Location channels and Location Notes pinned to places around the world.", comment: "Onboarding overview item description for Places")
                )
            }
        }
    }

    private func onboardingFeatureRow(
        icon: String,
        tint: Color,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .bitchatFont(size: 14, weight: .semibold)
                    .foregroundColor(palette.primary)
                Text(detail)
                    .bitchatFont(size: 12)
                    .foregroundColor(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nicknameCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "onboarding.nickname.label", defaultValue: "Your Nickname", comment: "Section header for picking a nickname during onboarding"))
                    .bitchatFont(size: 13, weight: .semibold)
                    .foregroundColor(palette.primary)

                HStack(spacing: 6) {
                    Text(verbatim: "@")
                        .bitchatFont(size: 15, weight: .semibold)
                        .foregroundColor(palette.secondary)

                    TextField(
                        String(localized: "onboarding.nickname.placeholder", defaultValue: "Choose a nickname", comment: "Placeholder for nickname text field in onboarding"),
                        text: $draftNickname
                    )
                    .textFieldStyle(.plain)
                    .bitchatFont(size: 15, weight: .medium)
                    .foregroundColor(palette.primary)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled(true)
                    .submitLabel(.done)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(palette.background)
                .overlay(
                    RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous)
                        .stroke(palette.cardBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))

                Text(String(localized: "onboarding.nickname.hint", defaultValue: "No phone number or email. You can change this anytime in Settings.", comment: "Helper text below nickname field during onboarding"))
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.secondary)
            }
        }
    }

    private var privacyModeCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "onboarding.mode.label", defaultValue: "Privacy Mode", comment: "Section header for choosing Privacy Mode during onboarding"))
                    .bitchatFont(size: 13, weight: .semibold)
                    .foregroundColor(palette.primary)

                modeOptionRow(
                    mode: .everyday,
                    icon: "bolt.shield.fill",
                    tint: palette.accent,
                    title: String(localized: "settings.privacy_mode.everyday", defaultValue: "Everyday", comment: "Everyday privacy mode label"),
                    detail: String(localized: "onboarding.mode.everyday.detail", defaultValue: "Fast direct Nostr relays and encrypted local chat history on this device.", comment: "Description of Everyday mode during onboarding")
                )

                modeOptionRow(
                    mode: .stealth,
                    icon: "eye.slash.fill",
                    tint: .orange,
                    title: String(localized: "settings.privacy_mode.stealth", defaultValue: "Stealth", comment: "Stealth privacy mode label"),
                    detail: String(localized: "onboarding.mode.stealth.detail", defaultValue: "Tor routing, RAM-only chats that clear on close, and hidden lock-screen previews.", comment: "Description of Stealth mode during onboarding")
                )
            }
        }
    }

    private func modeOptionRow(
        mode: PrivacyMode,
        icon: String,
        tint: Color,
        title: String,
        detail: String
    ) -> some View {
        let isSelected = selectedMode == mode
        return Button {
            selectedMode = mode
            PrivacyModeSettings.applyMode(
                mode,
                onClearPersistedHistory: { appChromeModel.clearPersistedPrivateHistory() }
            )
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isSelected ? tint : palette.secondary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .bitchatFont(size: 14, weight: .semibold)
                        .foregroundColor(palette.primary)
                    Text(detail)
                        .bitchatFont(size: 12)
                        .foregroundColor(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isSelected ? tint : palette.secondary.opacity(0.45))
            }
            .padding(10)
            .background(isSelected ? tint.opacity(0.08) : palette.background.opacity(0.75))
            .overlay(
                RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous)
                    .stroke(isSelected ? tint.opacity(0.55) : palette.cardBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                finish(openAddFriend: false)
            } label: {
                Text(String(localized: "onboarding.action.get_started", defaultValue: "Get Started", comment: "Primary CTA button on first-run onboarding sheet"))
                    .bitchatFont(size: 15, weight: .semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                finish(openAddFriend: true)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 14, weight: .semibold))
                    Text(String(localized: "onboarding.action.add_friend", defaultValue: "Add a Friend First", comment: "Secondary CTA button on first-run onboarding sheet to jump straight to friend invite"))
                        .bitchatFont(size: 14, weight: .semibold)
                }
                .foregroundColor(palette.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous)
                        .stroke(palette.cardBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func finish(openAddFriend: Bool) {
        let trimmed = draftNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            appChromeModel.setNickname(trimmed)
            appChromeModel.validateAndSaveNickname()
        }
        OnboardingState.markCompleted()
        dismiss()
        onComplete(openAddFriend)
    }
}
