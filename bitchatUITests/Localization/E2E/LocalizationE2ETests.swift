import XCTest

final class LocalizationE2ETests: XCTestCase {
    func testArabiclLaunchesAndShowsKeyUI() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
        app.launchEnvironment["UITests"] = "1"
        app.launch()

        // Minimal E2E: ensure the location channels control appears in Arabic
        XCTAssertTrue(app.buttons["قنوات الموقع"].firstMatch.waitForExistence(timeout: 10))
    }
}

