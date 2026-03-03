import Foundation

// MARK: - AIPrivacyLevel
// This enum exists because bitchat's users chose the app specifically for privacy.
// The distinction between local and bridged is not cosmetic -- it determines whether
// the router can proceed silently or must obtain explicit consent first.

enum AIPrivacyLevel: String, Codable, Equatable {
    case local      // All processing on-device. Nothing leaves the phone.
    case bridged    // Request leaves device via Nostr to remote inference.
}

// MARK: - AIProvider Protocol
// Every backend -- local MLX, Nostr bridge, a future CoreML provider, a test mock --
// conforms to this single protocol. ChatViewModel never imports or references any
// concrete provider type. This is dependency inversion: the high-level policy (chat)
// depends on this abstraction, and the low-level details (MLX, Nostr) also depend
// on this abstraction. Neither knows about the other.

protocol AIProvider {
    var id: String { get }
    var displayName: String { get }

    // True when the provider could theoretically work on this device.
    // For local: device has enough RAM for at least one configured model.
    // For bridge: app has relay URLs configured.
    // Does NOT mean "ready to respond right now" -- see requiresSetup.
    var isAvailable: Bool { get }

    // True when a one-time action is needed before the provider can respond.
    // For local: the model has not been downloaded yet.
    // For bridge: stub returns false (no setup needed beyond consent).
    var requiresSetup: Bool { get }

    // Human-readable explanation of what setup involves, shown in UI.
    var setupDescription: String { get }

    // Drives the consent gate in the router. Local providers never trigger it.
    // Bridged providers always require explicit user acknowledgement.
    var privacyLevel: AIPrivacyLevel { get }

    // Single entry point for inference. Implementations handle all internal
    // complexity (loading, tokenization, generation, cleanup) behind this call.
    func respond(to prompt: String) async throws -> String
}

// MARK: - AIResponse
// Wraps a provider's text with provenance metadata so the UI can always show
// the user where their answer came from. Transparency is non-negotiable.

struct AIResponse: Equatable {
    let text: String
    let providerID: String
    let providerDisplayName: String
    let privacyLevel: AIPrivacyLevel
}

// MARK: - AIProviderError
// Typed errors so the router and UI can distinguish between "no provider exists"
// and "provider failed mid-inference" and show appropriate messaging for each.

enum AIProviderError: LocalizedError {
    case noProviderAvailable
    case providerRequiresSetup(providerName: String)
    case consentRequired(privacyLevel: AIPrivacyLevel)
    case inferenceError(underlying: Error)
    case modelNotLoaded
    case downloadFailed(underlying: Error)
    case insufficientRAM(required: Int64, available: Int64)
    case wifiRequired

    var errorDescription: String? {
        switch self {
        case .noProviderAvailable:
            return "No AI provider is available. Download a local model or connect to the internet."
        case .providerRequiresSetup(let name):
            return "\(name) needs to be set up before it can respond. Check AI settings."
        case .consentRequired:
            return "This provider sends data off-device. Your consent is required to proceed."
        case .inferenceError(let underlying):
            return "AI generation failed: \(underlying.localizedDescription)"
        case .modelNotLoaded:
            return "The AI model is not loaded. Please wait for it to initialize."
        case .downloadFailed(let underlying):
            return "Model download failed: \(underlying.localizedDescription)"
        case .insufficientRAM(let required, let available):
            let formatter = ByteCountFormatter()
            let req = formatter.string(fromByteCount: required)
            let avail = formatter.string(fromByteCount: available)
            return "This model requires \(req) RAM but only \(avail) is available."
        case .wifiRequired:
            return "Model downloads require a Wi-Fi connection to avoid cellular data usage."
        }
    }
}
