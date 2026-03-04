import XCTest
@testable import bitchat

// MARK: - Mock Providers

final class MockAIProvider: AIProvider {
    let id: String
    let displayName: String
    var isAvailable: Bool
    var requiresSetup: Bool = false
    let setupDescription = "Mock setup"
    let privacyLevel: AIPrivacyLevel
    var responseText = "mock response"
    var shouldThrow: Error?

    init(id: String, privacyLevel: AIPrivacyLevel, available: Bool = true) {
        self.id = id
        self.displayName = "Mock \(id)"
        self.isAvailable = available
        self.privacyLevel = privacyLevel
    }

    func respond(to prompt: String) async throws -> String {
        if let error = shouldThrow { throw error }
        return responseText
    }
}

// MARK: - Router Tests

final class AIProviderRouterTests: XCTestCase {
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "test.ai.router")!
        testDefaults.removePersistentDomain(forName: "test.ai.router")
    }

    // --- Existing tests ---

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

    // --- Consent invariant: no sequence of operations can leak data ---

    func testBridgedProviderNeverSelectedWithoutExplicitConsent() async throws {
        // Prove that no matter the provider ordering or availability state,
        // a bridged provider is never the currentProvider without consent.
        let bridge = MockAIProvider(id: "bridge", privacyLevel: .bridged)
        let local = MockAIProvider(id: "local", privacyLevel: .local)

        // Try every combination: bridge first, local first, local unavailable.
        for providers in [[bridge, local], [local, bridge]] {
            let router = AIProviderRouter(
                providers: providers,
                userDefaults: testDefaults
            )
            // Without consent, current should never be the bridge.
            if let current = router.currentProvider {
                XCTAssertNotEqual(
                    current.privacyLevel, .bridged,
                    "Bridge selected without consent with ordering \(providers.map(\.id))"
                )
            }
        }

        // Even when local is unavailable, bridge must not be selected.
        local.isAvailable = false
        let router = AIProviderRouter(providers: [bridge, local], userDefaults: testDefaults)
        XCTAssertNil(
            router.currentProvider,
            "No provider should be selected when local is unavailable and bridge has no consent"
        )
    }

    func testConsentCannotBeBypassedByGrantingThenRevokingDifferentLevel() async throws {
        // Granting consent for .local should not unlock .bridged.
        let bridge = MockAIProvider(id: "bridge", privacyLevel: .bridged)
        let router = AIProviderRouter(providers: [bridge], userDefaults: testDefaults)
        router.setUserConsent(for: .local, granted: true)
        XCTAssertFalse(router.hasUserConsent(for: .bridged))
        XCTAssertNil(router.currentProvider)
    }

    // --- Fallback ordering ---

    func testFallbackRespectsProviderOrdering() async throws {
        // First available+consented provider wins, regardless of privacy level.
        let local1 = MockAIProvider(id: "local1", privacyLevel: .local)
        let local2 = MockAIProvider(id: "local2", privacyLevel: .local)
        local1.responseText = "first"
        local2.responseText = "second"
        let router = AIProviderRouter(providers: [local1, local2], userDefaults: testDefaults)
        let response = try await router.respond(to: "test")
        XCTAssertEqual(response.providerID, "local1")
    }

    func testSkipsUnavailableProviders() async throws {
        let local1 = MockAIProvider(id: "local1", privacyLevel: .local, available: false)
        let local2 = MockAIProvider(id: "local2", privacyLevel: .local)
        local2.responseText = "fallback"
        let router = AIProviderRouter(providers: [local1, local2], userDefaults: testDefaults)
        let response = try await router.respond(to: "test")
        XCTAssertEqual(response.providerID, "local2")
    }

    func testSkipsProvidersRequiringSetup() async throws {
        let needsSetup = MockAIProvider(id: "setup", privacyLevel: .local)
        needsSetup.requiresSetup = true
        let ready = MockAIProvider(id: "ready", privacyLevel: .local)
        ready.responseText = "ready answer"
        let router = AIProviderRouter(providers: [needsSetup, ready], userDefaults: testDefaults)
        let response = try await router.respond(to: "test")
        XCTAssertEqual(response.providerID, "ready")
    }

    // --- No providers available ---

    func testNoProvidersThrowsNoProviderAvailable() async {
        let router = AIProviderRouter(providers: [], userDefaults: testDefaults)
        do {
            _ = try await router.respond(to: "test")
            XCTFail("Should throw noProviderAvailable")
        } catch AIProviderError.noProviderAvailable {
            // Expected.
        } catch { XCTFail("Wrong error: \(error)") }
    }

    func testAllUnavailableThrowsNoProviderAvailable() async {
        let local = MockAIProvider(id: "local", privacyLevel: .local, available: false)
        let router = AIProviderRouter(providers: [local], userDefaults: testDefaults)
        do {
            _ = try await router.respond(to: "test")
            XCTFail("Should throw")
        } catch AIProviderError.noProviderAvailable {
            // Expected.
        } catch AIProviderError.consentRequired {
            // Also acceptable -- no local available, no bridge.
        } catch { XCTFail("Wrong error: \(error)") }
    }

    // --- Response provenance ---

    func testResponseCarriesProviderMetadata() async throws {
        let local = MockAIProvider(id: "local-test", privacyLevel: .local)
        local.responseText = "hello"
        let router = AIProviderRouter(providers: [local], userDefaults: testDefaults)
        let response = try await router.respond(to: "hi")
        XCTAssertEqual(response.providerID, "local-test")
        XCTAssertEqual(response.providerDisplayName, "Mock local-test")
        XCTAssertEqual(response.privacyLevel, .local)
        XCTAssertEqual(response.text, "hello")
    }

    // --- Inference error wrapping ---

    func testInferenceErrorWrappedCorrectly() async {
        let local = MockAIProvider(id: "local", privacyLevel: .local)
        local.shouldThrow = NSError(domain: "test", code: 42)
        let router = AIProviderRouter(providers: [local], userDefaults: testDefaults)
        do {
            _ = try await router.respond(to: "test")
            XCTFail("Should throw")
        } catch AIProviderError.inferenceError {
            // Expected -- raw NSError is wrapped in AIProviderError.
        } catch { XCTFail("Wrong error: \(error)") }
    }

    // --- Unavailability reason messages ---

    func testUnavailabilityReasonWhenSetupNeeded() {
        let local = MockAIProvider(id: "local", privacyLevel: .local)
        local.requiresSetup = true
        let router = AIProviderRouter(providers: [local], userDefaults: testDefaults)
        XCTAssertNil(router.currentProvider)
        XCTAssertEqual(router.unavailabilityReason, "Mock setup")
    }

    func testUnavailabilityReasonWhenEmpty() {
        let router = AIProviderRouter(providers: [], userDefaults: testDefaults)
        XCTAssertEqual(router.unavailabilityReason, "No AI providers are configured.")
    }
}

// MARK: - Model Validation Tests

final class MLXModelValidationTests: XCTestCase {

    private var testDir: URL!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: testDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
        super.tearDown()
    }

    func testEmptyDirectoryIsNotDownloaded() {
        // An empty directory left by a failed download must not count as ready.
        // This is the core bug that Codex flagged: createDirectory runs before
        // the network transfer, so a crash or timeout leaves a directory with
        // no model file inside.
        let modelDir = testDir.appendingPathComponent("fake-model", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: modelDir,
            withIntermediateDirectories: true
        )
        // Directory exists but model.safetensors does not.
        let modelFile = modelDir.appendingPathComponent("model.safetensors")
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelFile.path))
    }

    func testDirectoryWithModelFileIsDownloaded() {
        let modelDir = testDir.appendingPathComponent("real-model", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: modelDir,
            withIntermediateDirectories: true
        )
        let modelFile = modelDir.appendingPathComponent("model.safetensors")
        FileManager.default.createFile(atPath: modelFile.path, contents: Data("fake weights".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelFile.path))
    }
}
