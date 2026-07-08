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
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var appChromeModel: AppChromeModel
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
        static let meshWaiting = String(localized: "content.empty.mesh_waiting", comment: "Second line of the empty mesh timeline saying no peers are in range yet")
        static let switchHint = String(localized: "content.empty.switch_hint", comment: "Empty timeline hint pointing at the channel switcher and the help screen")
        static let sightingsOne = String(localized: "content.empty.sightings_one", comment: "Empty mesh timeline stat when exactly one device came within range today")

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

        static let notesOne = String(localized: "content.empty.notes_one", comment: "Empty mesh timeline hint when exactly one note was left at this place")

        static func notesMany(_ count: Int) -> String {
            String(
                format: String(localized: "content.empty.notes_many", comment: "Empty mesh timeline hint counting notes left at this place"),
                locale: .current,
                count
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MeshRadarView()
                .padding(.bottom, 2)
            narrationLine(Strings.meshIntro)
            narrationLine(Strings.meshWaiting)
            if sightingsTracker.todayCount > 0 {
                narrationLine(sightingsText)
            }
            if let conversation = nearbyConversation {
                conversationHint(conversation)
            }
            if nearbyNotes.noteCount > 0 {
                notesHint
            }
            narrationLine(Strings.switchHint)
        }
        .onAppear { NearbyNotesCounter.shared.activate() }
        .onDisappear { NearbyNotesCounter.shared.deactivate() }
        .onReceive(refreshTimer) { _ in refreshTick += 1 }
    }
}

private extension MeshEmptyStateView {
    var nearbyConversation: NearbyConversation? {
        activityTracker.mostActiveConversation(among: locationChannelsModel.availableChannels)
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

    var notesHint: some View {
        let text = nearbyNotes.noteCount == 1
            ? Strings.notesOne
            : Strings.notesMany(nearbyNotes.noteCount)

        return Button {
            appChromeModel.presentNotices(geoTab: true)
        } label: {
            actionLine("📍 \(text)")
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
