import XCTest
@testable import Tor
@testable import bitchat

@MainActor
final class TorTransportSettingsTests: XCTestCase {
    private let fingerprint = "8838024498816A039FCBBAB14E6F40A0843051FA"

    func test_defaultsToDirectAndPersistsOnlyNormalizedBridgesInKeychain() throws {
        let suite = "TorTransportSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let keychain = PreviewKeychainManager()
        let input = """
        # BridgeDB response
        obfs4 192.0.2.10:443 \(fingerprint) cert=YWJjZA iat-mode=0
        Bridge obfs4 192.0.2.10:443 \(fingerprint) cert=YWJjZA iat-mode=0
        """

        let settings = TorTransportSettings(
            defaults: defaults,
            keychain: keychain,
            notificationCenter: NotificationCenter()
        )
        XCTAssertEqual(settings.mode, .direct)
        XCTAssertEqual(settings.saveObfs4BridgeInput(input), .success(1))
        XCTAssertEqual(settings.obfs4BridgeLines.count, 1)
        XCTAssertTrue(settings.obfs4BridgeLines[0].hasPrefix("Bridge obfs4 "))
        XCTAssertNil(defaults.data(forKey: "obfs4-lines-v1"))

        let reloaded = TorTransportSettings(
            defaults: defaults,
            keychain: keychain,
            notificationCenter: NotificationCenter()
        )
        XCTAssertEqual(reloaded.obfs4BridgeLines, settings.obfs4BridgeLines)
    }

    func test_rejectsMalformedAndOversizedInputWithoutReplacingStoredBridges() throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "TorTransportSettingsTests-\(UUID().uuidString)")
        )
        let keychain = PreviewKeychainManager()
        let settings = TorTransportSettings(
            defaults: defaults,
            keychain: keychain,
            notificationCenter: NotificationCenter()
        )
        let valid = "obfs4 192.0.2.10:443 \(fingerprint) cert=YWJjZA iat-mode=1"
        XCTAssertEqual(settings.saveObfs4BridgeInput(valid), .success(1))
        let original = settings.obfs4BridgeLines

        XCTAssertEqual(
            settings.saveObfs4BridgeInput("snowflake 192.0.2.3:80 \(fingerprint)"),
            .failure(.malformedLine(1))
        )
        XCTAssertEqual(
            settings.saveObfs4BridgeInput(String(repeating: "x", count: 16 * 1024 + 1)),
            .failure(.inputTooLarge)
        )
        XCTAssertEqual(settings.obfs4BridgeLines, original)
    }

    func test_panicResetClearsModeStickySuccessAndBridgeMaterial() throws {
        let suite = "TorTransportSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let keychain = PreviewKeychainManager()
        let settings = TorTransportSettings(
            defaults: defaults,
            keychain: keychain,
            notificationCenter: NotificationCenter()
        )
        let valid = "obfs4 192.0.2.10:443 \(fingerprint) cert=YWJjZA iat-mode=0"
        XCTAssertEqual(settings.saveObfs4BridgeInput(valid), .success(1))
        settings.setMode(.auto)
        defaults.set(
            TorTransport.snowflake.rawValue,
            forKey: TorTransportStorageKeys.lastSuccessfulTransport
        )

        settings.resetForPanic()

        XCTAssertEqual(settings.mode, .direct)
        XCTAssertTrue(settings.obfs4BridgeLines.isEmpty)
        XCTAssertNil(defaults.object(forKey: TorTransportStorageKeys.mode))
        XCTAssertNil(
            defaults.object(forKey: TorTransportStorageKeys.lastSuccessfulTransport)
        )
        XCTAssertNil(
            keychain.load(
                key: "obfs4-lines-v1",
                service: TorTransportSettings.keychainService
            )
        )
    }

    func test_autoPlannerUsesLastSuccessfulAvailableTransportFirst() {
        let withBridges = TorRouteConfiguration(
            mode: .auto,
            obfs4BridgeLines: ["Bridge obfs4 example"],
            lastSuccessfulTransport: .snowflake
        )
        XCTAssertEqual(
            TorRoutePlanner.candidates(for: withBridges),
            [.snowflake, .direct, .obfs4]
        )

        let withoutBridges = TorRouteConfiguration(
            mode: .auto,
            obfs4BridgeLines: [],
            lastSuccessfulTransport: .obfs4
        )
        XCTAssertEqual(
            TorRoutePlanner.candidates(for: withoutBridges),
            [.direct, .snowflake]
        )
    }

    func test_snowflakeDefaultsMatchPinnedRecommendedTorrc() {
        XCTAssertEqual(SnowflakeDefaults.maxPeers, 1)
        XCTAssertEqual(SnowflakeDefaults.bridgeLines.count, 2)
        XCTAssertEqual(
            SnowflakeDefaults.bridgeLines.filter { $0.contains("cdn77.org") }.count,
            2
        )
        XCTAssertTrue(
            SnowflakeDefaults.bridgeLines.allSatisfy {
                $0.hasPrefix("Bridge snowflake ")
                    && $0.contains(" fingerprint=")
                    && $0.contains(" ice=")
                    && !$0.contains("ampcache=")
                    && !$0.contains("netlify.app")
                    && !$0.contains("sqscreds=")
            }
        )
    }

    func test_foregroundRecoveryContinuesAnExistingArtiAttempt() {
        XCTAssertEqual(
            TorLifecyclePolicy.foregroundRecoveryAction(
                autoStartAllowed: true,
                isForeground: true,
                isReady: false,
                isRestarting: false,
                shutdownInFlight: false,
                artiIsRunning: true
            ),
            .continueCurrentAttempt
        )
    }

    func test_foregroundRecoveryRestartsOnlyWhenArtiIsNotRunning() {
        XCTAssertEqual(
            TorLifecyclePolicy.foregroundRecoveryAction(
                autoStartAllowed: true,
                isForeground: true,
                isReady: false,
                isRestarting: false,
                shutdownInFlight: false,
                artiIsRunning: false
            ),
            .restart
        )
    }

    func test_foregroundRecoveryDefersWhileShutdownOwnsTheBoundary() {
        XCTAssertEqual(
            TorLifecyclePolicy.foregroundRecoveryAction(
                autoStartAllowed: true,
                isForeground: true,
                isReady: false,
                isRestarting: false,
                shutdownInFlight: true,
                artiIsRunning: false
            ),
            .deferUntilShutdownCompletes
        )
    }

    func test_foregroundRecoveryDoesNothingWhenReadyOrBackgrounded() {
        XCTAssertEqual(
            TorLifecyclePolicy.foregroundRecoveryAction(
                autoStartAllowed: true,
                isForeground: true,
                isReady: true,
                isRestarting: false,
                shutdownInFlight: false,
                artiIsRunning: true
            ),
            .none
        )
        XCTAssertEqual(
            TorLifecyclePolicy.foregroundRecoveryAction(
                autoStartAllowed: true,
                isForeground: false,
                isReady: false,
                isRestarting: false,
                shutdownInFlight: false,
                artiIsRunning: true
            ),
            .none
        )
    }

    // MARK: - Pluggable transport event aggregation

    private func outcome(
        _ event: PluggableTransportEvent,
        active: TorTransport? = .snowflake,
        isStarting: Bool = true,
        isReady: Bool = false,
        hasConnectedProxy: Bool = false,
        artiIsRunning: Bool = true
    ) -> TorTransportEventOutcome {
        TorTransportEventPolicy.outcome(
            for: event,
            activeTransport: active,
            isStarting: isStarting,
            isReady: isReady,
            hasConnectedProxy: hasConnectedProxy,
            artiIsRunning: artiIsRunning
        )
    }

    func test_snowflakeSiblingFailureCannotRegressAConnectedProxy() {
        XCTAssertEqual(outcome(.connected(.snowflake)), .proxyConnected)
        XCTAssertEqual(
            outcome(.recoverableFailure(.snowflake), hasConnectedProxy: true),
            .ignore
        )
    }

    func test_snowflakeFailureBeforeAnyConnectionReportsRetrying() {
        XCTAssertEqual(
            outcome(.recoverableFailure(.snowflake), hasConnectedProxy: false),
            .proxyRetrying
        )
    }

    func test_eventsForAnInactiveRouteAreIgnored() {
        XCTAssertEqual(outcome(.connected(.obfs4), active: .snowflake), .ignore)
        XCTAssertEqual(outcome(.connected(.snowflake), active: nil), .ignore)
    }

    func test_eventsOutsideAStartOrReadyAttemptAreIgnored() {
        XCTAssertEqual(
            outcome(.connected(.snowflake), isStarting: false, isReady: false),
            .ignore
        )
        // Ready is a live route, but a connect event no longer changes it.
        XCTAssertEqual(
            outcome(.connected(.snowflake), isStarting: false, isReady: true),
            .ignore
        )
    }

    func test_stopIsDeferredToArtiWhileArtiOwnsTheRoute() {
        XCTAssertEqual(
            outcome(.stopped(.snowflake), artiIsRunning: true),
            .ignoreStopWhileArtiOwnsRoute
        )
        XCTAssertEqual(
            outcome(.stopped(.snowflake), artiIsRunning: false),
            .routeStopped
        )
    }

    func test_stopFailsTheRouteEvenAfterAProxyConnected() {
        XCTAssertEqual(
            outcome(
                .stopped(.snowflake),
                hasConnectedProxy: true,
                artiIsRunning: false
            ),
            .routeStopped
        )
    }

    // MARK: - Bootstrap wait policy

    private func waitOutcome(
        progress: Int,
        highWaterProgress: Int = -1,
        secondsSinceProgress: Int = 0,
        remainingSeconds: Int = 100,
        stallWindow: Int = 45
    ) -> TorBootstrapWaitOutcome {
        TorBootstrapWaitPolicy.outcome(
            progress: progress,
            highWaterProgress: highWaterProgress,
            secondsSinceProgress: secondsSinceProgress,
            remainingSeconds: remainingSeconds,
            stallWindow: stallWindow
        )
    }

    /// The defect this policy exists to fix: a Snowflake bootstrap that was
    /// still climbing got killed at a fixed deadline and reported as blocked.
    func test_aBootstrapStillAdvancingKeepsWaitingPastTheStallWindow() {
        XCTAssertEqual(
            waitOutcome(progress: 62, highWaterProgress: 40, secondsSinceProgress: 90),
            .keepWaiting
        )
    }

    func test_progressStandingStillForTheWholeWindowIsAStall() {
        XCTAssertEqual(
            waitOutcome(progress: 40, highWaterProgress: 40, secondsSinceProgress: 45),
            .stalled
        )
        XCTAssertEqual(
            waitOutcome(progress: 40, highWaterProgress: 40, secondsSinceProgress: 44),
            .keepWaiting
        )
    }

    /// A bootstrap that never reports any progress must still fail, otherwise
    /// a route that is genuinely blocked would wait out the whole ceiling.
    func test_aBootstrapThatNeverAdvancesStallsAtTheWindow() {
        XCTAssertEqual(
            waitOutcome(progress: 0, highWaterProgress: 0, secondsSinceProgress: 45),
            .stalled
        )
    }

    func test_runningOutOfTimeWhileAdvancingIsNotReportedAsAStall() {
        XCTAssertEqual(
            waitOutcome(
                progress: 62,
                highWaterProgress: 62,
                secondsSinceProgress: 10,
                remainingSeconds: 0
            ),
            .ceilingReached
        )
    }

    /// A bridged route downloads the whole directory on every cold start and
    /// plateaus while circuits retry, so its window has to exceed the direct
    /// one or healthy attempts get reported as a blocked network.
    func test_slowerTransportsGetLongerStallWindowsAndCeilings() {
        XCTAssertLessThan(
            TorTransport.direct.bootstrapStallWindow,
            TorTransport.obfs4.bootstrapStallWindow
        )
        XCTAssertLessThan(
            TorTransport.obfs4.bootstrapStallWindow,
            TorTransport.snowflake.bootstrapStallWindow
        )
        for transport in [TorTransport.direct, .obfs4, .snowflake] {
            XCTAssertLessThan(
                TimeInterval(transport.bootstrapStallWindow),
                transport.bootstrapDeadline,
                "\(transport) can never reach its stall window before its ceiling"
            )
        }
    }

    func test_completionWinsOverEveryOtherOutcome() {
        XCTAssertEqual(
            waitOutcome(
                progress: 100,
                highWaterProgress: 100,
                secondsSinceProgress: 999,
                remainingSeconds: 0
            ),
            .ready
        )
    }
}
