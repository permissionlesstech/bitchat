//
// BlossomMediaAttachmentView.swift
// bitchat
//
// Renders a NIP-92 Blossom media attachment inside feed cards with SHA-256
// verification and Stealth/Tor tap-to-load gating so scrolling never initiates
// passive external HTTP requests.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct BlossomMediaAttachmentView: View {
    let attachment: NostrProtocol.MediaAttachment
    let requiresTapToLoad: Bool

    @ThemedPalette private var palette
    @State private var loadedImage: ImageDownsampler.PlatformImage?
    @State private var isLoading = false
    @State private var loadError: String?

    init(
        attachment: NostrProtocol.MediaAttachment,
        requiresTapToLoad: Bool = PrivacyModeSettings.currentMode() == .stealth
            || NetworkActivationService.persistedTorPreference()
    ) {
        self.attachment = attachment
        self.requiresTapToLoad = requiresTapToLoad
    }

    var body: some View {
        Group {
            if let image = loadedImage {
                platformSwiftUIImage(image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 240)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(palette.cardBorder, lineWidth: 1)
                    )
            } else {
                Button(action: startLoad) {
                    HStack(spacing: 10) {
                        if isLoading {
                            ProgressView()
                                .frame(width: 22, height: 22)
                        } else {
                            Image(systemName: loadError != nil ? "exclamationmark.triangle" : "photo.badge.checkmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(loadError != nil ? palette.alertRed : palette.locationAccent)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                loadError ?? (
                                    requiresTapToLoad
                                        ? String(localized: "place_feed.media.tap_to_load_tor", defaultValue: "Tap to load image over Tor", comment: "Button prompting user to explicitly load a remote Blossom image in Stealth/Tor mode")
                                        : String(localized: "place_feed.media.loading", defaultValue: "Loading verified image…", comment: "Status while downloading and SHA-256 verifying a remote Blossom image")
                                )
                            )
                            .bitchatFont(size: 12, weight: .semibold)
                            .foregroundColor(palette.primary)
                            .lineLimit(1)

                            Text(verbatim: "\(attachment.url.host ?? "blossom") · sha256:\(attachment.sha256Hex.prefix(8))…")
                                .bitchatFont(size: 10)
                                .foregroundColor(palette.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.secondary.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(palette.cardBorder, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
            }
        }
        .onAppear {
            if let cached = BlossomMediaService.shared.cachedImage(for: attachment.sha256Hex) {
                loadedImage = cached
            } else if !requiresTapToLoad {
                startLoad()
            }
        }
    }

    private func startLoad() {
        guard !isLoading, loadedImage == nil else { return }
        isLoading = true
        loadError = nil
        Task {
            do {
                let image = try await BlossomMediaService.shared.fetchVerifiedImage(for: attachment)
                await MainActor.run {
                    self.loadedImage = image
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.loadError = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func platformSwiftUIImage(_ image: ImageDownsampler.PlatformImage) -> Image {
        #if os(iOS)
        Image(uiImage: image)
        #else
        Image(nsImage: image)
        #endif
    }
}
