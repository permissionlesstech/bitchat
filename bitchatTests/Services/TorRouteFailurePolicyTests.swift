import XCTest
@testable import Tor

/// Covers what happens after a bootstrap attempt gives up.
///
/// `TorTransportSettingsTests` covers which routes an auto sequence contains;
/// this covers moving through it and what happens once it runs out. That is
/// where the feature earns its keep: a direct route failing on a censored
/// network is the expected case, and reaching obfs4 afterwards is the point.
final class TorRouteFailurePolicyTests: XCTestCase {

    private let autoSequence: [TorTransport] = [.direct, .obfs4, .snowflake]

    // MARK: - Advancing

    func test_autoMovesToTheNextRouteInTheSequence() {
        XCTAssertEqual(
            TorRouteFailurePolicy.outcome(
                mode: .auto,
                candidates: autoSequence,
                index: 0,
                priorConsecutiveFailures: 0
            ),
            .advance(from: .direct, to: .obfs4)
        )
    }

    /// A `.advance` carrying its routes the wrong way round would record the
    /// route about to be tried as already attempted and skip the one that
    /// failed, which reads as a working fallback in the status UI.
    func test_advanceNamesTheRouteThatFailedAndTheOneReplacingIt() {
        guard case .advance(let from, let to) = TorRouteFailurePolicy.outcome(
            mode: .auto,
            candidates: autoSequence,
            index: 1,
            priorConsecutiveFailures: 0
        ) else {
            return XCTFail("a mid-sequence failure must advance")
        }
        XCTAssertEqual(from, .obfs4)
        XCTAssertEqual(to, .snowflake)
    }

    /// Advancing is what carries a blocked route to a transport that works, and
    /// the outcome that does it has nowhere to put a delay. So the thing to
    /// hold is that a run of earlier failures cannot turn the sequence into the
    /// outcome that does wait.
    func test_priorFailuresDoNotStopTheSequenceAdvancing() {
        for failures in 0...10 {
            let outcome = TorRouteFailurePolicy.outcome(
                mode: .auto,
                candidates: autoSequence,
                index: 0,
                priorConsecutiveFailures: failures
            )
            guard case .advance = outcome else {
                return XCTFail("\(failures) prior failures ended the sequence early")
            }
        }
    }

    /// Walks a whole auto sequence the way `TorManager` does, one failure at a
    /// time, and asserts it reaches every route in order and stops once.
    func test_aFullAutoSequenceTriesEveryRouteExactlyOnceThenStops() {
        var index = 0
        var tried: [TorTransport] = []

        while true {
            let outcome = TorRouteFailurePolicy.outcome(
                mode: .auto,
                candidates: autoSequence,
                index: index,
                priorConsecutiveFailures: 0
            )
            switch outcome {
            case .advance(let from, _):
                tried.append(from)
                index += 1
            case .exhausted(let route, _):
                tried.append(route)
                XCTAssertEqual(tried, autoSequence, "the sequence skipped or repeated a route")
                XCTAssertEqual(route, .snowflake, "the sequence ended on the wrong route")
                return
            case .noRouteInFlight:
                return XCTFail("the sequence ran off its own candidate list")
            }
            guard tried.count <= autoSequence.count else {
                return XCTFail("the sequence never terminated")
            }
        }
    }

    // MARK: - Never overriding the user's choice

    /// The invariant the transport picker rests on: a mode the user chose is an
    /// instruction, not a preference. Answering a failed obfs4 route with a
    /// direct one would put an unprotected route on a network they picked
    /// bridges for.
    func test_anExplicitModeNeverMovesToAnotherTransport() {
        for mode in [TorTransportMode.direct, .obfs4, .snowflake] {
            // Deliberately given the full sequence rather than the single
            // candidate the planner would return: the guard has to be the mode,
            // not the length of the list it happens to be handed.
            let outcome = TorRouteFailurePolicy.outcome(
                mode: mode,
                candidates: autoSequence,
                index: 0,
                priorConsecutiveFailures: 0
            )
            guard case .exhausted(let route, _) = outcome else {
                return XCTFail("\(mode.rawValue) advanced to a route the user did not choose")
            }
            XCTAssertEqual(route, .direct)
        }
    }

    // MARK: - Backing off

    func test_theLastRouteInASequenceBacksOffInsteadOfAdvancing() {
        guard case .exhausted(let route, let delay) = TorRouteFailurePolicy.outcome(
            mode: .auto,
            candidates: autoSequence,
            index: autoSequence.count - 1,
            priorConsecutiveFailures: 0
        ) else {
            return XCTFail("the end of the sequence must not advance")
        }
        XCTAssertEqual(route, .snowflake)
        XCTAssertEqual(delay, TorRouteFailurePolicy.baseRetryDelay)
    }

    /// The failure being reported is not yet in the count the caller holds, so
    /// off-by-one here would let the first exhausted sequence retry instantly.
    func test_theFirstExhaustedSequenceAlreadyWaits() {
        guard case .exhausted(_, let delay) = TorRouteFailurePolicy.outcome(
            mode: .direct,
            candidates: [.direct],
            index: 0,
            priorConsecutiveFailures: 0
        ) else {
            return XCTFail("a single-route mode has nothing to advance to")
        }
        XCTAssertGreaterThan(delay, 0)
    }

    func test_theDelayDoublesWithEachConsecutiveFailure() {
        XCTAssertEqual(
            (1...5).map(TorRouteFailurePolicy.retryDelay(afterConsecutiveFailures:)),
            [5, 10, 20, 40, 80]
        )
    }

    func test_theDelayStopsDoublingAtTheCeiling() {
        XCTAssertEqual(
            TorRouteFailurePolicy.retryDelay(afterConsecutiveFailures: 6),
            TorRouteFailurePolicy.maximumRetryDelay
        )
        // An app left on a blocked network reaches counts no doubling curve was
        // written for, where `pow` saturates to infinity. The delay is added to
        // a `Date`, so anything that escaped the ceiling here would park the
        // next attempt past any point the user is still around for. `min`
        // already resolves infinity to the ceiling; this pins that it keeps
        // doing so, since a future rewrite is free to reach for the exponent.
        for failures in [7, 64, 1_000, Int.max] {
            XCTAssertEqual(
                TorRouteFailurePolicy.retryDelay(afterConsecutiveFailures: failures),
                TorRouteFailurePolicy.maximumRetryDelay,
                "\(failures) failures produced an unusable delay"
            )
        }
    }

    /// The counter is cleared on success, so the next failure asks about zero.
    func test_aRouteThatHasNotFailedIsNotDelayed() {
        XCTAssertEqual(TorRouteFailurePolicy.retryDelay(afterConsecutiveFailures: 0), 0)
    }

    // MARK: - Nothing in flight

    /// A stop callback can arrive after the sequence was already cleared. The
    /// index is then past the end of the list, and reading it would trap.
    func test_anIndexPastTheEndOfTheSequenceIsNotARouteFailure() {
        for (candidates, index) in [([TorTransport](), 0), ([.direct], 1), ([.direct, .obfs4], 9)] {
            XCTAssertEqual(
                TorRouteFailurePolicy.outcome(
                    mode: .auto,
                    candidates: candidates,
                    index: index,
                    priorConsecutiveFailures: 0
                ),
                .noRouteInFlight,
                "index \(index) of \(candidates.count) was treated as a live route"
            )
        }
    }

    /// Nothing failed, so nothing may be counted against the backoff. Reporting
    /// this as `.exhausted` would make the caller increment its counter and
    /// delay the *next* real route for a failure that never happened.
    func test_anEmptySequenceIsNotCountedAsAFailureEvenAfterEarlierOnes() {
        XCTAssertEqual(
            TorRouteFailurePolicy.outcome(
                mode: .auto,
                candidates: [],
                index: 0,
                priorConsecutiveFailures: 4
            ),
            .noRouteInFlight
        )
    }
}
