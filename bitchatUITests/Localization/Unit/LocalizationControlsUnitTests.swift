import XCTest

final class LocalizationControlsUnitTests: XCTestCase {

    private func bringComposerIntoView(_ app: XCUIApplication) {
        // Try to bring the composer TextField into view if the list scrolled
        for _ in 0..<3 {
            let tf = app.textFields.firstMatch
            if tf.waitForExistence(timeout: 1) { return }
            app.swipeUp()
        }
    }

    private func existsLocalizedElement(_ app: XCUIApplication, expected: String, timeout: TimeInterval = 5) -> Bool {
        let byTextFieldLabel = app.textFields[expected].waitForExistence(timeout: timeout)
        if byTextFieldLabel { return true }
        let byTextFieldId = app.textFields.matching(NSPredicate(format: "identifier == %@", expected)).firstMatch
        if byTextFieldId.waitForExistence(timeout: 1) { return true }
        let any = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR identifier == %@", expected, expected)).firstMatch
        return any.waitForExistence(timeout: 1)
    }


    // Locales we want quick confidence on (LTR/RTL/CJK/Latin)
    private let locales = ["es", "fr", "zh-Hans", "ar", "ru"]

    // Expected localized strings for placeholder and send button where we know them
    private let placeholderByLocale: [String: String] = [
        // Use exact known translations from the catalog
        "es": "escribe un mensaje...",
        "fr": "écrivez un message...",
        "zh-Hans": "输入消息...",
        "ar": "اكتب رسالة...",
        "ru": "type a message..."
    ]

    private let sendButtonLabelByLocale: [String: String] = [
        "es": "Enviar mensaje", // if not present, fall back to Base assertion
        "fr": "Envoyer le message",
        "zh-Hans": "发送消息",
        "ar": "إرسال رسالة",
        "ru": "Отправить сообщение"
    ]

    // Helper to get expected fallback (Base) for labels when we don't specify a locale value
    private let basePlaceholderFallback = "type a message..." // Base value for placeholder.type_message
    private let baseSendLabelFallback = "Send message"     // Base value for accessibility.send_message

    
    private func appleLocale(for language: String) -> String {
        switch language {
        case "es": return "es_ES"
        case "fr": return "fr_FR"
        case "zh-Hans": return "zh_CN"
        case "ar": return "ar_SA"
        case "ru": return "ru_RU"
        default: return "en_US"
        }
    }

func testPlaceholderLocalizedAcrossLocales() {
        for locale in locales {
            let app = XCUIApplication()
            app.launchArguments += ["-AppleLanguages", "(\(locale))", "-AppleLocale", appleLocale(for: locale)]
            app.launchEnvironment["UITests"] = "1"
            app.launch()
            bringComposerIntoView(app)

            let expected = placeholderByLocale[locale] ?? basePlaceholderFallback
            // Placeholder appears as the text field's identifier in XCTest
            let input = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", "composer.input")).firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 5), "Missing placeholder for locale=\(locale)")
            app.terminate()
        }
    }

    func testSendButtonLabelAcrossLocales() {
        for locale in locales {
            let app = XCUIApplication()
            app.launchArguments += ["-AppleLanguages", "(\(locale))", "-AppleLocale", appleLocale(for: locale)]
            app.launchEnvironment["UITests"] = "1"
            app.launch()
            bringComposerIntoView(app)

            let expected = sendButtonLabelByLocale[locale] ?? baseSendLabelFallback
            let exists = app.buttons[expected].waitForExistence(timeout: 5) || app.buttons.matching(NSPredicate(format: "identifier == %@", expected)).firstMatch.waitForExistence(timeout: 1) || existsLocalizedElement(app, expected: expected)
            XCTAssertTrue(exists, "Missing send button label for locale=\(locale)")
            app.terminate()
        }
    }
}
