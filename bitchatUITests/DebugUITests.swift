import XCTest

class DebugUITests: XCTestCase {
    
    func testDiscoverAvailableElements() throws {
        let app = XCUIApplication()
        app.launch()
        
        // Wait for app to load
        sleep(3)
        
        print("=== DISCOVERING UI ELEMENTS ===")
        
        // List all text fields
        print("TEXT FIELDS:")
        for (index, textField) in app.textFields.allElementsBoundByIndex.enumerated() {
            print("  [\(index)] ID: '\(textField.identifier)' Label: '\(textField.label)' Placeholder: '\(textField.placeholderValue ?? "none")'")
        }
        
        // List all buttons
        print("\nBUTTONS:")
        for (index, button) in app.buttons.allElementsBoundByIndex.prefix(10).enumerated() {
            print("  [\(index)] ID: '\(button.identifier)' Label: '\(button.label)'")
        }
        
        // List all static texts
        print("\nSTATIC TEXTS (first 10):")
        for (index, text) in app.staticTexts.allElementsBoundByIndex.prefix(10).enumerated() {
            print("  [\(index)] ID: '\(text.identifier)' Label: '\(text.label)'")
        }
        
        // List other elements
        print("\nOTHER ELEMENTS:")
        for (index, element) in app.otherElements.allElementsBoundByIndex.prefix(5).enumerated() {
            print("  [\(index)] ID: '\(element.identifier)' Label: '\(element.label)'")
        }
        
        // This test always passes - it's just for discovery
        XCTAssertTrue(true)
    }
}