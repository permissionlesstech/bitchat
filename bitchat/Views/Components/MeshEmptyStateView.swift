//
// MeshEmptyStateView.swift
// bitchat
//
// The empty mesh timeline, upgraded from a dead end into a live surface:
// a sonar shows the radio scanning, the daily sightings tally proves the
// spot isn't dead, the liveliest nearby geohash conversation is one tap
// away, and notes left at this place surface when there are any.
// This is free and unencumbered software released into the public domain.
//

import SwiftUI

struct MeshEmptyStateView: View {
    /// Visible chat height to fill; the radar centers in the space left
    /// below the narration. Zero (previews) keeps a compact layout.
    var fillHeight: CGFloat = 0
    /// Ambient-footer mode, appended below archived echoes: skips the
    /// intro/help narration (the timeline isn't empty) and shrinks the
    /// radar, keeping the sightings tally and the live hints visible.
    var compact: Bool = false

    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @ObservedObject private var activityTracker = GeohashChatActivityTracker.shared
    @ObservedObject private var sightingsTracker = MeshSightingsTracker.shared
    @ObservedObject private var nearbyNotes = NearbyNotesCounter.shared

    @ThemedPalette private var palette

    /// The activity window is evaluated at render time; without new events
    /// nothing would trigger a re-render, so a stale "people are talking"
    /// hint could linger. A slow tick keeps the hints and relative times
    /// honest.
    @State private var refreshTick = 0
    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private enum Strings {
        static let meshIntro = String(localized: "content.empty.mesh_intro", comment: "First line of the empty mesh timeline explaining what the mesh channel is")
        static let switchHint = String(localized: "content.empty.switch_hint", comment: "Empty timeline hint pointing at the channel switcher and the help screen")
        static let sightingsOne = String(localized: "content.empty.sightings_one", comment: "Empty mesh timeline stat when exactly one device came within range today")
        static let checkNotes = String(localized: "content.empty.check_notes", comment: "Empty mesh timeline action that starts looking for notes left at this place; before tapping, no lookup runs")

        static func sightingsMany(_ count: Int) -> String {
            String(
                format: String(localized: "content.empty.sightings_many", comment: "Empty mesh timeline stat counting devices that came within range today"),
                locale: .current,
                count
            )
        }

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

    /// The radar means "searching for people": once anyone is connected or
    /// reachable on the mesh, the search is over and the sweep goes away.
    private var isSearchingForPeers: Bool {
        peerListModel.connectedMeshPeerCount == 0 && peerListModel.reachableMeshPeerCount == 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if compact {
                if isSearchingForPeers {
                    radarBlock
                }
                if let conversation = nearbyConversation {
                    conversationHint(conversation)
                }
                if showsCheckNotesHint {
                    checkNotesHint
                }
            } else {
                // The radar + tally already say "scanning, nobody yet", so
                // the narration stays to two lines with the live hint after
                // them, not wedged in between.
                narrationLine(Strings.meshIntro)
                narrationLine(Strings.switchHint)
                if let conversation = nearbyConversation {
                    conversationHint(conversation)
                }
                if showsCheckNotesHint {
                    checkNotesHint
                }

                // The radar centers in whatever space is left below the
                // text — the flexible spacers split it evenly.
                if isSearchingForPeers {
                    Spacer(minLength: 24)
                    radarBlock
                    Spacer(minLength: 12)
                }
            }
        }
        .frame(minHeight: compact ? 0 : fillHeight, alignment: .top)
        .onReceive(refreshTimer) { _ in
            refreshTick += 1
            // Roll the tally over if the local day changed while idle.
            sightingsTracker.refreshForDisplay()
        }
    }

    /// The radar with today's tally as its caption — the stat belongs to
    /// the scanning visual, not the narration lines.
    private var radarBlock: some View {
        VStack(spacing: 4) {
            MeshRadarView(height: compact ? 44 : 72)
            if sightingsTracker.todayCount > 0 {
                Text(verbatim: sightingsText)
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.secondary.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private extension MeshEmptyStateView {
    var nearbyConversation: NearbyConversation? {
        activityTracker.mostActiveConversation(among: locationChannelsModel.availableChannels)
    }

    /// Tap-to-reveal: the nearby-notes counter never subscribes on its own —
    /// looking at the mesh timeline must not open a building-precision relay
    /// REQ (a passive location side-channel). This static line is the one
    /// explicit act that unlocks it; nothing touches the network until the
    /// tap. It only renders when location permission is already granted
    /// (the tap never prompts, so without permission it would dead-end
    /// silently). Once revealed it yields to today's live strip and count,
    /// and the app-info setting stays the kill switch.
    var showsCheckNotesHint: Bool {
        nearbyNotes.offersRevealHint(permissionState: locationChannelsModel.permissionState)
    }

    var checkNotesHint: some View {
        Button {
            NearbyNotesCounter.shared.reveal()
        } label: {
            actionLine("📍 \(Strings.checkNotes)")
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The visual label carries decorative asterisks and an emoji; expose
        // just the localized action text to assistive tech.
        .accessibilityLabel(Strings.checkNotes)
    }

    var sightingsText: String {
        sightingsTracker.todayCount == 1
            ? Strings.sightingsOne
            : Strings.sightingsMany(sightingsTracker.todayCount)
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
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let ago = formatter.localizedString(for: message.timestamp, relativeTo: Date())
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
        // Non-breaking space before the closing asterisk so a tight wrap
        // can't orphan a lone "*" onto its own line.
        Text(verbatim: "* \(text)\u{00A0}*")
            .bitchatFont(size: 13)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
