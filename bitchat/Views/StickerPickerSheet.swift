// StickerPickerSheet.swift
// bitchat
//
// Sonar sticker picker: browse installed packs, install new ones by
// coordinate, and opt in to Nostr list sync.

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Sonar sticker picker sheet.
///
/// Shows installed packs as a thumbnail grid (load each pack's images off the
/// main actor via `StickerPackService`), lets the user paste a pack
/// coordinate (`30031:<pubkey>:<identifier>`) to install a new one, and
/// exposes the opt-in "sync installed packs to Nostr" toggle with a privacy
/// warning. Picking a sticker invokes `onPick` with the validated `StickerRef`
/// and dismisses.
struct StickerPickerSheet: View {
    /// Called with the picked sticker's wire-format ref; the sheet dismisses
    /// itself immediately after.
    let onPick: (StickerRef) -> Void

    @Environment(\.dismiss) private var dismiss
    @ThemedPalette private var palette

    /// New instances share persisted state (UserDefaults + deterministic
    /// file), so this is consistent with the store held by `ChatViewModel`.
    private let installStore = StickerInstallStore.shared
    private let packService = StickerPackService.shared

    @State private var installedPacks: [StickerPack] = []
    @State private var selectedIndex: Int = 0
    @State private var imageDataCache: [String: Data] = [:]

    @State private var installInput: String = ""
    @State private var installPhase: InstallPhase = .idle

    /// Mirrors `StickerInstallStore.syncEnabled` (a UserDefaults flag) so the
    /// toggle binds synchronously; the store reads the same key.
    @State private var syncEnabled: Bool = UserDefaults.standard
        .object(forKey: StickerInstallStore.syncEnabledDefaultsKey) as? Bool ?? false

    private enum InstallPhase: Equatable {
        case idle
        case loading
        case error(String)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        installedSection
                        installSection
                        syncSection
                    }
                    .padding(16)
                }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 480)
            #endif
        }
        #if os(iOS)
        .navigationViewStyle(.stack)
        #endif
        .task { await refreshInstalled() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(String(localized: "sticker.picker.title", comment: "Title of the sticker picker sheet"))
                .bitchatFont(size: 18)
            Spacer()
            SheetCloseButton { dismiss() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Installed packs

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "sticker.picker.section.installed", comment: "Section heading for the installed sticker packs"))
                .bitchatFont(size: 13, weight: .semibold)
                .foregroundColor(palette.secondary)

            if installedPacks.isEmpty {
                Text(String(localized: "sticker.picker.empty", comment: "Shown when no sticker packs are installed yet"))
                    .bitchatFont(size: 12)
                    .foregroundColor(palette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                packTabs
                if installedPacks.indices.contains(selectedIndex) {
                    stickerGrid(for: installedPacks[selectedIndex])
                }
            }
        }
    }

    private var packTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(installedPacks.enumerated()), id: \.element.id) { index, pack in
                    Button {
                        selectedIndex = index
                    } label: {
                        Text(pack.title)
                            .bitchatFont(
                                size: 12,
                                weight: selectedIndex == index ? .semibold : .regular
                            )
                            .foregroundColor(selectedIndex == index ? palette.primary : palette.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(
                                        selectedIndex == index
                                            ? palette.accent.opacity(0.18)
                                            : palette.background.opacity(0.4)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func stickerGrid(for pack: StickerPack) -> some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(pack.stickers) { sticker in
                stickerCell(sticker, pack: pack)
            }
        }
    }

    private func stickerCell(_ sticker: Sticker, pack: StickerPack) -> some View {
        Button {
            guard let ref = StickerRef(
                packCoordinate: pack.coordinate,
                shortcode: sticker.shortcode,
                plaintextSha256: sticker.sha256
            ) else { return }
            onPick(ref)
            dismiss()
        } label: {
            Group {
                if let data = imageDataCache[sticker.sha256],
                   let image = StickerPickerSheet.platformImage(from: data) {
                    image.resizable().scaledToFit()
                } else {
                    ProgressView().scaleEffect(0.8)
                }
            }
            .frame(width: 64, height: 64)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(palette.background.opacity(0.3))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sticker.emoji ?? sticker.shortcode)
        .accessibilityHint(
            String(localized: "sticker.accessibility.send", comment: "Accessibility hint for tapping a sticker to send it")
        )
        .task(id: sticker.sha256) {
            await loadImage(for: sticker)
        }
    }

    // MARK: - Install a pack

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "sticker.install.title", comment: "Section heading for installing a new sticker pack"))
                .bitchatFont(size: 13, weight: .semibold)
                .foregroundColor(palette.secondary)

            HStack(spacing: 8) {
                TextField(
                    String(localized: "sticker.install.placeholder", comment: "Placeholder for the pack coordinate input field"),
                    text: $installInput
                )
                .textFieldStyle(.plain)
                .bitchatFont(size: 12)
                .foregroundColor(palette.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(palette.secondary.opacity(0.3))
                )
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                #endif

                Button(action: { Task { await installPack() } }) {
                    Text(String(localized: "sticker.install.button", comment: "Button that installs the pasted sticker pack"))
                        .bitchatFont(size: 12, weight: .medium)
                }
                .disabled(
                    installPhase == .loading
                        || installInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            switch installPhase {
            case .idle:
                EmptyView()
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text(String(localized: "sticker.install.loading", comment: "Status shown while a pack is being fetched"))
                        .bitchatFont(size: 11)
                        .foregroundColor(palette.secondary)
                }
            case .error(let message):
                Text(message)
                    .bitchatFont(size: 11)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Nostr sync

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { syncEnabled },
                set: { newValue in
                    syncEnabled = newValue
                    // Mirror the store's UserDefaults-backed flag directly;
                    // the store reads this same key when deciding to publish.
                    UserDefaults.standard.set(
                        newValue,
                        forKey: StickerInstallStore.syncEnabledDefaultsKey
                    )
                    if newValue {
                        // Enabling sync must actually synchronize: import the
                        // remote list (so a second device's packs arrive),
                        // then publish the merged local list. Failures are
                        // logged inside the store; the toggle stays on.
                        Task {
                            try? await installStore.mergeInstalledFromNetwork()
                            try? await installStore.publishInstalledList()
                        }
                    }
                }
            )) {
                Text(String(localized: "sticker.sync.title", comment: "Toggle label for syncing installed sticker packs to Nostr"))
                    .bitchatFont(size: 13, weight: .medium)
                    .foregroundColor(palette.primary)
            }
            .toggleStyle(.switch)

            Text(String(localized: "sticker.sync.warning", comment: "Privacy warning explaining that Nostr sync publishes installed packs under the persistent identity"))
                .bitchatFont(size: 11)
                .foregroundColor(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.background.opacity(0.3))
        )
    }

    // MARK: - Actions

    private func refreshInstalled() async {
        let coordinates = await installStore.installedPacks()
        var packs: [StickerPack] = []
        for coordinate in coordinates {
            if let cached = packService.cachedPack(forCoordinate: coordinate) {
                packs.append(cached)
                continue
            }
            let parts = coordinate.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let author = String(parts[1])
            let identifier = String(parts[2])
            if let pack = try? await packService.fetchPack(
                authorPubkeyHex: author,
                identifier: identifier
            ) {
                packs.append(pack)
            }
        }
        installedPacks = packs
        if !installedPacks.indices.contains(selectedIndex) {
            selectedIndex = 0
        }
    }

    private func installPack() async {
        let trimmed = installInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard StickerRef.isValidCoordinate(trimmed) else {
            installPhase = .error(
                String(localized: "sticker.install.error.invalid", comment: "Error shown when a pasted pack coordinate is malformed")
            )
            return
        }
        installPhase = .loading
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        let author = String(parts[1])
        let identifier = String(parts[2])
        do {
            // Fetch first so an invalid/unreachable coordinate fails before we
            // record an install the user can't render.
            _ = try await packService.fetchPack(authorPubkeyHex: author, identifier: identifier)
            try await installStore.install(trimmed)
            installInput = ""
            installPhase = .idle
            await refreshInstalled()
        } catch {
            installPhase = .error(
                String(localized: "sticker.install.error.failed", comment: "Error shown when a pack could not be fetched or installed")
            )
        }
    }

    private func loadImage(for sticker: Sticker) async {
        guard imageDataCache[sticker.sha256] == nil else { return }
        if let data = try? await packService.imageData(for: sticker) {
            imageDataCache[sticker.sha256] = data
        }
    }
}

// MARK: - Cross-platform image bridging

#if os(iOS)
private extension StickerPickerSheet {
    static func platformImage(from data: Data) -> Image? {
        UIImage(data: data).map { Image(uiImage: $0) }
    }
}
#elseif os(macOS)
private extension StickerPickerSheet {
    static func platformImage(from data: Data) -> Image? {
        NSImage(data: data).map { Image(nsImage: $0) }
    }
}
#endif
