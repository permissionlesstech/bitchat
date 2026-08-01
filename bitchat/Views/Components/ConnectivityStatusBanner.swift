//
// ConnectivityStatusBanner.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CoreBluetooth
import SwiftUI

/// The degraded state a banner should surface, in priority order. Bluetooth
/// outranks tor: without the radio the app's core promise (mesh) is dead,
/// while a tor stall only pauses internet features.
enum ConnectivityIssue: Equatable {
    case bluetoothOff
    case bluetoothDenied
    case bluetoothUnsupported
    case torBlocked

    /// Pure resolution so the banner's priority logic is testable without a
    /// view. `.unknown`/`.resetting` deliberately resolve to nil — the radio
    /// is still starting and a flash of "bluetooth is off" at launch would
    /// be the same false signal this banner exists to prevent.
    static func resolve(bluetoothState: CBManagerState, torBlocked: Bool) -> ConnectivityIssue? {
        switch bluetoothState {
        case .poweredOff: return .bluetoothOff
        case .unauthorized: return .bluetoothDenied
        case .unsupported: return .bluetoothUnsupported
        case .poweredOn, .unknown, .resetting: break
        @unknown default: break
        }
        return torBlocked ? .torBlocked : nil
    }
}

/// Persistent one-line banner under the header while connectivity is
/// degraded. The Bluetooth alert is a one-shot modal — once dismissed, the
/// app used to look completely normal (empty timeline, radar sweeping)
/// while the radio was off. Tor stalls were only ever announced inside
/// geohash timelines. This banner is the always-visible truth; it renders
/// nothing when everything is fine.
struct ConnectivityStatusBanner: View {
    let issue: ConnectivityIssue
    @ThemedPalette private var palette

    private var message: String {
        switch issue {
        case .bluetoothOff:
            return String(
                localized: "content.banner.bluetooth_off",
                defaultValue: "bluetooth is off — nobody nearby can reach you. tap to fix.",
                comment: "Persistent banner while Bluetooth is switched off; tapping opens system settings"
            )
        case .bluetoothDenied:
            return String(
                localized: "content.banner.bluetooth_denied",
                defaultValue: "bluetooth access denied — mesh is offline. tap to open settings.",
                comment: "Persistent banner while Bluetooth permission is denied; tapping opens system settings"
            )
        case .bluetoothUnsupported:
            return String(
                localized: "content.banner.bluetooth_unsupported",
                defaultValue: "no bluetooth on this device — mesh is unavailable. location channels still work over the internet.",
                comment: "Persistent banner on devices without Bluetooth support"
            )
        case .torBlocked:
            return String(
                localized: "content.banner.tor_blocked",
                defaultValue: "tor can't connect — internet features are paused. mesh still works.",
                comment: "Persistent banner while Tor bootstrap has stalled, likely because the network blocks it"
            )
        }
    }

    /// Bluetooth problems deep-link to settings; the tor stall has no
    /// in-app remedy (the network is blocking it), so that banner is inert.
    private var opensSettings: Bool {
        switch issue {
        case .bluetoothOff, .bluetoothDenied: return true
        case .bluetoothUnsupported, .torBlocked: return false
        }
    }

    var body: some View {
        Group {
            if opensSettings {
                Button(action: { SystemSettings.bluetooth.open() }) {
                    label
                }
                .buttonStyle(.plain)
            } else {
                label
            }
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: issue == .torBlocked ? "network.slash" : "antenna.radiowaves.left.and.right.slash")
                .bitchatFont(size: 11, weight: .semibold)
            Text(message)
                .bitchatFont(size: 11)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(palette.alertRed)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}
