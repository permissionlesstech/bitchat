//
//  StickerMessageView.swift
//  bitchat
//
//  Renders a Sonar sticker message row. A sticker is an ordinary chat message
//  whose content is the StickerRef wire string; this view resolves the
//  referenced pack + image bytes (Tor-routed, disk-cached by StickerPackService)
//  and degrades to a clean placeholder when offline or unresolvable.
//

import SwiftUI
import BitFoundation

struct StickerMessageView: View {
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette
    let message: BitchatMessage

    enum LoadState: Equatable {
        case loading, ready(Data), missing, untrusted
    }
    @State private var loadState: LoadState = .loading

    private let stickerSize: CGFloat = 160

    var body: some View {
        let isFromMe = conversationUIModel.isMediaMessageFromCurrentUser(message)
        HStack(alignment: .bottom, spacing: 4) {
            if message.isPrivate {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundColor(palette.secondary.opacity(0.6))
                    .padding(.bottom, 4)
            }
            content(for: loadState)
                .frame(maxWidth: stickerSize, maxHeight: stickerSize)
                .onTapGesture {
                    if loadState == .missing || loadState == .untrusted { Task { await resolve() } }
                }
        }
        .frame(maxWidth: .infinity, alignment: isFromMe ? .trailing : .leading)
        .task(id: message.id) { await resolve() }
    }

    @ViewBuilder
    private func content(for state: LoadState) -> some View {
        switch state {
        case .loading:
            placeholder(symbol: "sparkles", tint: palette.secondary)
        case .missing:
            placeholder(symbol: "photo", tint: palette.secondary)
        case .untrusted:
            placeholder(symbol: "exclamationmark.triangle", tint: palette.alertRed)
        case .ready(let data):
            stickerImage(data)
        }
    }

    private func placeholder(symbol: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(palette.secondary.opacity(0.12))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 28))
                    .foregroundColor(tint.opacity(0.7))
            )
    }

    @ViewBuilder
    private func stickerImage(_ data: Data) -> some View {
        if let img = Self.platformImage(data) {
            img.resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            placeholder(symbol: "photo", tint: palette.secondary)
        }
    }

    #if os(iOS)
    private static func platformImage(_ data: Data) -> Image? {
        UIImage(data: data).map { Image(uiImage: $0) }
    }
    #else
    private static func platformImage(_ data: Data) -> Image? {
        NSImage(data: data).map { Image(nsImage: $0) }
    }
    #endif

    private func resolve() async {
        guard let ref = StickerRefCodec.parse(message.content) else {
            loadState = .missing
            return
        }
        let service = StickerPackService.shared
        var pack = service.cachedPack(forCoordinate: ref.packCoordinate)
        if pack == nil {
            let parts = ref.packCoordinate.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 3 {
                pack = try? await service.fetchPack(authorPubkeyHex: String(parts[1]), identifier: String(parts[2]))
            }
        }
        guard let pack else { loadState = .missing; return }
        guard service.validateStickerRef(
            packCoordinate: ref.packCoordinate,
            shortcode: ref.shortcode,
            plaintextSha256: ref.plaintextSha256,
            against: pack
        ) else { loadState = .untrusted; return }
        guard let sticker = pack.stickers.first(where: { $0.shortcode == ref.shortcode }) else {
            loadState = .untrusted
            return
        }
        do {
            let bytes = try await service.imageData(for: sticker)
            loadState = .ready(bytes)
        } catch {
            loadState = .missing
        }
    }
}
