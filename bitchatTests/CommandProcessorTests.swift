import Testing
@testable import bitchat

struct CommandProcessorTests {
    private var identityManager = MockIdentityManager(MockKeychain())

    @MainActor
    @Test func slapNotFoundGrammar() {
        let processor = CommandProcessor(chatViewModel: nil, meshService: nil, identityManager: identityManager)
        let result = processor.process("/slap @system")
        switch result {
        case .error(let message):
            #expect(message == "cannot slap system: not found")
        default:
            Issue.record("Expected error result")
        }
    }

    @MainActor
    @Test func hugNotFoundGrammar() {
        let processor = CommandProcessor(chatViewModel: nil, meshService: nil, identityManager: identityManager)
        let result = processor.process("/hug @system")
        switch result {
        case .error(let message):
            #expect(message == "cannot hug system: not found")
        default:
            Issue.record("Expected error result")
        }
    }
    
    @MainActor
    @Test func slapUsageMessage() {
        let processor = CommandProcessor(chatViewModel: nil, meshService: nil, identityManager: identityManager)
        let result = processor.process("/slap")
        switch result {
        case .error(let message):
            #expect(message == "usage: /slap <nickname>")
        default:
            Issue.record("Expected error result for usage message")
        }
    }
}
