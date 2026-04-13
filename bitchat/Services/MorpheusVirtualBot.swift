//
// MorpheusVirtualBot.swift
// bitchat
//
// Manages the MorpheusAI bot that responds to @MorpheusAI mentions in public chat.
// This is a backward-compatible approach that works with standard BitChat clients.
//
// How it works:
// 1. Bridge operator runs /ai-bridge on
// 2. Users mention @MorpheusAI in public chat: "Hey @MorpheusAI what is Bitcoin?"
// 3. Bridge intercepts the mention and sends to Morpheus API
// 4. Bot responds in public chat: "MorpheusAI: Bitcoin is..."
//
// This is free and unencumbered software released into the public domain.
//

import Foundation
import Network
import Combine

/// Manages the MorpheusAI bot that responds to @mentions in public chat
@MainActor
final class MorpheusVirtualBot: ObservableObject {
    static let shared = MorpheusVirtualBot()

    // MARK: - Configuration

    /// The bot's display name (used for @mention detection)
    static let botNickname = "MorpheusAI"

    /// Pattern to detect @MorpheusAI mentions
    static let mentionPattern = "@MorpheusAI"

    // MARK: - Published State

    /// Whether the bot is currently active
    @Published private(set) var isActive = false

    /// Whether this device can act as a bridge (has internet + API key)
    @Published private(set) var canActivate = false

    /// Number of queries processed
    @Published private(set) var queriesProcessed = 0

    // MARK: - Network Monitoring

    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "morpheus.bot.network")

    // MARK: - Conversation Context (per sender)

    /// Recent messages by sender PeerID for context (keyed by PeerID to avoid nickname collisions)
    private var conversationContext: [PeerID: [(role: String, content: String)]] = [:]
    private let maxContextMessages = 6

    // MARK: - References

    weak var bleService: BLEService?
    var addSystemMessage: ((String) -> Void)?
    var getCurrentGeohash: (() -> String?)?
    /// Callback to send a private message response back to a specific peer
    var sendPrivateResponse: ((String, PeerID, String) -> Void)?  // (content, peerID, senderNickname)

    /// Prefix for private AI queries
    static let privateAIPrefix = "!ai "

    // MARK: - Lifecycle

    private init() {
        startNetworkMonitoring()
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                let hasInternet = path.status == .satisfied
                let hasAPIKey = MorpheusAIService.shared.hasAPIKey
                self?.canActivate = hasInternet && hasAPIKey
            }
        }
        networkMonitor.start(queue: monitorQueue)
    }

    // MARK: - Bot Activation

    /// Activate the bot
    func activate() -> Result<String, Error> {
        guard MorpheusAIService.shared.hasAPIKey else {
            return .failure(BotError.noAPIKey)
        }

        // Do a synchronous network check instead of relying on async monitor
        let currentPath = networkMonitor.currentPath
        let hasInternet = currentPath.status == .satisfied

        guard hasInternet else {
            return .failure(BotError.noInternet)
        }

        isActive = true
        canActivate = true // Update state to match
        return .success("MorpheusAI bot activated. Users can now mention @MorpheusAI in public chat.")
    }

    /// Deactivate the bot
    func deactivate() {
        isActive = false
        conversationContext.removeAll()
    }

    // MARK: - Message Detection

    /// Check if a public message contains a mention of @MorpheusAI
    func containsBotMention(_ content: String) -> Bool {
        return content.localizedCaseInsensitiveContains(Self.mentionPattern)
    }

    /// Extract the query from a message that mentions @MorpheusAI
    func extractQuery(from content: String) -> String {
        // Remove the @MorpheusAI mention and clean up
        var query = content
            .replacingOccurrences(of: Self.mentionPattern, with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove common prefixes like "hey", "hi", etc.
        let prefixes = ["hey", "hi", "hello", "yo", ",", ":"]
        for prefix in prefixes {
            if query.lowercased().hasPrefix(prefix) {
                query = String(query.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return query
    }

    // MARK: - Message Handling

    /// Handle a public message that might contain a bot mention
    func handlePublicMessage(
        content: String,
        senderNickname: String,
        senderPeerID: PeerID?
    ) {
        guard isActive else { return }
        guard containsBotMention(content) else { return }

        let query = extractQuery(from: content)
        guard !query.isEmpty else {
            addSystemMessage?("MorpheusAI: Please include a question after @MorpheusAI")
            return
        }

        // Get geohash for location check (optional - skip if not available)
        let geohash = getCurrentGeohash?() ?? ""

        // Only check location restriction if we have a geohash
        if !geohash.isEmpty && !MorpheusAIService.shared.isLocationAllowed(geohash: geohash) {
            addSystemMessage?("MorpheusAI: Not available in your region")
            return
        }

        // Show thinking indicator
        addSystemMessage?("MorpheusAI is thinking...")

        // Update conversation context (keyed by PeerID to avoid nickname collisions)
        if let peerID = senderPeerID {
            if conversationContext[peerID] == nil {
                conversationContext[peerID] = []
            }
            conversationContext[peerID]?.append(("user", query))

            // Trim context if needed
            if let count = conversationContext[peerID]?.count, count > maxContextMessages {
                conversationContext[peerID]?.removeFirst(count - maxContextMessages)
            }
        }

        // Process query
        Task {
            await processQuery(query, from: senderPeerID, geohash: geohash)
        }
    }

    /// Process an AI query and respond
    private func processQuery(_ query: String, from senderPeerID: PeerID?, geohash: String) async {
        do {
            let history: [(role: String, content: String)]
            if let peerID = senderPeerID {
                history = conversationContext[peerID] ?? []
            } else {
                history = []
            }
            // Use history excluding the current query (which we just added)
            let contextHistory = Array(history.dropLast())

            let response = try await MorpheusAIService.shared.sendMessageWithHistory(
                query,
                history: contextHistory,
                geohash: geohash
            )

            // Update context with response
            await MainActor.run {
                if let peerID = senderPeerID {
                    conversationContext[peerID]?.append(("assistant", response))
                }
                queriesProcessed += 1
            }

            // Send response as public message
            let formattedResponse = "MorpheusAI: \(response)"
            await MainActor.run {
                addSystemMessage?(formattedResponse)
            }

        } catch let error as MorpheusAIError {
            await MainActor.run {
                addSystemMessage?("MorpheusAI: Error - \(error.localizedDescription)")
            }
        } catch {
            await MainActor.run {
                addSystemMessage?("MorpheusAI: Sorry, something went wrong. Please try again.")
            }
        }
    }

    // MARK: - Private Message Handling

    /// Check if a private message contains an AI query
    func containsPrivateAIQuery(_ content: String) -> Bool {
        return content.lowercased().hasPrefix(Self.privateAIPrefix.lowercased()) ||
               content.lowercased().hasPrefix("!ai")
    }

    /// Extract the query from a private AI message
    func extractPrivateQuery(from content: String) -> String {
        var query = content
        // Remove !ai prefix (case insensitive)
        if query.lowercased().hasPrefix("!ai ") {
            query = String(query.dropFirst(4))
        } else if query.lowercased().hasPrefix("!ai") {
            query = String(query.dropFirst(3))
        }
        return query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Handle a private message that might contain an AI query
    func handlePrivateMessage(
        content: String,
        senderNickname: String,
        senderPeerID: PeerID
    ) {
        guard isActive else { return }
        guard containsPrivateAIQuery(content) else { return }

        let query = extractPrivateQuery(from: content)
        guard !query.isEmpty else {
            sendPrivateResponse?("Please include a question after !ai", senderPeerID, senderNickname)
            return
        }

        // Get geohash for location check (optional)
        let geohash = getCurrentGeohash?() ?? ""

        // Only check location restriction if we have a geohash
        if !geohash.isEmpty && !MorpheusAIService.shared.isLocationAllowed(geohash: geohash) {
            sendPrivateResponse?("MorpheusAI is not available in your region", senderPeerID, senderNickname)
            return
        }

        // Send thinking indicator privately
        sendPrivateResponse?("MorpheusAI is thinking...", senderPeerID, senderNickname)

        // Update conversation context (keyed by PeerID to avoid nickname collisions)
        if conversationContext[senderPeerID] == nil {
            conversationContext[senderPeerID] = []
        }
        conversationContext[senderPeerID]?.append(("user", query))

        // Trim context if needed
        if let count = conversationContext[senderPeerID]?.count, count > maxContextMessages {
            conversationContext[senderPeerID]?.removeFirst(count - maxContextMessages)
        }

        // Process query
        Task {
            await processPrivateQuery(query, from: senderPeerID, to: senderNickname, geohash: geohash)
        }
    }

    /// Process a private AI query and respond privately
    private func processPrivateQuery(_ query: String, from senderPeerID: PeerID, to senderNickname: String, geohash: String) async {
        do {
            let history = conversationContext[senderPeerID] ?? []
            let contextHistory = Array(history.dropLast())

            let response = try await MorpheusAIService.shared.sendMessageWithHistory(
                query,
                history: contextHistory,
                geohash: geohash
            )

            // Update context with response
            await MainActor.run {
                conversationContext[senderPeerID]?.append(("assistant", response))
                queriesProcessed += 1
            }

            // Send response privately
            await MainActor.run {
                sendPrivateResponse?(response, senderPeerID, senderNickname)
            }

        } catch let error as MorpheusAIError {
            await MainActor.run {
                sendPrivateResponse?("Error: \(error.localizedDescription)", senderPeerID, senderNickname)
            }
        } catch {
            await MainActor.run {
                sendPrivateResponse?("Sorry, something went wrong. Please try again.", senderPeerID, senderNickname)
            }
        }
    }

    // MARK: - Context Management

    /// Clear conversation context for a user by PeerID
    func clearContext(for peerID: PeerID) {
        conversationContext.removeValue(forKey: peerID)
    }

    /// Clear all conversation context
    func clearAllContext() {
        conversationContext.removeAll()
    }

    // MARK: - Status

    /// Get bot status information
    var statusInfo: String {
        var info = "MorpheusAI Bot Status:\n"
        info += "- Active: \(isActive ? "yes" : "no")\n"
        info += "- Can activate: \(canActivate ? "yes" : "no")\n"
        info += "- API key: \(MorpheusAIService.shared.hasAPIKey ? "configured" : "not set")\n"
        info += "- Queries processed: \(queriesProcessed)\n"
        info += "- Model: \(MorpheusAIConfig.defaultModel)\n"
        info += "\nUsage:\n"
        info += "  Public: @MorpheusAI <question>\n"
        info += "  Private: /msg @BridgeNick !ai <question>"
        return info
    }

    // MARK: - Legacy compatibility

    /// For backward compatibility with code that checks this
    var botPeerID: PeerID? { nil }

    func isMessageForBot(recipientPeerID: PeerID?) -> Bool {
        return false // Not used in @mention approach
    }
}

// MARK: - Errors

extension MorpheusVirtualBot {
    enum BotError: Error, LocalizedError {
        case noAPIKey
        case noInternet
        case notActive
        case locationRestricted

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "API key not configured. Run /ai-key <your-key> first. Get a key at https://app.mor.org"
            case .noInternet:
                return "No internet connection available"
            case .notActive:
                return "Bot is not active"
            case .locationRestricted:
                return "MorpheusAI is not available in your region"
            }
        }
    }
}
