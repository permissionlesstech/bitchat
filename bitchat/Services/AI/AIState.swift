//
// AIState.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import SwiftUI

// MARK: - AI Consent Dialog Model

struct AIConsentPrompt: Identifiable {
    let id = UUID()
    let privacyLevel: AIPrivacyLevel
    let title: String
    let message: String
    let pendingPrompt: String
}

// MARK: - AIState
// Owns all AI-related state and logic. Completely decoupled from ChatViewModel.
// Views observe this object for AI status, errors, and consent prompts.
// Inference results are returned to the caller, not appended internally —
// the caller decides where messages go.

final class AIState: ObservableObject {

    @Published var isAIResponding: Bool = false
    @Published var consentPrompt: AIConsentPrompt? = nil
    @Published var aiError: String? = nil

    let router: AIProviderRouter
    let localProvider: MLXAIProvider

    init(router: AIProviderRouter, localProvider: MLXAIProvider) {
        self.router = router
        self.localProvider = localProvider
    }

    // MARK: - Ask AI
    // Returns a BitchatMessage on success, nil on consent-needed or error.
    // The caller is responsible for appending the message wherever it belongs.

    @MainActor
    func askAI(_ prompt: String) async -> BitchatMessage? {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        isAIResponding = true
        defer { isAIResponding = false }

        do {
            let response = try await router.respond(to: prompt)
            aiError = nil
            return BitchatMessage(
                sender: response.providerDisplayName,
                content: response.text,
                timestamp: Date(),
                isRelay: false,
                isPrivate: false
            )

        } catch AIProviderError.consentRequired(let level) {
            consentPrompt = AIConsentPrompt(
                privacyLevel: level,
                title: "Send message off-device?",
                message: "No local AI model is available. Your message can be sent "
                    + "through the Nostr network to a remote AI service. No account "
                    + "or personal information is required, but the content of your "
                    + "message will leave this device.\n\n"
                    + "You can download a local model in Settings to keep everything "
                    + "on-device.",
                pendingPrompt: prompt
            )
            return nil

        } catch {
            aiError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Consent Response
    // Returns a BitchatMessage if consent was granted and retry succeeded.

    @MainActor
    func handleConsentResponse(granted: Bool) async -> BitchatMessage? {
        guard let prompt = consentPrompt else { return nil }
        consentPrompt = nil
        if granted {
            router.setUserConsent(for: .bridged, granted: true)
            return await askAI(prompt.pendingPrompt)
        }
        return nil
    }
}
