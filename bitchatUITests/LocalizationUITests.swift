import XCTest

final class LocalizationUITests: XCTestCase {
    func testSpanishShowsLocationChannelsAccessibility() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launch()

        // The location channels button has a localized accessibility label
        XCTAssertTrue(app.buttons["canales de ubicación"].firstMatch.waitForExistence(timeout: 5))
    }
}

