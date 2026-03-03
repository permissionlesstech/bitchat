import XCTest
@testable import bitchat

final class MockAIProvider: AIProvider {
    let id: String
    let displayName: String
    var isAvailable: Bool
    var requiresSetup: Bool = false
    let setupDescription = "Mock setup"
    let privacyLevel: AIPrivacyLevel
    var responseText = "mock response"

    init(id: String, privacyLevel: AIPrivacyLevel, available: Bool = true) {
        self.id = id
        self.displayName = "Mock \(id)"
        self.isAvailable = available
        self.privacyLevel = privacyLevel
    }

    func respond(to prompt: String) async throws -> String {
        responseText
    }
}

final class AIProviderRouterTests: XCTestCase {
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "test.ai.router")!
        testDefaults.removePersistentDomain(forName: "test.ai.router")
    }

    func testLocalSelectedWhenBridgeNotConsented() async throws {
        let bridge = MockAIProvider(id: "bridge", privacyLevel: .bridged)
        let local = MockAIProvider(id: "local", privacyLevel: .local)
        local.responseText = "local answer"
        let router = AIProviderRouter(providers: [bridge, local], userDefaults: testDefaults)
        let response = try await router.respond(to: "test")
        XCTAssertEqual(response.providerID, "local")
        XCTAssertEqual(response.privacyLevel, .local)
    }

    func testBridgeSelectedAfterConsent() async throws {
        let bridge = MockAIProvider(id: "bridge", privacyLevel: .bridged)
        bridge.responseText = "bridge answer"
        let local = MockAIProvider(id: "local", privacyLevel: .local)
        let router = AIProviderRouter(providers: [bridge, local], userDefaults: testDefaults)
        router.setUserConsent(for: .bridged, granted: true)
        let response = try await router.respond(to: "test")
        XCTAssertEqual(response.providerID, "bridge")
    }

    func testConsentRequiredError() async {
        let bridge = MockAIProvider(id: "bridge", privacyLevel: .bridged)
        let local = MockAIProvider(id: "local", privacyLevel: .local, available: false)
        let router = AIProviderRouter(providers: [bridge, local], userDefaults: testDefaults)
        do {
            _ = try await router.respond(to: "test")
            XCTFail("Should throw consentRequired")
        } catch AIProviderError.consentRequired(let level) {
            XCTAssertEqual(level, .bridged)
        } catch { XCTFail("Wrong error") }
    }

    func testRevokeConsentFallsBack() async throws {
        let bridge = MockAIProvider(id: "bridge", privacyLevel: .bridged)
        let local = MockAIProvider(id: "local", privacyLevel: .local)
        let router = AIProviderRouter(providers: [bridge, local], userDefaults: testDefaults)
        router.setUserConsent(for: .bridged, granted: true)
        XCTAssertEqual(router.currentProvider?.id, "bridge")
        router.setUserConsent(for: .bridged, granted: false)
        XCTAssertEqual(router.currentProvider?.id, "local")
    }

    func testLocalNeverRequiresConsent() async throws {
        let local = MockAIProvider(id: "local", privacyLevel: .local)
        let router = AIProviderRouter(providers: [local], userDefaults: testDefaults)
        XCTAssertTrue(router.hasUserConsent(for: .local))
    }
}
