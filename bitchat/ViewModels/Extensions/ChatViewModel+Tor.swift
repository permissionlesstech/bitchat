//
// ChatViewModel+Tor.swift
// bitchat
//
// Tor lifecycle handling for ChatViewModel
//

import Foundation
import Combine
import Tor

extension ChatViewModel {
    
    // MARK: - Tor notifications
    
    @objc func handleTorWillStart() {
        Task { @MainActor in
            // A fresh attempt can stall again, so let it be reported again.
            self.torStallAnnounced = false
            if !self.torStatusAnnounced && TorManager.shared.torEnforced {
                self.torStatusAnnounced = true
                // Post only in geohash channels (queue if not active)
                self.addGeohashOnlySystemMessage(
                    String(localized: "system.tor.starting", comment: "System message when Tor is starting")
                )
            }
        }
    }

    @objc func handleTorWillRestart() {
        Task { @MainActor in
            self.torRestartPending = true
            // Post only in geohash channels (queue if not active)
            self.addGeohashOnlySystemMessage(
                String(localized: "system.tor.restarting", comment: "System message when Tor is restarting")
            )
        }
    }

    @objc func handleTorDidBecomeReady() {
        Task { @MainActor in
            self.torStallAnnounced = false
            // Only announce "restarted" if we actually restarted this session
            if self.torRestartPending {
                // Post only in geohash channels (queue if not active)
                self.addGeohashOnlySystemMessage(
                    String(localized: "system.tor.restarted", comment: "System message when Tor has restarted")
                )
                self.torRestartPending = false
            } else if TorManager.shared.torEnforced && !self.torInitialReadyAnnounced {
                // Initial start completed
                self.addGeohashOnlySystemMessage(
                    String(localized: "system.tor.started", comment: "System message when Tor has started")
                )
                self.torInitialReadyAnnounced = true
            }
        }
    }

    /// Bootstrap spent its whole deadline without connecting. Say so rather
    /// than leaving "starting tor…" on screen indefinitely: on a network that
    /// blocks Tor this is the terminal state, and someone needs to know that
    /// internet features are stalled while the mesh still works.
    @objc func handleTorBootstrapDidStall() {
        Task { @MainActor in
            guard TorManager.shared.torEnforced else { return }
            // torEnforced is a compile-time constant in release builds; the
            // runtime preference is what says whether anyone is waiting on
            // Tor. Turning Tor off mid-bootstrap must not read as blocking.
            guard NetworkActivationService.persistedTorPreference() else { return }
            guard !self.torStallAnnounced else { return }
            self.torStallAnnounced = true
            self.addGeohashOnlySystemMessage(
                String(
                    localized: "system.tor.blocked",
                    defaultValue: "tor could not connect — this network may be blocking it. mesh messaging still works; location channels and internet delivery are paused until tor gets through.",
                    comment: "System message shown when Tor bootstrap runs out its deadline without connecting, which is what a network that blocks Tor looks like"
                )
            )
        }
    }

    @objc func handleTorPreferenceChanged(_: Notification) {
        Task { @MainActor in
            self.torStatusAnnounced = false
            self.torInitialReadyAnnounced = false
            self.torRestartPending = false
            self.torStallAnnounced = false
        }
    }
}
