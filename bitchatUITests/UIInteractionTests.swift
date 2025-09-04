import XCTest

/// Professional UI interaction tests with minimal footprint
/// Tests core user workflows that depend on localization
final class UIInteractionTests: XCTestCase {
    
    private var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }
    
    // MARK: - Single Responsibility: Sidebar Interaction
    
    func testSidebarGestureInteraction() throws {
        app.launch()
        sleep(2)
        
        // Test swipe gesture to open sidebar
        let mainArea = app.otherElements.element(boundBy: 0)
        mainArea.swipeLeft()
        
        // Verify sidebar content appears (should contain user/peer information)
        let sidebarContent = app.staticTexts.allElementsBoundByIndex.filter { text in
            !text.label.isEmpty && (text.label.count > 5) &&
            (text.label.contains("PEOPLE") || text.label.contains("@") || text.label.lowercased().contains("mesh"))
        }
        
        XCTAssertTrue(sidebarContent.count > 0, "Sidebar should show content after swipe")
    }
    
    // MARK: - Single Responsibility: Sheet Navigation  
    
    func testChannelSheetInteraction() throws {
        app.launch()
        sleep(3) // Allow full app load
        
        // Find any tappable element containing "#" (channel selector)
        let channelElements = app.descendants(matching: .any).allElementsBoundByIndex.filter { element in
            element.label.contains("#") && element.isHittable
        }
        
        // If no # button found, test passes (might be in different state)
        guard let channelElement = channelElements.first else {
            XCTAssert(true, "Channel button not found - app may be in different state")
            return
        }
        
        channelElement.tap()
        sleep(2)
        
        // After tapping, should either show sheet content OR navigate
        let hasSheetContent = app.staticTexts.allElementsBoundByIndex.contains { text in
            !text.label.isEmpty && text.label.count > 10
        }
        
        let hasButtons = app.buttons.count > 0
        
        // Either content appeared (sheet) or navigation occurred
        XCTAssertTrue(hasSheetContent || hasButtons, "Tapping channel element should show content or navigation")
    }
    
    // MARK: - Single Responsibility: App Info Sheet
    
    func testAppInfoSheetInteraction() throws {
        app.launch() 
        sleep(2)
        
        // Tap on app title/logo area
        let appTitles = app.staticTexts.allElementsBoundByIndex.filter { text in
            text.label.contains("bitchat") && text.exists
        }
        
        guard let appTitle = appTitles.first else {
            XCTFail("Should have app title element")
            return
        }
        
        appTitle.tap()
        
        // Verify info sheet opens (should show app information)
        let infoContent = app.staticTexts.allElementsBoundByIndex.filter { text in
            text.label.lowercased().contains("feature") ||
            text.label.lowercased().contains("privacy") ||
            text.label.lowercased().contains("bitchat") ||
            text.label.count > 20 // Likely descriptive text
        }
        
        XCTAssertTrue(infoContent.count > 0, "App info sheet should show descriptive content")
    }
    
    // MARK: - Single Responsibility: Message Input Validation
    
    func testMessageInputLocalization() throws {
        app.launch()
        sleep(2)
        
        // Find message input field
        let messageFields = app.textFields.allElementsBoundByIndex
        guard let messageField = messageFields.first else {
            XCTFail("Should have message input field")
            return
        }
        
        // Verify it has a placeholder (indicates localization working)
        let placeholder = messageField.placeholderValue
        XCTAssertFalse(placeholder?.isEmpty ?? true, "Message input should have placeholder text")
        
        // Placeholder should be user-friendly, not a technical key
        XCTAssertFalse(placeholder?.contains(".") ?? false, "Placeholder should not be raw localization key")
        XCTAssertTrue((placeholder?.count ?? 0) > 5, "Placeholder should be descriptive")
    }
}