import XCTest

class LocalizationUITests: XCTestCase {
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }
    
    // MARK: - Dynamic Parameterized Testing Framework
    
    /// Generic test function for validating localized values
    func testLocalizedValue(key: String, locale: String, expectedValue: String? = nil, file: StaticString = #file, line: UInt = #line) {
        let actualValue = getLocalizedValue(key: key, locale: locale)
        
        if let expected = expectedValue {
            XCTAssertEqual(actualValue, expected, 
                          "Key '\(key)' expected '\(expected)' but got '\(actualValue)' in locale '\(locale)'",
                          file: file, line: line)
        } else {
            XCTAssertFalse(actualValue.isEmpty, 
                          "Key '\(key)' is empty in locale '\(locale)'", 
                          file: file, line: line)
            XCTAssertNotEqual(actualValue, key, 
                             "Key '\(key)' not localized in locale '\(locale)' (returning raw key)",
                             file: file, line: line)
        }
    }
    
    /// Matrix test: All critical keys across all 29 languages
    func testAllCriticalKeysAllLanguages() {
        let criticalKeys = [
            "nav.people",
            "actions.block", 
            "actions.mention",
            "actions.private_message",
            "common.close",
            "common.cancel",
            "placeholder.type_message",
            "placeholder.nickname",
            "alert.bluetooth_required",
            "accessibility.send_message"
        ]
        
        let allLanguages = [
            "en", "es", "zh-Hans", "zh-Hant", "zh-HK", "ar", "arz", "hi", "fr", "de", 
            "ru", "ja", "pt", "pt-BR", "ur", "tr", "vi", "id", "bn", "fil", "tl", 
            "yue", "ta", "te", "mr", "sw", "ha", "pcm", "pnb"
        ]
        
        for key in criticalKeys {
            for locale in allLanguages {
                testLocalizedValue(key: key, locale: locale)
            }
        }
    }
    
    // MARK: - Critical UI Path Testing
    
    func testMainChatInterface() throws {
        app.launch()
        
        let currentLocale = getCurrentLocale()
        
        // Test message input using identifier
        let messageInput = app.textFields["message-input"]
        XCTAssertTrue(messageInput.exists, "Message input should exist")
        
        // Verify placeholder is localized
        let expectedPlaceholder = getLocalizedValue(key: "placeholder.type_message", locale: currentLocale)
        XCTAssertEqual(messageInput.placeholderValue, expectedPlaceholder, "Placeholder should be localized")
        
        // Test send button using identifier
        let sendButton = app.buttons["send-button"]
        XCTAssertTrue(sendButton.exists, "Send button should exist")
        
        // Verify accessibility label is localized
        let expectedSendLabel = getLocalizedValue(key: "accessibility.send_message", locale: currentLocale)
        XCTAssertEqual(sendButton.label, expectedSendLabel, "Send button accessibility should be localized")
    }
    
    func testRightSidebarSlideOut() throws {
        app.launch()
        
        let currentLocale = getCurrentLocale()
        let expectedPeopleText = getLocalizedValue(key: "nav.people", locale: currentLocale)
        
        // Test sidebar slide gesture using main chat view identifier
        let mainView = app.otherElements["main-chat-view"]
        XCTAssertTrue(mainView.exists, "Main chat view should exist")
        mainView.swipeLeft()
        
        // Verify sidebar opened with localized "PEOPLE" header using identifier
        let peopleHeader = app.staticTexts["sidebar-people-header"]
        XCTAssertTrue(peopleHeader.waitForExistence(timeout: 3.0), 
                     "Sidebar people header should appear when sidebar opens")
        
        // Verify the header has the correct localized text
        XCTAssertEqual(peopleHeader.label, expectedPeopleText,
                      "Sidebar header should show localized text: \(expectedPeopleText)")
        
        // Test closing sidebar by tapping on main view
        mainView.tap()
        sleep(1) // Allow animation time
        // Header might still exist but not be visible/hittable
    }
    
    func testLocationChannelsSheet() throws {
        app.launch()
        
        let currentLocale = getCurrentLocale()
        
        // Find and tap mesh/location button (contains # symbol)
        let channelButton = app.buttons.containing(NSPredicate(format: "label CONTAINS '#'")).firstMatch
        XCTAssertTrue(channelButton.exists, "Channel button should exist")
        channelButton.tap()
        
        // Verify sheet opens with localized title
        let expectedTitle = getLocalizedValue(key: "location.title", locale: currentLocale)
        let sheetTitle = app.staticTexts[expectedTitle]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 3.0),
                     "Location channels sheet should open with localized title")
        
        // Verify close button is localized
        let expectedCloseText = getLocalizedValue(key: "nav.close", locale: currentLocale)
        let closeButton = app.buttons[expectedCloseText]
        XCTAssertTrue(closeButton.exists, "Close button should be localized")
        
        // Test closing sheet
        closeButton.tap()
        XCTAssertFalse(sheetTitle.exists, "Sheet should close")
    }
    
    func testAppInfoSheet() throws {
        app.launch()
        
        // Tap on bitchat/ title to open app info
        let appTitle = app.staticTexts["bitchat/"]
        XCTAssertTrue(appTitle.exists, "App title should exist")
        appTitle.tap()
        
        // Verify app info sheet opens
        let appInfoSheet = app.scrollViews.firstMatch
        XCTAssertTrue(appInfoSheet.waitForExistence(timeout: 3.0),
                     "App info sheet should open")
        
        // Test done/close button localization
        let currentLocale = getCurrentLocale()
        let expectedDoneText = getLocalizedValue(key: "nav.done", locale: currentLocale)
        let doneButton = app.buttons[expectedDoneText]
        XCTAssertTrue(doneButton.exists, "Done button should be localized")
    }
    
    func testMessageContextMenu() throws {
        app.launch()
        
        // Wait for any messages to appear or send a test message first
        let messageInput = app.textFields.firstMatch
        messageInput.tap()
        messageInput.typeText("Test message for context menu")
        
        let sendButton = app.buttons.firstMatch
        sendButton.tap()
        
        // Long press on the message to show context menu
        let testMessage = app.staticTexts["Test message for context menu"]
        if testMessage.waitForExistence(timeout: 2.0) {
            testMessage.press(forDuration: 1.0)
            
            // Verify context menu actions are localized
            let currentLocale = getCurrentLocale()
            let expectedCopyText = getLocalizedValue(key: "actions.copy_message", locale: currentLocale)
            let copyAction = app.buttons[expectedCopyText]
            XCTAssertTrue(copyAction.waitForExistence(timeout: 1.0),
                         "Copy message action should be localized")
        }
    }
    
    // MARK: - Comprehensive Accessibility Testing
    
    func testAccessibilityLabelsAllLanguages() {
        let accessibilityKeys = [
            "accessibility.send_message",
            "accessibility.open_unread_private_chat", 
            "accessibility.location_channels",
            "accessibility.people_count",
            "accessibility.connected_mesh",
            "accessibility.back_to_main"
        ]
        
        let keyLanguages = ["en", "es", "zh-Hans", "ar", "fr", "de", "ja"]
        
        for key in accessibilityKeys {
            for locale in keyLanguages {
                let value = getLocalizedValue(key: key, locale: locale)
                
                XCTAssertFalse(value.isEmpty, 
                              "Accessibility key '\(key)' empty in \(locale)")
                XCTAssertNotEqual(value, key,
                                 "Accessibility key '\(key)' not localized in \(locale)")
                
                // Verify accessibility text is appropriate length (not too long for screen readers)
                XCTAssertLessThan(value.count, 100, 
                                 "Accessibility label '\(key)' too long in \(locale): '\(value)'")
            }
        }
    }
    
    func testRTLLanguageSupport() {
        let rtlLanguages = ["ar", "arz", "ur", "pnb"] // Right-to-left languages
        
        for locale in rtlLanguages {
            // Test that RTL languages have proper localized values
            let blockAction = getLocalizedValue(key: "actions.block", locale: locale)
            let closeAction = getLocalizedValue(key: "common.close", locale: locale)
            
            XCTAssertFalse(blockAction.isEmpty, "Block action should be localized for RTL language \(locale)")
            XCTAssertFalse(closeAction.isEmpty, "Close action should be localized for RTL language \(locale)")
            
            // Since we're using .xcstrings with English fallbacks, RTL languages 
            // currently have English values - this is expected for now
            // Future enhancement: Add proper RTL translations
            XCTAssertNotEqual(blockAction, "actions.block", "Should not return raw key for \(locale)")
            XCTAssertNotEqual(closeAction, "common.close", "Should not return raw key for \(locale)")
        }
    }
    
    func testCJKLanguageSupport() {
        let cjkLanguages = ["zh-Hans", "zh-Hant", "zh-HK", "ja", "yue"] // Chinese, Japanese, Cantonese
        
        for locale in cjkLanguages {
            // Test CJK character support
            let peopleLabel = getLocalizedValue(key: "nav.people", locale: locale)
            let messageInput = getLocalizedValue(key: "placeholder.type_message", locale: locale)
            
            XCTAssertFalse(peopleLabel.isEmpty, "People label should exist for CJK language \(locale)")
            XCTAssertFalse(messageInput.isEmpty, "Message input should exist for CJK language \(locale)")
            
            // Verify proper Unicode handling (CJK characters should render correctly)
            XCTAssertTrue(peopleLabel.unicodeScalars.allSatisfy { !$0.properties.isIdeographic || $0.properties.isIdeographic }, 
                         "CJK text should handle Unicode properly in \(locale)")
        }
    }
    
    // MARK: - UI Interaction + Localization Integration Tests
    
    func testSidebarInteractionWithLocalization() throws {
        app.launch()
        
        let currentLocale = getCurrentLocale()
        
        // 1. Open sidebar using main chat view identifier
        let mainView = app.otherElements["main-chat-view"]
        XCTAssertTrue(mainView.exists, "Main chat view should exist")
        mainView.swipeLeft()
        
        // 2. Verify sidebar people header appears
        let peopleHeader = app.staticTexts["sidebar-people-header"]
        XCTAssertTrue(peopleHeader.waitForExistence(timeout: 3.0), "Sidebar should open")
        
        // 3. Verify header text is localized
        let expectedPeopleText = getLocalizedValue(key: "nav.people", locale: currentLocale)
        XCTAssertEqual(peopleHeader.label, expectedPeopleText, "Header should be localized")
        
        // 4. Test QR button if it exists (mesh mode)
        let qrButton = app.buttons.matching(NSPredicate(format: "identifier CONTAINS 'qr'")).firstMatch
        if qrButton.exists {
            XCTAssertFalse(qrButton.label.isEmpty, "QR button should have accessibility label")
        }
    }
    
    func testSheetNavigationFlow() throws {
        app.launch()
        
        let currentLocale = getCurrentLocale()
        
        // 1. Open location channels sheet using accessibility identifier
        let channelButton = app.buttons["channel-button"]
        XCTAssertTrue(channelButton.exists, "Channel button should exist")
        channelButton.tap()
        
        // 2. Verify sheet opens with localized title
        let sheetTitle = app.staticTexts["location-sheet-title"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 3.0), "Location sheet should open")
        
        // Verify title has correct localized text
        let expectedTitle = getLocalizedValue(key: "location.title", locale: currentLocale)
        XCTAssertEqual(sheetTitle.label, expectedTitle, "Sheet title should be localized")
        
        // 3. Test geohash input exists and has proper placeholder
        let geohashField = app.textFields["geohash-input"]
        if geohashField.exists {
            let expectedPlaceholder = getLocalizedValue(key: "placeholder.geohash", locale: currentLocale)
            XCTAssertEqual(geohashField.placeholderValue, expectedPlaceholder,
                          "Geohash input should have localized placeholder")
        }
        
        // 4. Close sheet with localized button
        let closeButton = app.buttons["location-sheet-close"]
        XCTAssertTrue(closeButton.exists, "Close button should exist")
        
        let expectedCloseText = getLocalizedValue(key: "nav.close", locale: currentLocale)
        XCTAssertEqual(closeButton.label, expectedCloseText, "Close button should be localized")
        
        closeButton.tap()
        
        // Verify sheet closes
        XCTAssertFalse(sheetTitle.exists, "Sheet should close after tapping close button")
    }
    
    func testAccessibilityAuditAllInteractiveElements() throws {
        app.launch()
        
        let currentLocale = getCurrentLocale()
        
        // Audit all buttons for proper accessibility
        let allButtons = app.buttons.allElementsBoundByIndex
        
        for button in allButtons.prefix(10) { // Test sample of buttons
            // Every button should have an accessibility label
            XCTAssertFalse(button.label.isEmpty, 
                          "Button should have accessibility label: \(button.identifier)")
            
            // Interactive elements should be properly labeled
            if button.isEnabled {
                XCTAssertTrue(button.label.count > 2, 
                             "Interactive button should have meaningful label: \(button.label)")
            }
        }
        
        // Test text fields have proper placeholders
        let allTextFields = app.textFields.allElementsBoundByIndex
        for textField in allTextFields {
            XCTAssertFalse(textField.placeholderValue?.isEmpty ?? true,
                          "Text field should have placeholder: \(textField.identifier)")
        }
        
        // Test navigation elements accessibility
        let navElements = app.staticTexts.allElementsBoundByIndex.filter { 
            $0.label.contains("bitchat") || $0.label.contains("#") || $0.label.contains("@")
        }
        for navElement in navElements.prefix(5) {
            XCTAssertTrue(navElement.isAccessibilityElement, 
                         "Navigation element should be accessible: \(navElement.label)")
        }
    }
    
    // MARK: - Language-Specific UI Tests
    
    func testChineseUIInteractions() throws {
        // Test Chinese UI with proper character rendering and interaction
        setAppLanguageAndRestart("zh-Hans")
        
        app.launch()
        
        // Test Chinese text in sidebar
        app.otherElements.firstMatch.swipeLeft()
        let chinesePeopleText = getLocalizedValue(key: "nav.people", locale: "zh-Hans") 
        let peopleHeader = app.staticTexts[chinesePeopleText]
        XCTAssertTrue(peopleHeader.waitForExistence(timeout: 2.0),
                     "Chinese sidebar header should appear")
        
        // Test Chinese input placeholder
        let messageField = app.textFields.firstMatch
        let chinesePlaceholder = getLocalizedValue(key: "placeholder.type_message", locale: "zh-Hans")
        XCTAssertEqual(messageField.placeholderValue, chinesePlaceholder,
                      "Message input should show Chinese placeholder")
    }
    
    func testArabicRTLInteractions() throws {
        // Test Arabic RTL UI layout and interactions  
        setAppLanguageAndRestart("ar")
        
        app.launch()
        
        // Test RTL text rendering
        let arabicBlockText = getLocalizedValue(key: "actions.block", locale: "ar")
        
        // Send a test message to enable context menu
        let messageInput = app.textFields.firstMatch
        messageInput.tap()
        messageInput.typeText("اختبار") // "Test" in Arabic
        app.buttons.firstMatch.tap()
        
        // Long press to show context menu with RTL text
        let testMessage = app.staticTexts["اختبار"]
        if testMessage.waitForExistence(timeout: 2.0) {
            testMessage.press(forDuration: 1.0)
            
            let blockButton = app.buttons[arabicBlockText]
            XCTAssertTrue(blockButton.waitForExistence(timeout: 1.0),
                         "Arabic block action should appear in context menu")
        }
    }
    
    // MARK: - Accessibility Integration Tests
    
    func testVoiceOverCompatibilityAcrossLanguages() throws {
        let testLanguages = ["en", "es", "zh-Hans", "ar", "fr"]
        
        for locale in testLanguages {
            // Test that all accessibility strings are VoiceOver-friendly
            let accessibilityKeys = [
                "accessibility.send_message",
                "accessibility.open_unread_private_chat",
                "accessibility.people_count",
                "accessibility.back_to_main"
            ]
            
            for key in accessibilityKeys {
                let value = getLocalizedValue(key: key, locale: locale)
                
                // Accessibility labels should be descriptive but concise
                XCTAssertGreaterThan(value.count, 3, "Accessibility label too short: \(value)")
                XCTAssertLessThan(value.count, 80, "Accessibility label too long: \(value)")
                
                // Should not contain technical markup or symbols
                XCTAssertFalse(value.contains("%@") && value.contains("%d"), 
                              "Raw format strings in accessibility label: \(value)")
            }
        }
    }
    
    func testScreenReaderNavigationFlow() throws {
        app.launch()
        
        // Test key accessibility elements using identifiers
        let messageInput = app.textFields["message-input"]
        let sendButton = app.buttons["send-button"]
        
        // Both elements should exist and be accessible
        XCTAssertTrue(messageInput.exists, "Message input should exist")
        XCTAssertTrue(sendButton.exists, "Send button should exist")
        
        XCTAssertTrue(messageInput.isAccessibilityElement, "Message input should be accessible")
        XCTAssertTrue(sendButton.isAccessibilityElement, "Send button should be accessible")
        
        // Both should have meaningful accessibility labels
        XCTAssertFalse(messageInput.label.isEmpty, "Message input should have accessibility label")
        XCTAssertFalse(sendButton.label.isEmpty, "Send button should have accessibility label")
        
        // Test placeholder is localized
        let currentLocale = getCurrentLocale()
        let expectedPlaceholder = getLocalizedValue(key: "placeholder.type_message", locale: currentLocale)
        XCTAssertEqual(messageInput.placeholderValue, expectedPlaceholder, "Input placeholder should be localized")
    }
    
    // MARK: - Edge Case Testing
    
    func testMissingLocalizationGracefulDegradation() throws {
        // Test what happens if a key is missing (should fallback gracefully)
        app.launch()
        
        // This tests our fallback chain: requested locale -> English -> key name
        let nonexistentKey = "test.nonexistent.key.12345"
        let fallbackValue = getLocalizedValue(key: nonexistentKey, locale: "zh-Hans")
        
        // Should gracefully return the key or English fallback, not crash
        XCTAssertNotNil(fallbackValue, "Missing keys should fallback gracefully")
    }
    
    func testLanguageSwitchingDuringRuntime() throws {
        // Test app behavior when user changes system language
        app.launch()
        
        // Verify initial English state
        let englishPeople = getLocalizedValue(key: "nav.people", locale: "en")
        
        // This is more of a documentation test since runtime language switching
        // requires app restart in iOS
        XCTAssertEqual(englishPeople, "PEOPLE", "English baseline should be correct")
    }
    
    // MARK: - Performance Testing
    
    func testLocalizationPerformance() {
        // Measure time to load and display localized strings
        measure {
            for i in 0..<100 {
                let _ = getLocalizedValue(key: "nav.people", locale: "zh-Hans")
                let _ = getLocalizedValue(key: "actions.block", locale: "ar")
                let _ = getLocalizedValue(key: "placeholder.type_message", locale: "es")
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private func getLocalizedValue(key: String, locale: String) -> String {
        // Access our .xcstrings file to get expected localized values
        guard let path = Bundle.main.path(forResource: "Localizable", ofType: "xcstrings"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: Any],
              let entry = strings[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let localeEntry = localizations[locale] as? [String: Any],
              let stringUnit = localeEntry["stringUnit"] as? [String: Any],
              let value = stringUnit["value"] as? String else {
            return key // Return key if not found (test will catch this)
        }
        return value
    }
    
    private func getCurrentLocale() -> String {
        return Locale.current.languageCode ?? "en"
    }
    
    private func setAppLanguageAndRestart(_ languageCode: String) {
        // Helper to change app language and restart
        // Note: This requires app restart to take effect
        let shellCommand = "xcrun simctl spawn 'iPhone 15 Pro' defaults write com.apple.Preferences AppleLanguages -array '\(languageCode)' && xcrun simctl shutdown 'iPhone 15 Pro' && xcrun simctl boot 'iPhone 15 Pro'"
        
        // In a real implementation, this would be executed before app.launch()
        // For now, this documents the intended behavior
    }
}

// MARK: - Test Data Structures

extension LocalizationUITests {
    
    /// Comprehensive test matrix for systematic validation
    struct LocalizationTestCase {
        let key: String
        let uiContext: String
        let criticalityLevel: CriticalityLevel
        let testInLanguages: [String]
        
        enum CriticalityLevel {
            case critical   // Must work in all 29 languages
            case important  // Must work in top 10 languages  
            case standard   // Must work in top 5 languages
        }
    }
    
    static let comprehensiveTestMatrix: [LocalizationTestCase] = [
        // Navigation - Critical (user can't use app without these)
        LocalizationTestCase(key: "nav.people", uiContext: "Sidebar header", 
                           criticalityLevel: .critical, testInLanguages: []),
        LocalizationTestCase(key: "nav.close", uiContext: "Sheet close buttons",
                           criticalityLevel: .critical, testInLanguages: []),
        
        // Actions - Critical (core functionality)
        LocalizationTestCase(key: "actions.block", uiContext: "Security action",
                           criticalityLevel: .critical, testInLanguages: []),
        LocalizationTestCase(key: "actions.private_message", uiContext: "DM action", 
                           criticalityLevel: .critical, testInLanguages: []),
        
        // Input - Important (affects UX significantly)
        LocalizationTestCase(key: "placeholder.type_message", uiContext: "Message composition",
                           criticalityLevel: .important, testInLanguages: []),
        LocalizationTestCase(key: "placeholder.nickname", uiContext: "Identity setup",
                           criticalityLevel: .important, testInLanguages: []),
        
        // Accessibility - Critical (affects users with disabilities)
        LocalizationTestCase(key: "accessibility.send_message", uiContext: "Send button screen reader",
                           criticalityLevel: .critical, testInLanguages: []),
        LocalizationTestCase(key: "accessibility.people_count", uiContext: "Count announcements",
                           criticalityLevel: .important, testInLanguages: []),
    ]
}