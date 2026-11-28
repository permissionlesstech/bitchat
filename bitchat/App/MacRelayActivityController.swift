//
// MacRelayActivityController.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(macOS)

import Combine
import CoreBluetooth
import Foundation
import Tor

/// Drives `RelayActivityAssertion` from the live transports, so the App Nap
/// exemption is held exactly while Tor or the BLE mesh is relaying (#1593).
@MainActor
final class MacRelayActivityController {
    private let assertion: RelayActivityAssertion
    private let appNapMonitor = MacAppNapRiskMonitor()
    private var cancellables = Set<AnyCancellable>()

    // Default arguments are evaluated in a nonisolated context, so neither the
    // assertion nor the `.shared` singletons can be defaulted in a signature —
    // they are main-actor isolated. Both are resolved in-body instead.
    init() {
        assertion = RelayActivityAssertion()
    }

    /// Observes the live transports. Called once the runtime exists.
    func observe(chatViewModel: ChatViewModel) {
        let activation = NetworkActivationService.shared
        let tor = TorManager.shared
        cancellables.removeAll()
        appNapMonitor.start()

        appNapMonitor.$appNapWouldApply
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] wouldApply in
                self?.assertion.update { $0.appNapWouldApply = wouldApply }
            }
            .store(in: &cancellables)

        // Tor "on" per user preference *and* activation policy — this covers
        // the bootstrap window, before `isReady` flips.
        Publishers.CombineLatest(activation.$activationAllowed, activation.$userTorEnabled)
            .map { $0 && $1 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] torDesired in
                self?.assertion.update { $0.torDesired = torDesired }
            }
            .store(in: &cancellables)

        tor.$isReady
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                self?.assertion.update { $0.torReady = ready }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(activation.$activationAllowed, chatViewModel.$bluetoothState)
            .map { allowed, state in
                RelayActivityAssertion.isBLERelayActive(
                    bluetoothPoweredOn: state == .poweredOn,
                    activationAllowed: allowed
                )
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bleRelayActive in
                self?.assertion.update { $0.bleRelayActive = bleRelayActive }
            }
            .store(in: &cancellables)
    }

    /// Drops the transport subscriptions and releases the assertion.
    func stop() {
        cancellables.removeAll()
        appNapMonitor.stop()
        assertion.release()
    }
}

#endif
