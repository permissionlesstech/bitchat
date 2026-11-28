//
// PublicProfileSheet.swift
// bitchat
//
// Manages the opt-in persistent Nostr Public Handle (NIP-01 kind 0) and the
// private, Keychain-backed Following list (never broadcast as public kind 3).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct PublicProfileSheet: View {
    @ObservedObject private var profileStore = NostrProfileStore.shared
    @ObservedObject private var followsStore = NostrFollowsStore.shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ThemedPalette private var palette

    @State private var isEnabled = false
    @State private var displayName = ""
    @State private var about = ""
    @State private var nip05 = ""
    @State private var copiedNpub = false
    @State private var savedBanner = false

    @State private var followInput = ""
    @State private var followError: String?

    let defaultNickname: String

    var body: some View {
        VStack(spacing: 0) {
            ThemedSheetHeader(
                title: String(localized: "public_profile.title", defaultValue: "Identity & Following", comment: "Title of the Public Handle and Private Following management sheet"),
                onClose: { dismiss() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    publicHandleSection
                    followingSection
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .themedSurface()
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 580, idealHeight: 680)
        #endif
        .themedSheetBackground()
        .onAppear {
            loadDraftFromStore()
        }
    }

    private var publicHandleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemedSectionLabel(
                text: String(localized: "public_profile.section.handle", defaultValue: "PUBLIC HANDLE (OPT-IN)", comment: "Section header for the optional persistent Nostr handle").uppercased()
            )

            ThemedCard(spacing: 12) {
                Toggle(isOn: $isEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "public_profile.toggle.title", defaultValue: "Enable Public Handle", comment: "Toggle enabling a persistent Nostr kind-0 public handle"))
                            .bitchatFont(size: 15, weight: .semibold)
                            .foregroundColor(palette.primary)
                        Text(String(localized: "public_profile.toggle.subtitle", defaultValue: "By default, place posts use unlinkable per-place keys. Enable a persistent handle only when you want followers across places.", comment: "Privacy explanation contrasting per-place keys with opt-in public handle"))
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: isEnabled) { enabled in
                    if !enabled {
                        profileStore.disablePublicHandle()
                        savedBanner = false
                    } else if displayName.trimmed.isEmpty {
                        displayName = defaultNickname
                    }
                }

                if isEnabled {
                    Rectangle()
                        .fill(palette.divider)
                        .frame(height: 1)

                    if let npub = profileStore.ownPublicNpub {
                        HStack(spacing: 8) {
                            Text(verbatim: abbreviatedNpub(npub))
                                .bitchatFont(size: 12, weight: .medium)
                                .foregroundColor(palette.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                ClipboardHelper.copy(npub)
                                copiedNpub = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                    copiedNpub = false
                                }
                            } label: {
                                Label(
                                    copiedNpub
                                        ? String(localized: "public_profile.action.copied", defaultValue: "Copied", comment: "Confirmation after copying npub")
                                        : String(localized: "public_profile.action.copy_npub", defaultValue: "Copy npub", comment: "Button copying the user's npub to clipboard"),
                                    systemImage: copiedNpub ? "checkmark" : "doc.on.doc"
                                )
                                .bitchatFont(size: 12, weight: .semibold)
                                .foregroundColor(palette.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        TextField(
                            String(localized: "public_profile.field.name", defaultValue: "Display name", comment: "Placeholder for kind-0 display name"),
                            text: $displayName
                        )
                        .textFieldStyle(.plain)
                        .bitchatFont(size: 14)
                        .foregroundColor(palette.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .themedInputBackground()

                        TextField(
                            String(localized: "public_profile.field.about", defaultValue: "Short bio (optional)", comment: "Placeholder for kind-0 bio"),
                            text: $about,
                            axis: .vertical
                        )
                        .textFieldStyle(.plain)
                        .bitchatFont(size: 14)
                        .foregroundColor(palette.primary)
                        .lineLimit(1...3)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .themedInputBackground()

                        TextField(
                            String(localized: "public_profile.field.nip05", defaultValue: "NIP-05 handle (e.g. name@domain.com)", comment: "Placeholder for optional NIP-05 identifier"),
                            text: $nip05
                        )
                        .textFieldStyle(.plain)
                        .bitchatFont(size: 14)
                        .foregroundColor(palette.primary)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.emailAddress)
                        #endif
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .themedInputBackground()
                    }

                    HStack {
                        Button(action: publishProfile) {
                            Text(String(localized: "public_profile.action.publish", defaultValue: "Save & Publish Profile", comment: "Button saving and publishing NIP-01 kind-0 profile metadata"))
                                .bitchatFont(size: 14, weight: .semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(palette.accent)
                                .foregroundColor(palette.accentForeground)
                                .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    if savedBanner {
                        Text(String(localized: "public_profile.status.published", defaultValue: "Profile published to relays.", comment: "Confirmation shown after kind-0 metadata event is published"))
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.locationAccent)
                    }
                }
            }
        }
    }

    private var followingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemedSectionLabel(
                text: String(localized: "public_profile.section.following", defaultValue: "FOLLOWING (PRIVATE)", comment: "Section header for private local-only following list").uppercased()
            )

            ThemedCard(spacing: 12) {
                Text(String(localized: "public_profile.following.privacy_note", defaultValue: "Stored only in your device Keychain and never published as a public follow list. Mutual mesh favorites with Nostr keys are included automatically.", comment: "Privacy explanation for local-only following list"))
                    .bitchatFont(size: 12)
                    .foregroundColor(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    TextField(
                        String(localized: "public_profile.following.placeholder", defaultValue: "npub1… or hex pubkey", comment: "Placeholder for adding a Nostr pubkey to follow"),
                        text: $followInput
                    )
                    .textFieldStyle(.plain)
                    .bitchatFont(size: 13)
                    .foregroundColor(palette.primary)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    #endif
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .themedInputBackground()

                    Button(action: addFollow) {
                        Text(String(localized: "public_profile.action.follow", defaultValue: "Follow", comment: "Button to follow a Nostr author"))
                            .bitchatFont(size: 13, weight: .semibold)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(palette.accent)
                            .foregroundColor(palette.accentForeground)
                            .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(followInput.trimmed.isEmpty)
                }

                if let followError {
                    Text(followError)
                        .bitchatFont(size: 12)
                        .foregroundColor(palette.alertRed)
                }

                if !followsStore.explicitFollows.isEmpty {
                    Rectangle()
                        .fill(palette.divider)
                        .frame(height: 1)

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(followsStore.explicitFollows) { entry in
                            followedRow(entry)
                        }
                    }
                } else if followsStore.favoriteFollowPubkeys.isEmpty {
                    Text(String(localized: "public_profile.following.empty", defaultValue: "No followed accounts yet.", comment: "Empty state when user follows zero Nostr pubkeys"))
                        .bitchatFont(size: 13)
                        .foregroundColor(palette.secondary)
                }

                if !followsStore.favoriteFollowPubkeys.isEmpty {
                    Text(
                        String(
                            format: String(localized: "public_profile.following.favorites_included", defaultValue: "+ %lld favorited mesh peers with Nostr keys", comment: "Caption showing count of favorited mesh peers automatically included in Following"),
                            locale: .current,
                            followsStore.favoriteFollowPubkeys.count
                        )
                    )
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.secondary)
                }
            }
        }
    }

    private func followedRow(_ entry: NostrFollowsStore.FollowedAuthor) -> some View {
        let name = profileStore.displayName(
            for: entry.pubkeyHex,
            fallbackNickname: entry.alias
        )
        let nip05 = profileStore.profile(for: entry.pubkeyHex)?.nip05
        let color = Color(peerSeed: entry.pubkeyHex, isDark: colorScheme == .dark)

        return HStack(spacing: 10) {
            Text(verbatim: String(name.prefix(1)).uppercased())
                .bitchatFont(size: 12, weight: .bold)
                .foregroundColor(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.15))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                    .bitchatFont(size: 14, weight: .semibold)
                    .foregroundColor(palette.primary)
                    .lineLimit(1)
                if let nip05, !nip05.isEmpty {
                    Text(verbatim: nip05)
                        .bitchatFont(size: 11)
                        .foregroundColor(palette.locationAccent)
                        .lineLimit(1)
                } else if let npub = entry.npub {
                    Text(verbatim: abbreviatedNpub(npub))
                        .bitchatFont(size: 11)
                        .foregroundColor(palette.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button {
                followsStore.unfollow(entry.pubkeyHex)
            } label: {
                Text(String(localized: "public_profile.action.unfollow", defaultValue: "Unfollow", comment: "Button removing a pubkey from the private follow list"))
                    .bitchatFont(size: 12, weight: .medium)
                    .foregroundColor(palette.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(palette.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func loadDraftFromStore() {
        let current = profileStore.ownProfile
        isEnabled = current.isEnabled
        displayName = current.displayName.trimmed.isEmpty ? defaultNickname : current.displayName
        about = current.about
        nip05 = current.nip05
    }

    private func publishProfile() {
        let updated = NostrProfileStore.OwnPublicProfile(
            isEnabled: isEnabled,
            displayName: displayName.trimmed,
            about: about.trimmed,
            nip05: nip05.trimmed
        )
        if profileStore.saveAndPublishOwnProfile(updated) {
            savedBanner = true
        }
    }

    private func addFollow() {
        let candidate = followInput.trimmed
        guard let normalized = NostrProtocol.normalizePubkeyHex(candidate) else {
            followError = String(localized: "public_profile.following.invalid_key", defaultValue: "Enter a valid npub1… or 64-character hex pubkey.", comment: "Validation error when adding an invalid Nostr pubkey")
            return
        }
        followError = nil
        if followsStore.follow(normalized) {
            profileStore.ensureProfiles(for: [normalized])
            followInput = ""
        }
    }

    private func abbreviatedNpub(_ npub: String) -> String {
        guard npub.count > 20 else { return npub }
        return "\(npub.prefix(12))…\(npub.suffix(6))"
    }
}
