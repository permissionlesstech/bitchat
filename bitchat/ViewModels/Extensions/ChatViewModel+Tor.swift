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
            if !self.torStatusAnnounced && TorManager.shared.torEnforced {
                self.torStatusAnnounced = true
                // Post only in geohash channels (queue if not active)
                self.addGeohashOnlySystemMessage(
                    String(localized: "system.tor.starting", defaultValue: "starting tor...", comment: "System message when Tor is starting")
                )
            }
        }
    }

    @objc func handleTorWillRestart() {
        Task { @MainActor in
            self.torRestartPending = true
            // Post only in geohash channels (queue if not active)
            self.addGeohashOnlySystemMessage(
                String(localized: "system.tor.restarting", defaultValue: "tor restarting to recover connectivity...", comment: "System message when Tor is restarting")
            )
        }
    }

    @objc func handleTorDidBecomeReady() {
        Task { @MainActor in
            // Only announce "restarted" if we actually restarted this session
            if self.torRestartPending {
                // Post only in geohash channels (queue if not active)
                self.addGeohashOnlySystemMessage(
                    String(localized: "system.tor.restarted", defaultValue: "tor restarted. network routing restored.", comment: "System message when Tor has restarted")
                )
                self.torRestartPending = false
            } else if TorManager.shared.torEnforced && !self.torInitialReadyAnnounced {
                // Initial start completed
                self.addGeohashOnlySystemMessage(
                    String(localized: "system.tor.started", defaultValue: "tor started. routing all chats via tor for IP privacy.", comment: "System message when Tor has started")
                )
                self.torInitialReadyAnnounced = true
            }
        }
    }

    @objc func handleTorPreferenceChanged(_ notification: Notification) {
        Task { @MainActor in
            self.torStatusAnnounced = false
            self.torInitialReadyAnnounced = false
            self.torRestartPending = false
        }
    }
}
