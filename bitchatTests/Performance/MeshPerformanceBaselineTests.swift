//
// MeshPerformanceBaselineTests.swift
// bitchatTests
//
// One phone joining an established 64-node dense mesh (8×8 grid, king-move
// links), over real BLEService engines in SimulatedMesh: link-up
// announces, the announces they earn, mesh-wide relays with signature
// verification and registry/topology work at every node, Noise handshakes
// with both neighbours, initial sync, and settling.
//
// It guards announce storms. Every announce costs every node a
// deduplication, an Ed25519 verification and a relay decision, so per-join
// cost tracks how many announces a join triggers. When every node answered
// every newcomer, a join triggered over a thousand announce originations
// here and ran at well under one join per second in a debug build;
// perf-floors.json keeps the floor several times above that.
//
// Not @MainActor, and async: the engines hop UI events to the main actor,
// which must keep draining while the benchmark blocks its own thread —
// otherwise a storm queues hundreds of thousands of main-actor tasks and
// the benchmark measures memory pressure instead.
//

import XCTest
@testable import bitchat

final class MeshPerformanceBaselineTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BITCHAT_SKIP_PERF_BASELINES"] == "1",
            "Performance baselines skipped via BITCHAT_SKIP_PERF_BASELINES"
        )
    }

    func testMeshJoinAnnounceExchange() async throws {
        let width = 8
        let mesh = SimulatedMesh.grid(width: width, height: width, kingMoves: true)
        var samples: [TimeInterval] = []

        for pass in 0..<10 {
            // A storm makes each join take seconds; a few passes are enough
            // to fail the floor without stretching the CI step.
            if samples.count >= 3, samples.reduce(0, +) > 10 { break }
            let joiner = mesh.launch(nickname: "joiner\(pass)")
            // A different spot of the mesh each pass: two nodes side by side
            // in one row, as one phone can reach.
            let column = pass % (width - 1)
            let row = (pass * 3) % width
            let anchors = [row * width + column, row * width + column + 1]
            let start = Date()
            mesh.join(joiner, linkingTo: anchors)
            samples.append(Date().timeIntervalSince(start))
            XCTAssertTrue(mesh.knows(anchors[0], joiner))
        }

        PerformanceBaselineTests.reportThroughputLine(
            "mesh.joinAnnounce",
            samples: samples,
            operations: 1,
            unit: "joins"
        )
    }
}
