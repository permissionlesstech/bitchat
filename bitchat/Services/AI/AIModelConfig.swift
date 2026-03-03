import Foundation

// MARK: - AIModelConfig
// Represents a single downloadable model. Every field that would otherwise be a
// hardcoded constant lives here instead: the URL, the size, the RAM floor, the
// quantization label. A test can construct one of these pointing at a local file.
// A future settings screen can let power users paste their own Hugging Face URL.
// Nothing in the architecture needs to change for either case.

struct AIModelConfig: Identifiable, Codable, Equatable {
    let id: String                    // Stable identifier, e.g. "smollm2-360m-4bit"
    let displayName: String           // Shown in UI: "SmolLM2 360M (4-bit)"
    let sourceURL: URL                // Full URL to the model repository or archive
    let diskSizeBytes: Int64          // Shown to the user before download begins
    let minimumRAMBytes: Int64        // Device must report at least this much available RAM
    let supportedLanguages: [String]  // BCP-47 codes, e.g. ["en", "es", "fr"]
    let quantization: String          // e.g. "4-bit", displayed in settings for transparency

    // Convenience: human-readable disk size for UI display.
    // Computed rather than stored so it always reflects diskSizeBytes accurately.
    var formattedDiskSize: String {
        ByteCountFormatter.string(fromByteCount: diskSizeBytes, countStyle: .file)
    }
}

// MARK: - AIProviderConfig
// The top-level configuration that wires together everything the AI system needs.
// Constructed once at the app's composition root (BitchatApp.swift) and injected
// downward. Every provider, router, and view receives its decisions from here.

struct AIProviderConfig: Codable, Equatable {
    // Ordered by preference: the local provider tries each model from first to last,
    // selecting the first one the device can support. Put the best model first and
    // the smallest fallback last.
    let localModels: [AIModelConfig]

    // Nostr relay URLs for the bridge provider. These follow the same relay
    // architecture bitchat already uses for message transport — the AI bridge
    // is just another kind of event flowing through the same infrastructure.
    let bridgeRelays: [String]

    // Maximum tokens to generate per response. Defaults are intentionally
    // conservative to prevent runaway generation on constrained devices.
    let maxGenerationTokens: Int

    // Temperature for local inference. Bridged providers manage their own.
    let localTemperature: Float

    init(
        localModels: [AIModelConfig],
        bridgeRelays: [String] = [],
        maxGenerationTokens: Int = 512,
        localTemperature: Float = 0.7
    ) {
        self.localModels = localModels
        self.bridgeRelays = bridgeRelays
        self.maxGenerationTokens = maxGenerationTokens
        self.localTemperature = localTemperature
    }
}
