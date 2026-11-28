//
// WalkieFeedback.swift
// bitchat
//
// Tactile and optional audio cue feedback for push-to-talk / walkie-talkie
// sessions so users can operate eyes-free without clipping their first word.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
#if os(iOS)
import AudioToolbox
import UIKit
#endif

@MainActor
enum WalkieFeedback {
    /// Fires the moment capture actually begins recording (after AVAudioSession
    /// activation settles) so the user knows the mic is hot.
    static func micArmed(isLive: Bool) {
        guard !TestEnvironment.isRunningTests else { return }
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: isLive ? .medium : .light)
        generator.prepare()
        generator.impactOccurred()
        if isLive && PTTSettings.toneCuesEnabled {
            // Standard subtle iOS begin-record cue; respects the hardware silent switch.
            AudioServicesPlaySystemSound(1113)
        }
        #endif
    }

    /// Fires when a valid transmission finishes and is sent.
    static func micReleased(isLive: Bool) {
        guard !TestEnvironment.isRunningTests else { return }
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
        if isLive && PTTSettings.toneCuesEnabled {
            // Standard subtle iOS end-record / roger cue; respects silent switch.
            AudioServicesPlaySystemSound(1114)
        }
        #endif
    }

    /// Fires when the user slides past the cancel threshold or locks hands-free.
    static func detent() {
        guard !TestEnvironment.isRunningTests else { return }
        #if os(iOS)
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
        #endif
    }

    /// Fires when an active recording is canceled.
    static func canceled() {
        guard !TestEnvironment.isRunningTests else { return }
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
        #endif
    }

    /// Fires softly when a remote talker starts streaming live into the current view.
    static func incomingBurstStarted() {
        guard !TestEnvironment.isRunningTests else { return }
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }
}
