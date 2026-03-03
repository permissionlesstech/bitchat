import Foundation
import Combine
import SwiftUI

// MARK: - AIProviderRouter
// The router is the only object that knows about multiple providers. It implements
// the same fallback philosophy as bitchat's mesh networking: prefer the best
// available option, fall back gracefully, and always tell the user what happened.
//
// Provider selection priority:
//   1. Bridged provider (better quality) -- only if internet is available
//      AND the user has explicitly consented to data leaving the device.
//   2. Local provider -- works offline, no consent needed, lower quality.
//   3. Neither -- surface a clear explanation, never fail silently.

final class AIProviderRouter: ObservableObject {

    // MARK: - Published State

    @Published private(set) var currentProvider: AIProvider?
    @Published private(set) var unavailabilityReason: String?

    // MARK: - Consent Keys

    private static let consentKeyPrefix = "ai.consent."

    // MARK: - Internal State

    private let providers: [AIProvider]
    private let userDefaults: UserDefaults

    // MARK: - Initialization

    init(providers: [AIProvider], userDefaults: UserDefaults = .standard) {
        self.providers = providers
        self.userDefaults = userDefaults
        self.currentProvider = nil
        self.unavailabilityReason = nil
        resolveCurrentProvider()
    }

    // MARK: - Consent Management

    func setUserConsent(for privacyLevel: AIPrivacyLevel, granted: Bool) {
        let key = Self.consentKeyPrefix + privacyLevel.rawValue
        userDefaults.set(granted, forKey: key)
        resolveCurrentProvider()
    }

    func hasUserConsent(for privacyLevel: AIPrivacyLevel) -> Bool {
        // Local processing never needs consent -- this is a design invariant.
        if privacyLevel == .local { return true }
        let key = Self.consentKeyPrefix + privacyLevel.rawValue
        return userDefaults.bool(forKey: key)
    }

    // MARK: - Provider Resolution

    func resolveCurrentProvider() {
        // Phase 1: Find a provider that is fully ready right now.
        for provider in providers {
            let consentOK = hasUserConsent(for: provider.privacyLevel)
            if provider.isAvailable && !provider.requiresSetup && consentOK {
                currentProvider = provider
                unavailabilityReason = nil
                return
            }
        }

        // Phase 2: No provider is ready. Build an actionable explanation.
        currentProvider = nil

        if let setupNeeded = providers.first(where: { $0.isAvailable && $0.requiresSetup }) {
            unavailabilityReason = setupNeeded.setupDescription
            return
        }

        if providers.first(where: {
            $0.isAvailable && !$0.requiresSetup && $0.privacyLevel == .bridged
        }) != nil {
            unavailabilityReason = "A bridged AI provider is available but requires your permission to send data off-device."
            return
        }

        if providers.isEmpty {
            unavailabilityReason = "No AI providers are configured."
        } else {
            unavailabilityReason = "No AI provider is available on this device. Download a local model in Settings, or connect to the internet."
        }
    }

    // MARK: - Respond

    func respond(to prompt: String) async throws -> AIResponse {
        await MainActor.run { resolveCurrentProvider() }

        guard let provider = currentProvider else {
            // Check if a bridged provider only needs consent, so the ViewModel
            // can show a consent dialog instead of a generic error.
            if providers.first(where: {
                $0.isAvailable && !$0.requiresSetup && $0.privacyLevel == .bridged
                && !hasUserConsent(for: .bridged)
            }) != nil {
                throw AIProviderError.consentRequired(privacyLevel: .bridged)
            }
            throw AIProviderError.noProviderAvailable
        }

        do {
            let text = try await provider.respond(to: prompt)
            return AIResponse(
                text: text,
                providerID: provider.id,
                providerDisplayName: provider.displayName,
                privacyLevel: provider.privacyLevel
            )
        } catch {
            if error is AIProviderError { throw error }
            throw AIProviderError.inferenceError(underlying: error)
        }
    }

    // MARK: - Provider Access for UI

    var allProviders: [AIProvider] { providers }
    var localProviders: [AIProvider] { providers.filter { $0.privacyLevel == .local } }
    var bridgedProviders: [AIProvider] { providers.filter { $0.privacyLevel == .bridged } }
}
