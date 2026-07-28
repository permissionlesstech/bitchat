import XCTest
@testable import Tor
@testable import bitchat

/// Drives the real `TorManager` panic path rather than a mock.
///
/// `NetworkActivationServiceTests` proves the panic boundary *calls*
/// `resetTransportForPanic()`, but it does so against
/// `MockNetworkActivationTorController`, so nothing there covers what the call
/// actually removes. The security claim of a panic wipe is that private obfs4
/// bridges and guard state are not recoverable from disk afterwards, and that
/// claim lives entirely in this method.
///
/// These cases mutate `TorManager.shared` and the state directories it owns,
/// both of which are process-wide.
@MainActor
final class TorManagerPanicTests: XCTestCase {

    func test_resetTransportForPanic_removesCachedBridgeAndGuardStateFromDisk() throws {
        let manager = TorManager.shared
        let artiDirectory = try XCTUnwrap(manager.dataDirectoryURL())
        let bridgedDirectory = try XCTUnwrap(manager.dataDirectoryURL(for: .obfs4))
        let transportStateDirectory = try XCTUnwrap(manager.pluggableTransportStateDirectoryURL())

        // A bridged route caches descriptors keyed by the bridge line that
        // produced them, so the per-transport subdirectory is the one holding
        // recoverable bridge material. Direct Tor's guard state sits in the
        // parent and is its own linkable record of this device.
        let seeded = [
            artiDirectory.appendingPathComponent("dir.sqlite3"),
            bridgedDirectory.appendingPathComponent("bridge-descriptor-cache"),
            transportStateDirectory.appendingPathComponent("obfs4_bridgeline.txt")
        ]
        for file in seeded {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("recoverable".utf8).write(to: file)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }

        manager.resetTransportForPanic()

        for file in seeded {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: file.path),
                "panic left \(file.lastPathComponent) recoverable on disk"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: artiDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transportStateDirectory.path))
    }

    func test_resetTransportForPanic_clearsPublishedRouteEvenWhenArtiWasNeverStarted() {
        let manager = TorManager.shared
        manager.configureTransport(
            TorRouteConfiguration(
                mode: .auto,
                obfs4BridgeLines: [
                    "obfs4 192.0.2.10:443 8838024498816A039FCBBAB14E6F40A0843051FA cert=YWJjZA iat-mode=0"
                ],
                lastSuccessfulTransport: .snowflake
            )
        )

        // The panic boundary is synchronous and unconditional, so it also runs
        // on a cold app. `arti_stop()` reports -1 there rather than failing,
        // and the wipe still has to complete.
        let started = Date()
        manager.resetTransportForPanic()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(manager.transportStatus, .idle)
        // The wipe waits for Arti to finish stopping before unlinking its
        // files. With no Arti running there is nothing to wait for, and the
        // panic button must not stall on the main actor for the full budget.
        XCTAssertLessThan(elapsed, 1.0)
    }
}
