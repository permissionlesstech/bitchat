//
// ChatViewModel+AI.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

// MARK: - ChatViewModel AI Extension
// Exposes a shared AIState instance through a lightweight extension.
// No stored properties are added to ChatViewModel — the AI layer
// owns its own state via AIState, keeping the two fully decoupled.

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

    // MARK: - Shared AI State

    private static let _sharedAIState: AIState = {
        let localProvider = MLXAIProvider(config: aiConfig)
        let bridgeProvider = NostrBridgeAIProvider(relayURLs: aiConfig.bridgeRelays)
        let router = AIProviderRouter(providers: [bridgeProvider, localProvider])
        return AIState(router: router, localProvider: localProvider)
    }()

    var aiState: AIState {
        Self._sharedAIState
    }
}
