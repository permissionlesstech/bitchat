//
// NostrTransportTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

@Suite("NostrTransport Thread Safety Tests")
struct NostrTransportTests {

    @Test("Concurrent read receipt enqueue does not crash")
    @MainActor
    func concurrentReadReceiptEnqueue() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let transport = NostrTransport(keychain: keychain, idBridge: idBridge)

        // Create 100 concurrent read receipt submissions
        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let receipt = ReadReceipt(
                        originalMessageID: UUID().uuidString,
                        readerID: PeerID(str: String(format: "%016x", i)),
                        readerNickname: "Reader\(i)"
                    )
                    let peerID = PeerID(str: String(format: "%016x", i))
                    transport.sendReadReceipt(receipt, to: peerID)
                }
            }
        }

        // If we reach here without crashing, the test passes
        // The concurrent enqueue operations completed without data races
    }

    @Test("Read queue processes under concurrent load")
    @MainActor
    func readQueueProcessingUnderLoad() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let transport = NostrTransport(keychain: keychain, idBridge: idBridge)

        // Rapidly enqueue many receipts from multiple concurrent sources
        let iterations = 50

        // First batch - rapid fire
        for i in 0..<iterations {
            let receipt = ReadReceipt(
                originalMessageID: UUID().uuidString,
                readerID: PeerID(str: String(format: "%016x", i)),
                readerNickname: "Reader\(i)"
            )
            transport.sendReadReceipt(receipt, to: PeerID(str: String(format: "%016x", i)))
        }

        // Give some time for processing to start
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Second batch - while first might be processing
        await withTaskGroup(of: Void.self) { group in
            for i in iterations..<(iterations * 2) {
                group.addTask {
                    let receipt = ReadReceipt(
                        originalMessageID: UUID().uuidString,
                        readerID: PeerID(str: String(format: "%016x", i)),
                        readerNickname: "Reader\(i)"
                    )
                    transport.sendReadReceipt(receipt, to: PeerID(str: String(format: "%016x", i)))
                }
            }
        }

        // If we reach here without crashing or deadlocking, test passes
    }

    @Test("isPeerReachable is thread safe")
    @MainActor
    func isPeerReachableThreadSafety() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let transport = NostrTransport(keychain: keychain, idBridge: idBridge)

        let iterations = 100

        // Concurrent reads on isPeerReachable
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let peerID = PeerID(str: String(format: "%016x", i))
                    return transport.isPeerReachable(peerID)
                }
            }

            // Collect results (all should be false since no favorites configured)
            for await result in group {
                #expect(result == false)
            }
        }
    }
}
