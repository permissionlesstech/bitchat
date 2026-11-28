//
// MeshEmptyStateView.swift
// bitchat
//
// The empty mesh timeline: shows a quiet status-aware line when no one is in
// Bluetooth range yet (and stays blank once peers are nearby), plus the
// liveliest nearby geohash conversation one tap away when active.
// This is free and unencumbered software released into the public domain.
//

import Combine
import SwiftUI

struct MeshEmptyStateView: View {
    /// Visible chat height to fill. Zero (previews) keeps a compact layout.
    var fillHeight: CGFloat = 0
    /// Ambient-footer mode, appended below archived echoes: skips the empty
    /// status line (the timeline isn't empty), keeping live hints visible.
    var compact: Bool = false

    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @ObservedObject private var activityTracker = GeohashChatActivityTracker.shared

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette

    /// The activity window is evaluated at render time; without new events
    /// nothing would trigger a re-render, so a stale "people are talking"
    /// hint could linger. A slow tick keeps the hints and relative times
    /// honest.
    @State private var refreshTick = 0
    private let refreshTimer = Timer.publish(every: 60, tolerance: 10, on: .main, in: .common).autoconnect()

    private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private enum Strings {
        static let noPeersNearby = String(
            localized: "content.empty.no_peers_nearby",
            defaultValue: "No one in Bluetooth range yet.",
            comment: "Empty Nearby mesh timeline status when no peers are currently in Bluetooth range"
        )

        static func activityOne(_ geohash: String) -> String {
            String(
                format: String(localized: "content.empty.activity_one", comment: "Empty mesh timeline hint when one person is chatting in a nearby geohash channel; placeholder is the geohash"),
                locale: .current,
                geohash
            )
        }

        static func activityMany(_ geohash: String) -> String {
            String(
                format: String(localized: "content.empty.activity_many", comment: "Empty mesh timeline hint when several people are chatting in a nearby geohash channel; placeholder is the geohash"),
                locale: .current,
                geohash
            )
        }
    }

    private var hasNearbyPeers: Bool {
        peerListModel.connectedMeshPeerCount > 0 || peerListModel.reachableMeshPeerCount > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !compact && !hasNearbyPeers {
                narrationLine(Strings.noPeersNearby)
            }
            if let conversation = nearbyConversation {
                conversationHint(conversation)
            }
        }
        .frame(minHeight: compact ? 0 : fillHeight, alignment: .top)
        .onReceive(refreshTimer) { _ in
            guard scenePhase == .active else { return }
            refreshTick += 1
        }
    }
}

private extension MeshEmptyStateView {
    var nearbyConversation: NearbyConversation? {
        activityTracker.mostActiveConversation(among: locationChannelsModel.availableChannels)
    }

    func conversationHint(_ conversation: NearbyConversation) -> some View {
        let headline = conversation.messageCount == 1
            ? Strings.activityOne(conversation.channel.geohash)
            : Strings.activityMany(conversation.channel.geohash)

        return Button {
            locationChannelsModel.markTeleported(for: conversation.channel.geohash, false)
            locationChannelsModel.select(.location(conversation.channel))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                actionLine("💬 \(headline)")
                narrationLine("  \(previewText(for: conversation.lastMessage))")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func previewText(for message: GeohashChatPreview) -> String {
        let maxLen = TransportConfig.uiGeoNotifySnippetMaxLen
        var content = message.content
        if content.count > maxLen {
            content = String(content.prefix(maxLen)) + "…"
        }
        let ago = Self.relativeTimeFormatter.localizedString(for: message.timestamp, relativeTo: Date())
        return "<\(message.senderName)> \(content) · \(ago)"
    }

    func narrationLine(_ text: String) -> some View {
        emptyStateLine(text, color: palette.secondary.opacity(0.9))
    }

    /// Tappable lines render in the primary color so they read as actions
    /// amid the grey narration.
    func actionLine(_ text: String) -> some View {
        emptyStateLine(text, color: palette.primary)
    }

    func emptyStateLine(_ text: String, color: Color) -> some View {
        let formatted = theme.usesGlassChrome ? text : "* \(text)\u{00A0}*"
        return Text(verbatim: formatted)
            .bitchatFont(size: 13)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
