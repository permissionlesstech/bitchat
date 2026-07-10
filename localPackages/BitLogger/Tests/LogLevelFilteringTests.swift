import XCTest
@testable import BitLogger

/// The public logging wrappers must not evaluate their message autoclosure
/// when the level is filtered out — hot paths log per packet/event, and
/// building a discarded interpolated string on each call is real overhead.
final class LogLevelFilteringTests: XCTestCase {
    private final class EvaluationCounter {
        var count = 0
        func message() -> String {
            count += 1
            return "expensive interpolation"
        }
    }

    private var originalLevel: SecureLogger.LogLevel!

    override func setUp() {
        super.setUp()
        originalLevel = SecureLogger.minimumLevel
    }

    override func tearDown() {
        SecureLogger.minimumLevel = originalLevel
        super.tearDown()
    }

    func testFilteredDebugMessageIsNeverEvaluated() {
        SecureLogger.minimumLevel = .info
        let counter = EvaluationCounter()

        SecureLogger.debug(counter.message())

        XCTAssertEqual(counter.count, 0, "Filtered debug message should not be constructed")
    }

    func testFilteredInfoMessageIsNeverEvaluated() {
        SecureLogger.minimumLevel = .error
        let counter = EvaluationCounter()

        SecureLogger.info(counter.message())

        XCTAssertEqual(counter.count, 0, "Filtered info message should not be constructed")
    }

    func testEnabledLevelStillEvaluatesMessage() {
        SecureLogger.minimumLevel = .debug
        let counter = EvaluationCounter()

        SecureLogger.warning(counter.message())

        XCTAssertEqual(counter.count, 1, "Enabled levels must still log")
    }
}
