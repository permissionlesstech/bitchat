import XCTest
@testable import bitchat

final class CommandProcessorTests: XCTestCase {
    
    var identityManager: MockIdentityManager!
    
    override func setUp() {
        super.setUp()
        // Provide a minimal identity manager for commands that query identity/block lists
        identityManager = MockIdentityManager(MockKeychain())
    }
    
    override func tearDown() {
        identityManager = nil
        super.tearDown()
    }

    @MainActor
    func test_slap_notFoundGrammar() {
        let processor = CommandProcessor(chatViewModel: nil, meshService: nil, identityManager: identityManager)
        let result = processor.process("/slap @system")
        switch result {
        case .error(let message):
            let expectedMessage = String.localizedStringWithFormat(String(localized: "command.error.cannot_block_unblock"), "slap", "system")
            XCTAssertEqual(message, expectedMessage)
        default:
            XCTFail("Expected error result")
        }
    }

    @MainActor
    func test_hug_notFoundGrammar() {
        let processor = CommandProcessor(chatViewModel: nil, meshService: nil, identityManager: identityManager)
        let result = processor.process("/hug @system")
        switch result {
        case .error(let message):
            let expectedMessage = String.localizedStringWithFormat(String(localized: "command.error.cannot_block_unblock"), "hug", "system")
            XCTAssertEqual(message, expectedMessage)
        default:
            XCTFail("Expected error result")
        }
    }

    @MainActor
    func test_slap_usageMessage() {
        let processor = CommandProcessor(chatViewModel: nil, meshService: nil, identityManager: identityManager)
        let result = processor.process("/slap")
        switch result {
        case .error(let message):
            let expectedMessage = String.localizedStringWithFormat(String(localized: "command.usage.block_unblock"), "slap")
            XCTAssertEqual(message, expectedMessage)
        default:
            XCTFail("Expected error result for usage message")
        }
    }
}
