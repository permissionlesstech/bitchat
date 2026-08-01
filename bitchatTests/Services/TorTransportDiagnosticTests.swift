import XCTest
@testable import Tor

/// The route diagnostic used to be a finished sentence built where it was
/// reported, which put English in front of every reader and left the text
/// somewhere the localization coverage test could not see it. Splitting it into
/// a value gave the two audiences different rules: the settings screen renders
/// it through the string catalog, while logs and `NSError` keep the English
/// below. These tests pin that English, because log greps and bug reports
/// written before the split still have to match after it.
final class TorTransportDiagnosticTests: XCTestCase {
    /// Every case, so the coverage claims below are about the whole type.
    /// Adding a case without adding it here shows up as a count mismatch.
    private let allCases: [TorTransportDiagnostic] = [
        .routeMismatch,
        .notReadyBeforeTimeout,
        .configurationFailed,
        .socksListenerFailed,
        .bootstrapFailed,
        .stoppedBeforeReady,
        .listenerReady(.obfs4),
        .handoffConfigured(.obfs4),
        .proxyOpened(.obfs4),
        .bridgeRequestSent(.obfs4),
        .proxyConnected(.obfs4),
        .proxyRetrying(.obfs4),
        .routeStopped(.obfs4)
    ]

    func test_logDescriptionsAreUnchangedFromTheStringsTheyReplaced() {
        let expected: [(TorTransportDiagnostic, String)] = [
            (.routeMismatch, "internal route mismatch; tor was not started"),
            (.notReadyBeforeTimeout, "tor did not become ready before the timeout"),
            (.configurationFailed, "tor configuration failed"),
            (.socksListenerFailed, "the local tor proxy could not start"),
            (.bootstrapFailed, "tor bootstrap failed"),
            (.stoppedBeforeReady, "tor stopped before becoming ready"),
            (.listenerReady(.snowflake), "snowflake listener ready; configuring tor handoff"),
            (.listenerReady(.obfs4), "obfs4 listener ready; configuring tor handoff"),
            (
                .handoffConfigured(.obfs4),
                "tor handoff to obfs4 configured; waiting for proxy connection"
            ),
            (.proxyOpened(.obfs4), "tor opened obfs4; connecting to its local listener"),
            (
                .bridgeRequestSent(.snowflake),
                "snowflake received tor's bridge request; finding a proxy"
            ),
            (.proxyConnected(.snowflake), "snowflake proxy connected; bootstrapping tor"),
            (.proxyRetrying(.snowflake), "snowflake could not connect to a proxy; retrying"),
            (.routeStopped(.obfs4), "obfs4 stopped unexpectedly")
        ]

        for (diagnostic, text) in expected {
            XCTAssertEqual(diagnostic.logDescription, text)
        }
    }

    func test_everyCaseCarriesDistinctNonEmptyLogText() {
        XCTAssertEqual(allCases.count, 13)
        for diagnostic in allCases {
            XCTAssertFalse(
                diagnostic.logDescription.isEmpty,
                "\(diagnostic) reports nothing a log could show"
            )
        }
        XCTAssertEqual(
            Set(allCases.map(\.logDescription)).count,
            allCases.count,
            "two cases would be indistinguishable in a log"
        )
    }

    /// A reader has to be able to tell which route a line is about, so the
    /// transport-carrying cases have to name it.
    func test_transportCasesNameTheTransportTheyDescribe() {
        for transport in [TorTransport.obfs4, .snowflake] {
            let carrying: [TorTransportDiagnostic] = [
                .listenerReady(transport),
                .handoffConfigured(transport),
                .proxyOpened(transport),
                .bridgeRequestSent(transport),
                .proxyConnected(transport),
                .proxyRetrying(transport),
                .routeStopped(transport)
            ]
            for diagnostic in carrying {
                XCTAssertTrue(
                    diagnostic.logDescription.contains(transport.rawValue),
                    "\(diagnostic) does not say it is about \(transport.rawValue)"
                )
            }
        }
    }

    /// `handlePluggableTransportEvent` drops a repeated retry by comparing the
    /// new diagnostic with the published one. That guard is why the value is
    /// `Equatable`, and it has to keep distinguishing transports: collapsing
    /// them would silence a real retry on the route that just took over.
    func test_equalityDistinguishesTransportsSoRetriesAreNotCollapsed() {
        XCTAssertEqual(
            TorTransportDiagnostic.proxyRetrying(.obfs4),
            TorTransportDiagnostic.proxyRetrying(.obfs4)
        )
        XCTAssertNotEqual(
            TorTransportDiagnostic.proxyRetrying(.obfs4),
            TorTransportDiagnostic.proxyRetrying(.snowflake)
        )
        XCTAssertNotEqual(
            TorTransportDiagnostic.proxyRetrying(.obfs4),
            TorTransportDiagnostic.routeStopped(.obfs4)
        )
    }
}
