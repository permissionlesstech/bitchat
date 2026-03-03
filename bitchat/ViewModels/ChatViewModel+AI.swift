//
// ChatViewModel+AI.swift
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

// MARK: - ChatViewModel AI Extension
// Adds AI capabilities to the existing ChatViewModel without modifying its
// core init or breaking any existing functionality. The AI router is a static
// singleton so we avoid changing the ViewModel's initializer signature.

extension ChatViewModel {

    // MARK: - Configuration

    static let aiConfig = AIProviderConfig(
        localModels: [
            AIModelConfig(
                id: "smollm2-1.7b-4bit",
                displayName: "SmolLM2 1.7B (4-bit)",
                sourceURL: URL(string: "https://huggingface.co/mlx-community/SmolLM2-1.7B-Instruct-4bit")!,
                diskSizeBytes: 950_000_000,
                minimumRAMBytes: 3_000_000_000,
                supportedLanguages: ["en"],
                quantization: "4-bit"
            ),
            AIModelConfig(
                id: "smollm2-360m-4bit",
                displayName: "SmolLM2 360M (4-bit)",
                sourceURL: URL(string: "https://huggingface.co/mlx-community/SmolLM2-360M-Instruct-4bit")!,
                diskSizeBytes: 245_000_000,
                minimumRAMBytes: 1_500_000_000,
                supportedLanguages: ["en"],
                quantization: "4-bit"
            ),
        ],
        bridgeRelays: [
            "wss://relay.damus.io",
            "wss://nos.lol",
        ]
    )

    // MARK: - Shared Router

    private static let _sharedRouter: AIProviderRouter = {
        let localProvider = MLXAIProvider(config: aiConfig)
        let bridgeProvider = NostrBridgeAIProvider(relayURLs: aiConfig.bridgeRelays)
        return AIProviderRouter(providers: [bridgeProvider, localProvider])
    }()

    var aiRouter: AIProviderRouter {
        Self._sharedRouter
    }

    // MARK: - Ask AI

    @MainActor
    func askAI(_ prompt: String) async -> (consentNeeded: AIConsentPrompt?, error: String?) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, nil)
        }

        do {
            let response = try await aiRouter.respond(to: prompt)

            let aiMessage = BitchatMessage(
                sender: response.providerDisplayName,
                content: response.text,
                timestamp: Date(),
                isRelay: false,
                isPrivate: false
            )

            messages.append(aiMessage)
            return (nil, nil)

        } catch AIProviderError.consentRequired(let level) {
            let consent = AIConsentPrompt(
                privacyLevel: level,
                title: "Send message off-device?",
                message: "No local AI model is available. Your message can be sent through the Nostr network to a remote AI service. No account or personal information is required, but the content of your message will leave this device.\n\nYou can download a local model in Settings to keep everything on-device.",
                pendingPrompt: prompt
            )
            return (consent, nil)

        } catch {
            return (nil, error.localizedDescription)
        }
    }

    // MARK: - Consent Response

    @MainActor
    func handleAIConsentResponse(granted: Bool, pendingPrompt: String) async -> (consentNeeded: AIConsentPrompt?, error: String?) {
        if granted {
            aiRouter.setUserConsent(for: .bridged, granted: true)
            return await askAI(pendingPrompt)
        }
        return (nil, nil)
    }
}
