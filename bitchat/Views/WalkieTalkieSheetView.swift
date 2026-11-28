//
// WalkieTalkieSheetView.swift
// bitchat
//
// Dedicated push-to-talk deck for Nearby (#mesh) and mesh-reachable DMs:
// big thumb-friendly hold-to-talk pad, live voice-level ring, slide-up
// hands-free lock, slide-left cancel, quick channel switcher, and 1-tap
// live/mute/chirp controls.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct WalkieTalkieSheetView: View {
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @ObservedObject var voiceRecordingVM: VoiceRecordingViewModel
    @ObservedObject private var pttPreferences = PTTPreferences.shared
    #if os(iOS)
    @ObservedObject private var systemPTT = SystemPTTChannelManager.shared
    #endif
    @Environment(\.dismiss) private var dismiss
    @ThemedPalette private var palette

    @State private var isSlideCanceling = false
    @State private var isApproachingLock = false
    @State private var padDragOffset: CGSize = .zero

    /// Whether the user can switch channels from inside the Walkie-Talkie deck.
    /// Switching from a DM to Nearby dismisses the DM sheet cleanly; switching
    /// between DMs updates the active conversation in place.
    var allowsChannelSwitching: Bool = true

    private var currentTarget: VoiceNoteTarget {
        if let peerID = privateConversationModel.selectedPeerID {
            return .privateChat(peerID)
        }
        return .publicMesh
    }

    #if os(iOS)
    private var currentChannelKey: String {
        if let peerID = privateConversationModel.selectedPeerID {
            return privateConversationModel.autoListenPolicyKey(for: peerID)
        }
        return "mesh.public"
    }
    #endif

    private var availability: ChatViewModel.LiveVoiceAvailability {
        conversationUIModel.currentLiveVoiceAvailability()
    }

    private var isLiveReady: Bool {
        switch availability {
        case .liveReadyPublic, .liveReadyDM, .liveReadyGroup:
            return true
        case .disabledByUser, .dmHandshaking, .dmOutOfRadioRange, .groupNoReachableMembers, .unsupported:
            return false
        }
    }

    private var activeTalker: String? {
        conversationUIModel.activeTalkerInCurrentContext(
            selectedPeerID: privateConversationModel.selectedPeerID
        )
    }

    private var currentChannelName: String {
        if let header = privateConversationModel.selectedHeaderState {
            return header.isGroupConversation ? header.displayName : "@\(header.displayName)"
        }
        return String(localized: "walkie.channel.nearby", defaultValue: "Nearby (#mesh)", comment: "Channel name for public Nearby mesh in the walkie-talkie deck")
    }

    private var reachableMeshPeers: [MeshPeerRow] {
        peerListModel.meshRows.filter { !$0.isMe && ($0.isConnected || $0.isReachable) && !$0.isBlocked }
    }

    private var statusDescriptor: (color: Color, icon: String, text: String) {
        switch availability {
        case .liveReadyPublic:
            let count = peerListModel.reachableMeshPeerCount
            return (
                palette.accent,
                "dot.radiowaves.left.and.right",
                String(
                    format: String(
                        localized: "walkie.status.live_nearby",
                        defaultValue: "Live · %lld nearby on Bluetooth mesh",
                        comment: "Status caption in the walkie-talkie deck when live broadcast is ready in Nearby"
                    ),
                    locale: .current,
                    count
                )
            )
        case .liveReadyDM:
            let name = privateConversationModel.selectedHeaderState?.displayName ?? ""
            return (
                palette.accent,
                "lock.fill",
                String(
                    format: String(
                        localized: "walkie.status.live_dm",
                        defaultValue: "Live · Encrypted direct channel with @%@",
                        comment: "Status caption in the walkie-talkie deck when live encrypted DM streaming is ready"
                    ),
                    locale: .current,
                    name
                )
            )
        case .liveReadyGroup(let reachableCount):
            return (
                palette.accent,
                "person.3.fill",
                String(
                    format: String(
                        localized: "walkie.status.live_group",
                        defaultValue: "Live · Streaming encrypted to %lld nearby group members",
                        comment: "Status caption in the walkie-talkie deck when live encrypted mesh group streaming is ready"
                    ),
                    locale: .current,
                    reachableCount
                )
            )
        case .groupNoReachableMembers:
            return (
                Color.orange,
                "person.3",
                String(
                    localized: "walkie.status.group_none_nearby",
                    defaultValue: "No group members in Bluetooth range · Saves local voice note",
                    comment: "Status caption when no members of a mesh group are currently reachable over Bluetooth"
                )
            )
        case .dmHandshaking:
            return (
                Color.orange,
                "lock.rotation",
                String(
                    localized: "walkie.status.handshaking",
                    defaultValue: "Securing session · Sends as voice note until connected",
                    comment: "Status caption when a mesh DM peer is still completing the Noise handshake"
                )
            )
        case .dmOutOfRadioRange:
            return (
                Color.orange,
                "antenna.radiowaves.left.and.right.slash",
                String(
                    localized: "walkie.status.out_of_range",
                    defaultValue: "Out of radio range · Sends as a voice note",
                    comment: "Status caption when the DM peer is not reachable over Bluetooth mesh"
                )
            )
        case .disabledByUser:
            return (
                palette.secondary,
                "waveform",
                String(
                    localized: "walkie.status.voice_note_mode",
                    defaultValue: "Voice note mode · Turn on Live to stream as you talk",
                    comment: "Status caption when live push-to-talk is toggled off"
                )
            )
        case .unsupported:
            return (
                palette.secondary,
                "mic.slash",
                String(
                    localized: "walkie.status.unsupported",
                    defaultValue: "Switch to Nearby or a Bluetooth DM to talk live",
                    comment: "Status caption when the current channel does not support live push-to-talk"
                )
            )
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            topHeader

            liveModeCard

            if let talker = activeTalker {
                incomingTalkerBanner(nickname: talker)
            }

            Spacer(minLength: 4)

            pttCenterPad

            Spacer(minLength: 4)

            bottomControlsRow
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .themedSheetBackground()
        .foregroundColor(palette.primary)
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 500)
        #endif
        .onAppear {
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
        }
        .onDisappear {
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
            if voiceRecordingVM.state.isActive && !voiceRecordingVM.isLockedRecording {
                voiceRecordingVM.cancel()
            }
        }
        .alert(
            Text(String(localized: "voice.error.title", defaultValue: "Recording error", comment: "Title of the voice recording error alert")),
            isPresented: Binding(
                get: { voiceRecordingVM.showAlert },
                set: { if !$0 { voiceRecordingVM.showAlert = false } }
            ),
            actions: {
                Button(String(localized: "common.ok"), role: .cancel) {}
                if voiceRecordingVM.state == .permissionDenied {
                    Button(String(localized: "location_channels.action.open_settings")) {
                        SystemSettings.microphone.open()
                    }
                }
            },
            message: {
                Text(voiceRecordingVM.state.alertMessage)
            }
        )
    }

    // MARK: - Top Header

    private var topHeader: some View {
        HStack(spacing: 10) {
            if allowsChannelSwitching {
                Menu {
                    Button {
                        if privateConversationModel.selectedPeerID != nil {
                            privateConversationModel.endConversation()
                        }
                    } label: {
                        HStack {
                            Label(
                                String(localized: "walkie.channel.nearby", defaultValue: "Nearby (#mesh)", comment: "Channel name for public Nearby mesh in the walkie-talkie deck"),
                                systemImage: "antenna.radiowaves.left.and.right"
                            )
                            if privateConversationModel.selectedPeerID == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    if !reachableMeshPeers.isEmpty {
                        Section(
                            String(
                                localized: "walkie.channel.nearby_people",
                                defaultValue: "Nearby people",
                                comment: "Menu section listing mesh-reachable DM peers in the walkie-talkie channel picker"
                            )
                        ) {
                            ForEach(reachableMeshPeers) { peer in
                                Button {
                                    privateConversationModel.openConversation(for: peer.peerID)
                                } label: {
                                    HStack {
                                        Text(verbatim: "@\(peer.displayName)")
                                        if privateConversationModel.selectedPeerID?.toShort() == peer.peerID.toShort() {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if !peerListModel.groupRows.isEmpty {
                        Section(
                            String(
                                localized: "walkie.channel.groups",
                                defaultValue: "Groups",
                                comment: "Menu section listing mesh groups in the walkie-talkie channel picker"
                            )
                        ) {
                            ForEach(peerListModel.groupRows) { group in
                                Button {
                                    privateConversationModel.openConversation(for: group.peerID)
                                } label: {
                                    HStack {
                                        Text(verbatim: "#\(group.name)")
                                        if privateConversationModel.selectedPeerID == group.peerID {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "radio")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(isLiveReady ? palette.accent : palette.secondary)
                        Text(currentChannelName)
                            .bitchatFont(size: 16, weight: .bold)
                            .foregroundColor(palette.primary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(palette.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(palette.cardBackground)
                    .overlay(
                        Capsule().stroke(palette.cardBorder, lineWidth: 1)
                    )
                    .clipShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel(
                    String(
                        localized: "walkie.accessibility.channel_picker",
                        defaultValue: "Switch walkie-talkie channel",
                        comment: "Accessibility label for the channel switcher button in the walkie-talkie deck"
                    )
                )
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "radio")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isLiveReady ? palette.accent : palette.secondary)
                    Text(currentChannelName)
                        .bitchatFont(size: 16, weight: .bold)
                        .foregroundColor(palette.primary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(palette.secondary.opacity(0.75))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "common.close", defaultValue: "Close", comment: "Close button"))
        }
    }

    // MARK: - Live Mode Card

    private var liveModeCard: some View {
        let status = statusDescriptor
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        String(
                            localized: "walkie.toggle.title",
                            defaultValue: "Live Walkie-Talkie",
                            comment: "Toggle title in the walkie-talkie deck to arm real-time voice streaming"
                        )
                    )
                    .bitchatFont(size: 14, weight: .semibold)
                    .foregroundColor(palette.primary)

                    Text(
                        pttPreferences.liveVoiceEnabled
                        ? String(
                            localized: "walkie.toggle.subtitle_on",
                            defaultValue: "Streams as you speak · Incoming live voice plays aloud",
                            comment: "Subtitle when Live Walkie-Talkie is turned on"
                        )
                        : String(
                            localized: "walkie.toggle.subtitle_off",
                            defaultValue: "Off · Holding records a normal voice note",
                            comment: "Subtitle when Live Walkie-Talkie is turned off"
                        )
                    )
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { pttPreferences.liveVoiceEnabled },
                        set: { pttPreferences.setLiveVoiceEnabled($0) }
                    )
                )
                .labelsHidden()
                .tint(palette.accent)
            }

            Divider().opacity(0.4)

            HStack(spacing: 6) {
                Image(systemName: status.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(status.color)
                Text(verbatim: status.text)
                    .bitchatFont(size: 11, weight: .medium)
                    .foregroundColor(palette.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if pttPreferences.liveVoiceEnabled {
                    if privateConversationModel.selectedPeerID == nil {
                        Button {
                            pttPreferences.setPublicAutoPlayEnabled(!pttPreferences.publicAutoPlayEnabled)
                            WalkieFeedback.detent()
                        } label: {
                            Text(
                                pttPreferences.publicAutoPlayEnabled
                                ? String(localized: "walkie.public_autoplay.on", defaultValue: "Public Auto-Play On", comment: "Compact pill when public Nearby speaker autoplay is enabled")
                                : String(localized: "walkie.public_autoplay.off", defaultValue: "Public Auto-Play Off", comment: "Compact pill when public Nearby speaker autoplay is disabled")
                            )
                            .bitchatFont(size: 10, weight: .semibold)
                            .foregroundColor(pttPreferences.publicAutoPlayEnabled ? palette.accent : palette.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(
                                    pttPreferences.publicAutoPlayEnabled
                                    ? palette.accent.opacity(0.14)
                                    : palette.secondary.opacity(0.14)
                                )
                            )
                        }
                        .buttonStyle(.plain)
                    } else if let peerID = privateConversationModel.selectedPeerID {
                        let policy = privateConversationModel.autoListenPolicy(for: peerID)
                        Menu {
                            ForEach(PTTAutoListenPolicy.allCases) { option in
                                Button {
                                    privateConversationModel.setAutoListenPolicy(option, for: peerID)
                                } label: {
                                    HStack {
                                        Text(option.displayName)
                                        if policy == option {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text(policy.shortLabel)
                                    .bitchatFont(size: 10, weight: .semibold)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                            }
                            .foregroundColor(policy == .never ? palette.secondary : palette.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(palette.accent.opacity(0.12)))
                        }
                        .menuStyle(.borderlessButton)
                    }
                }
            }
        }
        .padding(12)
        .background(palette.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Incoming Talker Banner

    private func incomingTalkerBanner(nickname: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .modifier(PulsingOpacityModifier(active: true))

            Text(
                String(
                    format: String(
                        localized: "walkie.banner.speaking",
                        defaultValue: "@%@ is talking live",
                        comment: "Banner announcing who is streaming live voice right now"
                    ),
                    locale: .current,
                    nickname
                )
            )
            .bitchatFont(size: 13, weight: .semibold)
            .foregroundColor(palette.primary)
            .lineLimit(1)

            Spacer()

            LiveVoiceBadge()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Center Push-to-Talk Pad

    private var padFillColor: Color {
        if isSlideCanceling { return .orange }
        if voiceRecordingVM.state.isActive { return .red }
        if activeTalker != nil { return Color.red.opacity(0.7) }
        return isLiveReady ? palette.accent : palette.secondary.opacity(0.85)
    }

    private var padOuterHaloScale: CGFloat {
        guard voiceRecordingVM.state.isActive else { return 1.0 }
        // Base active pulse + live microphone loudness boost.
        return 1.08 + CGFloat(voiceRecordingVM.audioLevel) * 0.28
    }

    private var pttCenterPad: some View {
        let canTalk = conversationUIModel.canSendVoiceInCurrentContext && availability != .unsupported
        return VStack(spacing: 14) {
            ZStack {
                // Voice-reactive outer halo ring
                Circle()
                    .fill(padFillColor.opacity(voiceRecordingVM.state.isActive ? 0.22 : 0.08))
                    .frame(width: 196, height: 196)
                    .scaleEffect(padOuterHaloScale)
                    .animation(.easeOut(duration: 0.08), value: voiceRecordingVM.audioLevel)
                    .animation(.easeOut(duration: 0.16), value: voiceRecordingVM.state.isActive)

                // Secondary crisp guide ring
                Circle()
                    .stroke(padFillColor.opacity(0.35), lineWidth: 2)
                    .frame(width: 184, height: 184)

                // Primary tactile push-to-talk circle
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [padFillColor, padFillColor.opacity(0.82)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 168, height: 168)
                    .shadow(color: padFillColor.opacity(0.35), radius: voiceRecordingVM.state.isActive ? 18 : 10, y: 4)
                    .scaleEffect(voiceRecordingVM.state.isActive ? 0.96 : 1.0)
                    .animation(.spring(response: 0.22, dampingFraction: 0.72), value: voiceRecordingVM.state.isActive)

                VStack(spacing: 8) {
                    Image(systemName: padCenterIcon)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundColor(.white)

                    if voiceRecordingVM.state.isActive {
                        if isSlideCanceling {
                            Text(
                                String(
                                    localized: "walkie.hud.release_to_cancel",
                                    defaultValue: "Release to cancel",
                                    comment: "Prompt when user slid left past cancel threshold"
                                )
                            )
                            .bitchatFont(size: 12, weight: .bold)
                            .foregroundColor(.white)
                        } else {
                            TimelineView(.periodic(from: .now, by: 0.05)) { context in
                                Text(voiceRecordingVM.formattedDuration(for: context.date))
                                    .bitchatFont(size: 16, weight: .bold)
                                    .foregroundColor(.white)
                                    .monospacedDigit()
                            }
                            Text(
                                voiceRecordingVM.isLockedRecording
                                ? String(localized: "walkie.pad.tap_to_send", defaultValue: "Tap to send", comment: "Prompt on the locked walkie-talkie button")
                                : (voiceRecordingVM.isLiveStreaming
                                    ? String(localized: "walkie.pad.on_air", defaultValue: "LIVE · ON AIR", comment: "Status shown on the walkie-talkie pad while transmitting live")
                                    : String(localized: "walkie.pad.recording", defaultValue: "RECORDING", comment: "Status shown on the walkie-talkie pad while recording a voice note"))
                            )
                            .bitchatFont(size: 11, weight: .bold)
                            .foregroundColor(.white.opacity(0.92))
                        }
                    } else {
                        Text(
                            isLiveReady
                            ? String(localized: "walkie.pad.hold_live", defaultValue: "Hold to Talk", comment: "Idle label on the walkie-talkie button when live mode is armed")
                            : String(localized: "walkie.pad.hold_record", defaultValue: "Hold to Record", comment: "Idle label on the walkie-talkie button when voice-note fallback is active")
                        )
                        .bitchatFont(size: 14, weight: .bold)
                        .foregroundColor(.white)
                    }
                }
            }
            .offset(
                x: max(-28, min(0, padDragOffset.width * 0.25)),
                y: max(-24, min(0, padDragOffset.height * 0.25))
            )
            .opacity(canTalk ? 1.0 : 0.45)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard canTalk else { return }
                        if voiceRecordingVM.isLockedRecording {
                            return
                        }
                        if voiceRecordingVM.state == .idle {
                            voiceRecordingVM.start(shouldShow: true, target: currentTarget)
                        }
                        if voiceRecordingVM.state.isActive {
                            padDragOffset = value.translation
                            let cancelHit = value.translation.width <= -72
                            if cancelHit != isSlideCanceling {
                                isSlideCanceling = cancelHit
                                WalkieFeedback.detent()
                            }
                            let lockHit = !cancelHit && value.translation.height <= -64
                            if lockHit != isApproachingLock {
                                isApproachingLock = lockHit
                                if lockHit {
                                    voiceRecordingVM.lockRecording()
                                    padDragOffset = .zero
                                    isApproachingLock = false
                                    isSlideCanceling = false
                                }
                            }
                        }
                    }
                    .onEnded { _ in
                        guard canTalk else { return }
                        if voiceRecordingVM.isLockedRecording {
                            // Tapping the locked pad stops and sends.
                            voiceRecordingVM.stopLockedRecording(
                                completion: conversationUIModel.sendVoiceNote(at:target:)
                            )
                            return
                        }
                        let shouldCancel = isSlideCanceling
                        isSlideCanceling = false
                        isApproachingLock = false
                        padDragOffset = .zero
                        if shouldCancel {
                            voiceRecordingVM.cancel()
                        } else {
                            voiceRecordingVM.finish(completion: conversationUIModel.sendVoiceNote(at:target:))
                        }
                    }
            )
            .accessibilityLabel(
                isLiveReady
                ? String(localized: "walkie.pad.hold_live", defaultValue: "Hold to Talk", comment: "Accessibility label for the push-to-talk pad")
                : String(localized: "walkie.pad.hold_record", defaultValue: "Hold to Record", comment: "Accessibility label for the voice note pad")
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                guard canTalk else { return }
                if voiceRecordingVM.state.isActive {
                    voiceRecordingVM.finish(completion: conversationUIModel.sendVoiceNote(at:target:))
                } else {
                    voiceRecordingVM.start(shouldShow: true, target: currentTarget)
                }
            }

            // Secondary gesture hint / locked-mode cancel action
            if voiceRecordingVM.isLockedRecording {
                Button(role: .destructive) {
                    voiceRecordingVM.cancel()
                } label: {
                    Label(
                        String(localized: "common.cancel", defaultValue: "Cancel", comment: "Cancel locked recording"),
                        systemImage: "xmark.circle.fill"
                    )
                    .bitchatFont(size: 13, weight: .semibold)
                    .foregroundColor(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.red.opacity(0.14)))
                }
                .buttonStyle(.plain)
            } else if voiceRecordingVM.state.isActive {
                Text(
                    String(
                        localized: "walkie.pad.gesture_hint",
                        defaultValue: "↑ Slide up to lock · ← Slide left to cancel",
                        comment: "Gesture guidance shown below the push-to-talk pad while holding"
                    )
                )
                .bitchatFont(size: 12)
                .foregroundColor(palette.secondary)
            } else if let hint = voiceRecordingVM.briefHint {
                Text(verbatim: hint)
                    .bitchatFont(size: 12, weight: .medium)
                    .foregroundColor(palette.accent)
            } else {
                Text(
                    String(
                        localized: "walkie.pad.idle_hint",
                        defaultValue: "Press and hold to talk · Release to send",
                        comment: "Idle guidance shown below the push-to-talk pad"
                    )
                )
                .bitchatFont(size: 12)
                .foregroundColor(palette.secondary)
            }
        }
    }

    private var padCenterIcon: String {
        if isSlideCanceling { return "trash.fill" }
        if voiceRecordingVM.isLockedRecording { return "lock.fill" }
        if voiceRecordingVM.state.isActive {
            return voiceRecordingVM.isLiveStreaming ? "dot.radiowaves.left.and.right" : "waveform"
        }
        return "mic.fill"
    }

    // MARK: - Bottom Quick Controls

    private var bottomControlsRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    pttPreferences.toggleAutoListenMuted()
                    if pttPreferences.isAutoListenMuted {
                        conversationUIModel.muteActiveLiveVoicePlayback()
                    }
                    WalkieFeedback.detent()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: pttPreferences.isAutoListenMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(
                            pttPreferences.isAutoListenMuted
                            ? String(localized: "walkie.control.speaker_muted", defaultValue: "Speaker muted", comment: "Walkie-talkie control pill when incoming live audio is muted")
                            : String(localized: "walkie.control.listening", defaultValue: "Listening aloud", comment: "Walkie-talkie control pill when incoming live audio will play aloud")
                        )
                        .bitchatFont(size: 12, weight: .semibold)
                        .lineLimit(1)
                    }
                    .foregroundColor(pttPreferences.isAutoListenMuted ? palette.secondary : palette.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(palette.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                pttPreferences.isAutoListenMuted ? palette.cardBorder : palette.accent.opacity(0.4),
                                lineWidth: 1
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    pttPreferences.setToneCuesEnabled(!pttPreferences.toneCuesEnabled)
                    WalkieFeedback.detent()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: pttPreferences.toneCuesEnabled ? "bell.badge.fill" : "bell.slash")
                            .font(.system(size: 13, weight: .semibold))
                        Text(
                            pttPreferences.toneCuesEnabled
                            ? String(localized: "walkie.control.chirp_on", defaultValue: "Cue tones on", comment: "Walkie-talkie control pill when mic-key cue tones are enabled")
                            : String(localized: "walkie.control.chirp_off", defaultValue: "Cue tones off", comment: "Walkie-talkie control pill when mic-key cue tones are disabled")
                        )
                        .bitchatFont(size: 12, weight: .semibold)
                        .lineLimit(1)
                    }
                    .foregroundColor(pttPreferences.toneCuesEnabled ? palette.primary : palette.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(palette.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(palette.cardBorder, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            #if os(iOS)
            systemPTTControlRow
            #endif
        }
    }

    #if os(iOS)
    private var systemPTTControlRow: some View {
        VStack(spacing: 4) {
            Button {
                if systemPTT.isActive {
                    systemPTT.leaveCurrentChannel()
                } else {
                    if !pttPreferences.liveVoiceEnabled {
                        pttPreferences.setLiveVoiceEnabled(true)
                    }
                    systemPTT.joinChannel(
                        SystemPTTChannelInfo(
                            channelKey: currentChannelKey,
                            displayName: currentChannelName,
                            target: currentTarget
                        )
                    )
                }
                WalkieFeedback.detent()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: systemPTT.isActive ? "lock.open.display" : "iphone.radiowaves.left.and.right")
                        .font(.system(size: 13, weight: .semibold))
                    Text(
                        systemPTT.isActive
                        ? String(localized: "walkie.system_ptt.active", defaultValue: "Lock-Screen PTT Active · Tap to Leave", comment: "Button when iOS PushToTalk channel is active on Lock Screen and Dynamic Island")
                        : String(localized: "walkie.system_ptt.join", defaultValue: "Pin to Lock Screen & Dynamic Island", comment: "Button to join iOS system PushToTalk channel")
                    )
                    .bitchatFont(size: 12, weight: .semibold)
                    .lineLimit(1)
                }
                .foregroundColor(systemPTT.isActive ? palette.accent : palette.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            systemPTT.isActive ? palette.accent.opacity(0.5) : palette.cardBorder,
                            lineWidth: 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            if case .unavailable(let reason) = systemPTT.status {
                Text(verbatim: reason)
                    .bitchatFont(size: 10)
                    .foregroundColor(palette.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    #endif
}
