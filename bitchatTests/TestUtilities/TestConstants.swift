//
// TestConstants.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
@testable import bitchat

struct TestConstants {
    static let defaultTimeout: TimeInterval = 5.0
    /// For positive waits on work that hops through `Task.detached` or
    /// background queues: those contend with every parallel test worker for
    /// the global executor, so a loaded CI runner can exceed
    /// `defaultTimeout`. `waitUntil` returns as soon as the condition holds,
    /// so passing runs never pay the longer timeout.
    static let longTimeout: TimeInterval = 10.0

    /// **Default deadline for any "wait until this async thing settles" helper.**
    ///
    /// Four separate tests flaked on CI during July 2026 with the same root
    /// cause, and it is worth stating the rule rather than re-learning it a
    /// fifth time: *a wait deadline is not a latency budget.* It exists so a
    /// genuine hang eventually fails the suite. Size it for the worst-case
    /// scheduler, never for how long the operation "should" take.
    ///
    /// A CI runner executes many suites at once. Work behind `@MainActor`,
    /// `Task.detached(priority: .utility)`, or a `DispatchQueue.asyncAfter` can
    /// be starved for seconds — one observed run took 3.75 s for a 1 s
    /// operation. Deadlines sized to the operation (the old 1 s defaults) turn
    /// that starvation into a red build that reads like a product bug.
    ///
    /// This costs nothing when tests pass, because every helper returns as soon
    /// as its condition holds. It only extends the genuine-failure case.
    ///
    /// `TestTimingHygieneTests` enforces that wait helpers default to at least
    /// `minimumSettleTimeout`.
    static let settleTimeout: TimeInterval = 30.0

    /// Floor enforced by `TestTimingHygieneTests`. Anything below this is a
    /// latency assumption in disguise.
    static let minimumSettleTimeout: TimeInterval = 10.0

    /// For waits whose **expected outcome is `false`** — "prove this does not
    /// happen".
    ///
    /// The floor above is wrong for these, and inverted: a negative wait always
    /// runs its deadline out, so `settleTimeout` would spend 30 s per case
    /// proving nothing extra. Starvation cannot cause a false failure here
    /// either — a starved runner only makes the thing *less* likely to happen,
    /// so the assertion still holds. Short is correct, and naming it says the
    /// polarity out loud instead of leaving a bare literal that reads like the
    /// mistake this file exists to prevent.
    ///
    /// `TestTimingHygieneTests` accepts this by name. Using it for a wait you
    /// expect to succeed reintroduces exactly the flake class it sits next to.
    static let negativeWaitWindow: TimeInterval = 1.0

    /// For an injected **production timer or time window** that must not
    /// elapse while a test is still stepping through the state it guards.
    ///
    /// A test drives a handshake as consecutive synchronous calls, and the
    /// product arms a teardown timer on the first of them. A starved runner
    /// can stall between any two calls for longer than any value sized to the
    /// work — 1 s was outrun, and so was the 20 s production default — so the
    /// timer wins, the half-open state is torn down, and the next call fails
    /// in a way that reads like a product bug. Raising the value only scales
    /// with the stall. Inject this instead, and where expiry is the behaviour
    /// under test, fire it through the product's DEBUG hook.
    ///
    /// Longer than any CI job is allowed to run, so no test run can outlive it.
    static let unlosableInterval: TimeInterval = 3600


    static let testNickname1 = "Alice"
    static let testNickname2 = "Bob"
    static let testNickname3 = "Charlie"
    static let testNickname4 = "David"
    
    static let testMessage1 = "Hello, World!"
    static let testLongMessage = String(repeating: "This is a long message. ", count: 100)
}
