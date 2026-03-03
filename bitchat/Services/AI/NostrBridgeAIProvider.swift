import Foundation

// MARK: - NostrBridgeAIProvider
// Stub implementation of AIProvider for Nostr-bridged remote inference.
// This exists so the router, settings UI, and consent flow all work end-to-end
// today. When the real implementation lands, it replaces this file and nothing
// else in the system needs to change.
//
// Privacy level is .bridged because the user's prompt will leave their device,
// travel through Nostr relays, and reach a remote inference server. No account
// or personal info is required (Nostr events are pseudonymous), but the prompt
// content does leave the device, and the user must consent first.

final class NostrBridgeAIProvider: AIProvider {

    let id = "nostr-bridge"
    let displayName = "Nostr AI Bridge"
    let privacyLevel: AIPrivacyLevel = .bridged

    // False until the real implementation is complete. The router skips this
    // provider entirely, and settings shows it as "coming soon".
    var isAvailable: Bool { false }

    var requiresSetup: Bool { false }

    var setupDescription: String {
        "The Nostr AI Bridge sends your message through the Nostr network to a remote AI service. No account is needed. Coming soon."
    }

    private let relayURLs: [String]

    init(relayURLs: [String]) {
        self.relayURLs = relayURLs
    }

    func respond(to prompt: String) async throws -> String {
        // FUTURE IMPLEMENTATION PLAN (NIP-90 Data Vending Machines)
        //
        // 1. PUBLISH JOB REQUEST
        //    Create a kind 5050 event (NIP-90 text generation job) with:
        //    - "i" tag containing the user's prompt
        //    - "param" tags for model preferences (optional)
        //    - "bid" tag with a Cashu token or Lightning invoice offer
        //    Sign with the app's ephemeral Nostr keypair (not the user's
        //    identity key) and publish to each relay in self.relayURLs.
        //
        // 2. WAIT FOR JOB RESULT
        //    Subscribe to kind 6050 events (job results) referencing our
        //    request event ID. Timeout after 30 seconds and fall back to
        //    the local provider via the router.
        //
        // 3. PAYMENT VERIFICATION
        //    The DVM may respond with a kind 7000 event requesting payment
        //    before delivering the result. Handle:
        //    - Cashu: redeem a token from the user's ecash balance
        //    - Lightning: pay a BOLT11 invoice via the user's wallet
        //    After payment, the DVM publishes the actual kind 6050 result.
        //
        // 4. RESPONSE EXTRACTION
        //    Parse the "content" field of the 6050 event as the AI response.
        //    Verify the event signature to confirm it came from a known DVM.
        //    Return the content string to the caller.
        //
        // Privacy considerations:
        //   - Prompt is encrypted to the DVM's pubkey (NIP-04 or NIP-44)
        //   - Relay operators see metadata but not content
        //   - No account, email, or identity is transmitted
        //   - The ephemeral keypair is rotated periodically
        //
        // The relay URLs come from AIProviderConfig.bridgeRelays, set at
        // the composition root. Swapping relays is a config change only.

        throw AIProviderError.noProviderAvailable
    }
}
