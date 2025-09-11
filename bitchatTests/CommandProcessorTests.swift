import XCTest
@testable import bitchat

final class CommandProcessorTests: XCTestCase {

    @MainActor
    func test_slap_notFoundGrammar() {
        let processor = CommandProcessor(chatViewModel: nil, meshService: nil)
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
        let processor = CommandProcessor(chatViewModel: nil, meshService: nil)
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
        let processor = CommandProcessor(chatViewModel: nil, meshService: nil)
        let result = processor.process("/slap")
        switch result {
        case .error(let message):
            XCTAssertEqual(message, "usage: /slap <nickname>")
        default:
            XCTFail("Expected error result for usage message")
        }
    }
}

