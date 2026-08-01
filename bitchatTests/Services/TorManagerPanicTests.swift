import XCTest
@testable import Tor
@testable import bitchat

/// Mirrors the declaration in `TorManager`, which keeps its FFI surface file
/// private. `waitForArtiToStop()` decides whether to sleep at all from this
/// symbol and nothing else, so reading it is how the cold-app case checks that
/// the panic path does not block without timing the call.
@_silgen_name("arti_is_running")
private func arti_is_running() -> Int32

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
/// both of which are process-wide. The wipe below deletes the whole tree
/// `TorManagerDirectoryCacheTests` writes into, so both classes run under
/// `TorStateDirectoryLock`.
@MainActor
final class TorManagerPanicTests: XCTestCase {

    private var stateDirectoryLock: TorStateDirectoryLock.Token?

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateDirectoryLock = try TorStateDirectoryLock.acquire()
    }

    override func tearDownWithError() throws {
        stateDirectoryLock?.release()
        stateDirectoryLock = nil
        try super.tearDownWithError()
    }

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
        //
        // The wipe waits for Arti to finish stopping before unlinking its
        // files, and the panic button must not stall on the main actor for
        // that budget when there is nothing to wait for. `waitForArtiToStop()`
        // returns on its guard without sleeping once, and this is the guard's
        // only input, so establishing it is what makes the wait a no-op. The
        // check is on that input rather than on elapsed wall-clock time: a
        // loaded runner can exceed any elapsed bound with the behaviour
        // entirely correct, which is the flake class `TestTimingHygieneTests`
        // exists to keep out of this suite.
        XCTAssertEqual(
            arti_is_running(),
            0,
            "this case covers a cold app, so there must be no runtime to wait on"
        )

        manager.resetTransportForPanic()

        XCTAssertEqual(manager.transportStatus, .idle)
        XCTAssertEqual(
            arti_is_running(),
            0,
            "the wipe must not have left a runtime behind for the next attempt"
        )
    }
}
