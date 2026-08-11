//
// RelayActivityAssertion.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(macOS)

import Foundation

/// Abstracts `ProcessInfo`'s activity assertions so the gating policy can be
/// exercised without touching real power-management state.
protocol ProcessActivityAsserting: AnyObject {
    func beginActivity(reason: String) -> NSObjectProtocol
    func endActivity(_ token: NSObjectProtocol)
}

final class ProcessInfoActivityAsserter: ProcessActivityAsserting {
    func beginActivity(reason: String) -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: reason
        )
    }

    func endActivity(_ token: NSObjectProtocol) {
        ProcessInfo.processInfo.endActivity(token)
    }
}

/// Holds an App Nap exemption while a transport is actually relaying.
///
/// macOS throttles timers, networking and BLE callbacks for an app whose
/// windows are all minimized or fully occluded, which stalls Tor and the mesh
/// relay even though the process is still "running" (#1593). iOS has explicit
/// scene-phase dormancy handling; macOS had none.
///
/// The assertion is deliberately *not* held for the whole process lifetime: a
/// configuration with Tor switched off and Bluetooth unavailable is not
/// relaying anything, so an assertion there is pure battery cost.
///
/// Transport wiring lives in `MacRelayActivityController`; this type stays free
/// of Combine and AppKit so the policy and the begin/end bookkeeping are
/// directly testable.
@MainActor
final class RelayActivityAssertion {
    static let activityReason = "Relaying bitchat traffic over Tor and BLE mesh"

    /// Inputs that decide whether the process is doing relay work.
    struct TransportState: Equatable {
        /// Tor is switched on by the user and network activation policy allows
        /// it. Covers bootstrap, which needs CPU before `torReady` flips.
        var torDesired: Bool = false
        /// Tor has finished bootstrapping and is carrying traffic.
        var torReady: Bool = false
        /// The BLE mesh radio is powered on, so we can scan/advertise/relay.
        var bluetoothPoweredOn: Bool = false
    }

    /// Pure policy.
    ///
    /// `torDesired` is included alongside `torReady` on purpose: dropping the
    /// assertion mid-bootstrap is what would leave a minimized window stuck
    /// part-way through connecting.
    static func shouldHold(_ state: TransportState) -> Bool {
        state.torDesired || state.torReady || state.bluetoothPoweredOn
    }

    private let asserter: ProcessActivityAsserting
    private var token: NSObjectProtocol?
    private(set) var state = TransportState()

    /// Whether the App Nap exemption is currently held.
    var isHolding: Bool { token != nil }

    init(asserter: ProcessActivityAsserting = ProcessInfoActivityAsserter()) {
        self.asserter = asserter
    }

    /// Applies a state change, beginning or ending the assertion if the policy
    /// verdict flipped. Idempotent: repeated same-verdict updates never stack
    /// or double-release assertions.
    func apply(_ newState: TransportState) {
        state = newState
        let wanted = Self.shouldHold(state)
        if wanted, token == nil {
            token = asserter.beginActivity(reason: Self.activityReason)
        } else if !wanted, let held = token {
            asserter.endActivity(held)
            token = nil
        }
    }

    /// Mutates one field of the transport state, re-evaluating the policy.
    /// Used by the per-transport Combine sinks, which each know about one flag.
    func update(_ mutate: (inout TransportState) -> Void) {
        var next = state
        mutate(&next)
        guard next != state else { return }
        apply(next)
    }

    /// Releases the assertion regardless of transport state (app teardown).
    func release() {
        guard let held = token else { return }
        asserter.endActivity(held)
        token = nil
    }
}

#endif
