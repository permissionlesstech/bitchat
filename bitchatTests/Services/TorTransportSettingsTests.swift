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

    func test_panicRequiresAFreshTransportChoiceAndSurvivesRelaunch() throws {
        let suite = "TorTransportSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let keychain = PreviewKeychainManager()
        let settings = TorTransportSettings(
            defaults: defaults,
            keychain: keychain,
            notificationCenter: NotificationCenter()
        )
        XCTAssertFalse(settings.requiresTransportSelection)

        settings.resetForPanic()
        XCTAssertTrue(settings.requiresTransportSelection)

        // Relaunching must not undo a wipe, so the gate is persisted.
        let relaunched = TorTransportSettings(
            defaults: defaults,
            keychain: keychain,
            notificationCenter: NotificationCenter()
        )
        XCTAssertTrue(relaunched.requiresTransportSelection)

        // The wipe already left the mode at .direct, so re-picking direct is a
        // no-op on mode and must still count as the user's choice.
        relaunched.setMode(.direct)
        XCTAssertFalse(relaunched.requiresTransportSelection)
        XCTAssertFalse(
            defaults.bool(forKey: TorTransportStorageKeys.transportSelectionRequired)
        )
    }

    func test_clearingBridgesKeepsObfs4ModeAndPlansNothing() throws {
        let suite = "TorTransportSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = TorTransportSettings(
            defaults: defaults,
            keychain: PreviewKeychainManager(),
            notificationCenter: NotificationCenter()
        )
        XCTAssertEqual(
            settings.saveObfs4BridgeInput(
                "obfs4 192.0.2.10:443 \(fingerprint) cert=YWJjZA iat-mode=0"
            ),
            .success(1)
        )
        settings.setMode(.obfs4)

        settings.clearObfs4Bridges()

        // Dropping to direct here would put someone who cleared their bridges
        // onto plain Tor on the network they chose obfs4 to hide from.
        XCTAssertEqual(settings.mode, .obfs4)
        XCTAssertTrue(settings.obfs4BridgeLines.isEmpty)
        XCTAssertEqual(TorRoutePlanner.candidates(for: settings.routeConfiguration), [])
    }

    func test_explicitModeNeverPlansAnyOtherTransport() {
        // `startArti` refuses any transport outside this set, so this is the
        // invariant that keeps a censorship mode from silently becoming plain
        // Tor. A device run in obfs4 mode did start Arti with no pluggable
        // transport at all, which is the exposure that guard now blocks.
        let bridges = ["Bridge obfs4 example"]

        for mode in [TorTransportMode.direct, .obfs4, .snowflake] {
            let configuration = TorRouteConfiguration(
                mode: mode,
                obfs4BridgeLines: bridges,
                // A previous success on another transport must not leak into
                // an explicitly chosen mode; only auto is allowed to reorder.
                lastSuccessfulTransport: .snowflake
            )
            let candidates = TorRoutePlanner.candidates(for: configuration)
            XCTAssertFalse(
                candidates.contains(where: { $0.rawValue != mode.rawValue }),
                "\(mode.rawValue) mode planned \(candidates.map(\.rawValue))"
            )
        }

        // obfs4 without bridge material has nothing to plan, and must not fall
        // back to a transport the user did not pick.
        XCTAssertEqual(
            TorRoutePlanner.candidates(
                for: TorRouteConfiguration(
                    mode: .obfs4,
                    obfs4BridgeLines: [],
                    lastSuccessfulTransport: .direct
                )
            ),
            []
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

    /// Backgrounding preserves the attempt now instead of tearing it down, so
    /// nothing clears `isReady` when the system reclaims Arti during a long
    /// suspension. Taking the flag at face value returned `.none` for a route
    /// whose SOCKS listener was gone, and the app went on reporting a working
    /// Tor until traffic failed against it.
    func test_foregroundRecoveryRebuildsAReadyRouteWhoseRuntimeIsGone() {
        XCTAssertEqual(
            TorLifecyclePolicy.foregroundRecoveryAction(
                autoStartAllowed: true,
                isForeground: true,
                isReady: true,
                isRestarting: false,
                shutdownInFlight: false,
                artiIsRunning: false
            ),
            .restart
        )
        XCTAssertEqual(
            TorLifecyclePolicy.foregroundRecoveryAction(
                autoStartAllowed: true,
                isForeground: true,
                isReady: true,
                isRestarting: false,
                shutdownInFlight: true,
                artiIsRunning: false
            ),
            .deferUntilShutdownCompletes
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

    /// Only the iOS slices were rebuilt to publish fractional progress. The
    /// macOS one still reports 0 until the client is bootstrapped and then 100,
    /// so "stopped advancing" is indistinguishable from "not started yet"
    /// there: the stall windows called every cold start slower than 30s a
    /// blocked network, and the per-transport ceiling cut the wait that build
    /// used to get from 75s to 45s.
    func test_aCoarseProgressSliceIsJudgedOnlyByItsCeiling() {
        let coarse = TorBootstrapBudget.forRoute(
            .direct,
            reportsFractionalProgress: false
        )
        XCTAssertNil(coarse.stallWindow)
        XCTAssertGreaterThanOrEqual(coarse.deadline, 75)
        XCTAssertEqual(
            TorBootstrapWaitPolicy.outcome(
                progress: 0,
                highWaterProgress: 0,
                secondsSinceProgress: 600,
                remainingSeconds: 30,
                stallWindow: coarse.stallWindow
            ),
            .keepWaiting,
            "progress that never moves carries no information on this slice"
        )
        XCTAssertEqual(
            TorBootstrapWaitPolicy.outcome(
                progress: 0,
                highWaterProgress: 0,
                secondsSinceProgress: 600,
                remainingSeconds: 0,
                stallWindow: coarse.stallWindow
            ),
            .ceilingReached
        )
    }

    /// Coarse progress is a reason to wait longer, never to wait less. The
    /// per-transport ceilings were written for a slice that reports real
    /// percentages; applying them to one that reports 0 until it reports 100
    /// cut the direct-route wait from the 75s that build used to get down to
    /// 45s, on top of the stall window killing it at 30s.
    func test_coarseProgressNeverShortensTheWaitAnyRouteWouldOtherwiseGet() {
        for transport in [TorTransport.direct, .obfs4, .snowflake] {
            let coarse = TorBootstrapBudget.forRoute(
                transport,
                reportsFractionalProgress: false
            )
            let fractional = TorBootstrapBudget.forRoute(
                transport,
                reportsFractionalProgress: true
            )
            XCTAssertGreaterThanOrEqual(
                coarse.deadline,
                fractional.deadline,
                "\(transport) waits less on the slice with less information"
            )
            XCTAssertGreaterThanOrEqual(
                coarse.deadline,
                TorBootstrapBudget.coarseProgressDeadline
            )
        }
    }

    func test_aFractionalProgressSliceKeepsThePerTransportBudget() {
        for transport in [TorTransport.direct, .obfs4, .snowflake] {
            let budget = TorBootstrapBudget.forRoute(
                transport,
                reportsFractionalProgress: true
            )
            XCTAssertEqual(budget.stallWindow, transport.bootstrapStallWindow)
            XCTAssertEqual(budget.deadline, transport.bootstrapDeadline)
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

    /// The wait callers get by default has to outlast the sequence the manager
    /// runs, or auto mode abandons Snowflake — the route most likely to be the
    /// one that gets through — while it is still bootstrapping. The literals
    /// are the second reading of the ceilings on purpose: raising one has to be
    /// acknowledged here rather than silently shortening that wait.
    func test_theDefaultReadyWaitOutlastsAFullAutoSequence() {
        XCTAssertEqual(TorTransport.direct.bootstrapDeadline, 45)
        XCTAssertEqual(TorTransport.obfs4.bootstrapDeadline, 120)
        XCTAssertEqual(TorTransport.snowflake.bootstrapDeadline, 300)
        XCTAssertGreaterThan(TorTransport.fullSequenceDeadline, 45 + 120 + 300)
    }

    // MARK: - Readiness resolution

    /// The defect this policy exists to fix. Readiness had two writers a
    /// second apart: the bootstrap poll published the percentage, and the SOCKS
    /// probe published reachability. When the probe landed first, readiness was
    /// judged against a percentage that nothing would ever refresh, so a fully
    /// bootstrapped Tor with a live listener stayed fail-closed for good.
    func test_aStaleProgressCopyDoesNotHoldBackAReachableRoute() {
        let resolved = TorReadinessPolicy.resolve(
            socksReady: true,
            publishedProgress: 83,
            liveProgress: { 100 }
        )

        XCTAssertTrue(resolved.isReady)
        XCTAssertEqual(resolved.progress, 100, "the stale copy has to be corrected, not just overridden")
    }

    func test_aReachableListenerStillNeedsACompletedBootstrap() {
        let resolved = TorReadinessPolicy.resolve(
            socksReady: true,
            publishedProgress: 40,
            liveProgress: { 62 }
        )

        XCTAssertFalse(resolved.isReady)
        XCTAssertEqual(resolved.progress, 62)
    }

    func test_readinessAlwaysRequiresTheSocksListener() {
        var consultedLiveProgress = false
        let resolved = TorReadinessPolicy.resolve(
            socksReady: false,
            publishedProgress: 100,
            liveProgress: {
                consultedLiveProgress = true
                return 100
            }
        )

        XCTAssertFalse(resolved.isReady, "a completed bootstrap without a listener carries no traffic")
        XCTAssertEqual(resolved.progress, 100)
        XCTAssertFalse(consultedLiveProgress, "nothing to re-read when the route cannot be ready either way")
    }

    func test_anAlreadyCompleteCopyIsTrustedWithoutReReadingIt() {
        var consultedLiveProgress = false
        let resolved = TorReadinessPolicy.resolve(
            socksReady: true,
            publishedProgress: 100,
            liveProgress: {
                consultedLiveProgress = true
                return 0
            }
        )

        XCTAssertTrue(resolved.isReady)
        XCTAssertFalse(
            consultedLiveProgress,
            "Arti zeroes its counter when an attempt ends, so re-reading a settled route can only unset it"
        )
    }
}
