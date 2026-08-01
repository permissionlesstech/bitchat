//
// ConnectivityStatusTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CoreBluetooth
import Testing
@testable import bitchat

struct ConnectivityIssueTests {

    @Test("Bluetooth problems outrank a tor stall; healthy state shows nothing")
    func resolvePrioritizesBluetoothOverTor() {
        #expect(ConnectivityIssue.resolve(bluetoothState: .poweredOff, torBlocked: true) == .bluetoothOff)
        #expect(ConnectivityIssue.resolve(bluetoothState: .unauthorized, torBlocked: false) == .bluetoothDenied)
        #expect(ConnectivityIssue.resolve(bluetoothState: .unsupported, torBlocked: false) == .bluetoothUnsupported)
        #expect(ConnectivityIssue.resolve(bluetoothState: .poweredOn, torBlocked: true) == .torBlocked)
        #expect(ConnectivityIssue.resolve(bluetoothState: .poweredOn, torBlocked: false) == nil)
    }

    @Test("A starting radio must not flash a false 'bluetooth is off' banner")
    func resolveStaysQuietWhileRadioIsStarting() {
        #expect(ConnectivityIssue.resolve(bluetoothState: .unknown, torBlocked: false) == nil)
        #expect(ConnectivityIssue.resolve(bluetoothState: .resetting, torBlocked: false) == nil)
        // A tor stall still surfaces once known, even while the radio starts.
        #expect(ConnectivityIssue.resolve(bluetoothState: .unknown, torBlocked: true) == .torBlocked)
    }
}
