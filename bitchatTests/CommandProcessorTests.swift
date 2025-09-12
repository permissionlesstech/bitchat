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
            XCTAssertEqual(message, "cannot slap system: not found")
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
            XCTAssertEqual(message, "cannot hug system: not found")
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
            XCTAssertEqual(message, "usage: /slap <nickname>")
        default:
            XCTFail("Expected error result for usage message")
        }
    }
}
