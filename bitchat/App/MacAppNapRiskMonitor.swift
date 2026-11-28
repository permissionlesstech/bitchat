//
// MacAppNapRiskMonitor.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(macOS)

import AppKit
import Combine
import Foundation

/// Tracks when macOS would apply App Nap to this process.
///
/// App Nap throttles a backgrounded app whose windows are all minimized or
/// fully occluded. While a window is visible, the OS does not nap us and an
/// activity assertion would be wasted battery for no benefit (#1593).
@MainActor
final class MacAppNapRiskMonitor: ObservableObject {
    @Published private(set) var appNapWouldApply = false

    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification
        ]
        for name in names {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.refresh()
                }
            )
        }
        refresh()
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    func refresh() {
        appNapWouldApply = Self.computeAppNapWouldApply()
    }

    /// True when every window is minimized or not visibly on screen.
    static func computeAppNapWouldApply() -> Bool {
        let windows = NSApplication.shared.windows.filter { $0.isVisible || $0.isMiniaturized }
        guard !windows.isEmpty else { return true }
        return !windows.contains { window in
            !window.isMiniaturized && window.occlusionState.contains(.visible)
        }
    }
}

#endif
