import XCTest
@testable import Tor
@testable import bitchat

/// Covers the seeding that lets a pluggable transport start from a directory
/// direct Tor already downloaded.
///
/// The behaviour is worth pinning down because getting it backwards is silent
/// and harmful in two different directions: seeding direct from a bridged route
/// would move bridge-derived descriptors into the route that has no bridges,
/// and overwriting a route's existing directory would throw away progress that
/// is further along than the copy.
///
/// These cases mutate the state directories `TorManager.shared` owns, which are
/// process-wide.
@MainActor
final class TorManagerDirectoryCacheTests: XCTestCase {

    private let manager = TorManager.shared

    override func tearDownWithError() throws {
        if let root = manager.dataDirectoryURL(for: .direct) {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Seeds the marker file the tests use to tell one directory from another.
    @discardableResult
    private func writeCache(at directory: URL, marker: String) throws -> URL {
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appendingPathComponent("dir.sqlite3")
        try Data(marker.utf8).write(to: file)
        return file
    }

    private func marker(at directory: URL) -> String? {
        let file = directory
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("dir.sqlite3")
        guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func test_bridgedRouteWithNoDirectoryIsSeededFromDirect() throws {
        let direct = try XCTUnwrap(manager.dataDirectoryURL(for: .direct))
        let snowflake = try XCTUnwrap(manager.dataDirectoryURL(for: .snowflake))
        try writeCache(at: direct, marker: "direct")

        manager.seedDirectoryCacheIfNeeded(for: .snowflake, into: snowflake)

        XCTAssertEqual(
            marker(at: snowflake),
            "direct",
            "a bridged route starting cold was left to fetch its own directory"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: snowflake.appendingPathComponent("cache.seeding").path
            ),
            "seeding left its staging directory behind"
        )
    }

    /// The copy only ever runs towards a bridged route. Direct has no bridges,
    /// and descriptors fetched through one do not belong in its directory.
    func test_directRouteIsNeverSeeded() throws {
        let direct = try XCTUnwrap(manager.dataDirectoryURL(for: .direct))
        let snowflake = try XCTUnwrap(manager.dataDirectoryURL(for: .snowflake))
        try writeCache(at: snowflake, marker: "snowflake")

        manager.seedDirectoryCacheIfNeeded(for: .direct, into: direct)

        XCTAssertNil(
            marker(at: direct),
            "bridge-derived directory material reached the plain Tor route"
        )
    }

    /// A route that has got further than direct keeps what it has.
    func test_existingDirectoryIsNotOverwritten() throws {
        let direct = try XCTUnwrap(manager.dataDirectoryURL(for: .direct))
        let obfs4 = try XCTUnwrap(manager.dataDirectoryURL(for: .obfs4))
        try writeCache(at: direct, marker: "direct")
        try writeCache(at: obfs4, marker: "obfs4")

        manager.seedDirectoryCacheIfNeeded(for: .obfs4, into: obfs4)

        XCTAssertEqual(
            marker(at: obfs4),
            "obfs4",
            "seeding overwrote a directory the route had already built"
        )
    }

    /// Nothing to copy is the state a first run is in, and it has to stay
    /// non-fatal: Arti downloads its own directory from there.
    func test_missingSourceLeavesTheRouteAlone() throws {
        let direct = try XCTUnwrap(manager.dataDirectoryURL(for: .direct))
        let snowflake = try XCTUnwrap(manager.dataDirectoryURL(for: .snowflake))
        try? FileManager.default.removeItem(at: direct)

        manager.seedDirectoryCacheIfNeeded(for: .snowflake, into: snowflake)

        XCTAssertNil(marker(at: snowflake))
    }
}
