//
// MorpheusAIService.swift
// bitchat
//
// Morpheus AI Gateway integration for BitChat
// This is free and unencumbered software released into the public domain.
//

import Foundation

/// Configuration for Morpheus AI service
struct MorpheusAIConfig {
    /// Base URL for the Morpheus API
    static let baseURL = "https://api.mor.org/api/v1"

    /// Default model to use for chat completions
    static var defaultModel = "glm-4.7:web"

    /// API key for authentication (should be set from secure storage)
    static var apiKey: String?

    /// Maximum tokens for response
    static let maxTokens = 1024

    /// Temperature for response randomness (0.0 - 1.0)
    static let temperature = 0.7

    /// Request timeout in seconds
    static let timeoutSeconds: TimeInterval = 60

    /// System prompt for the AI assistant
    static let systemPrompt = """
        You are MorpheusChat, a helpful AI assistant integrated into BitChat - a decentralized \
        peer-to-peer messaging app. Keep responses concise and friendly, suitable for chat. \
        You're powered by the Morpheus decentralized AI network.
        """
}

/// Countries where Morpheus AI is enabled
enum AllowedCountry: String, CaseIterable {
    case usa = "US"
    case bulgaria = "BG"
    case iran = "IR"

    /// Check if a coordinate falls within this country's approximate bounds
    func contains(latitude: Double, longitude: Double) -> Bool {
        switch self {
        case .usa:
            // Continental US approximate bounds
            return latitude >= 24.5 && latitude <= 49.5 &&
                   longitude >= -125.0 && longitude <= -66.5
        case .bulgaria:
            // Bulgaria approximate bounds
            return latitude >= 41.2 && latitude <= 44.2 &&
                   longitude >= 22.3 && longitude <= 28.6
        case .iran:
            // Iran approximate bounds
            return latitude >= 25.0 && latitude <= 40.0 &&
                   longitude >= 44.0 && longitude <= 63.5
        }
    }
}

/// Errors that can occur during Morpheus AI operations
enum MorpheusAIError: Error, LocalizedError {
    case noAPIKey
    case networkError(Error)
    case invalidResponse
    case rateLimited
    case serverError(String)
    case countryRestricted
    case encodingError

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "Morpheus API key not configured"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from Morpheus API"
        case .rateLimited:
            return "Rate limited - please wait before trying again"
        case .serverError(let message):
            return "Server error: \(message)"
        case .countryRestricted:
            return "MorpheusChat is not available in your region"
        case .encodingError:
            return "Failed to encode request"
        }
    }
}

/// Response from Morpheus chat completion API
struct MorpheusChatResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let role: String
            let content: String
        }
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    let id: String?
    let choices: [Choice]
    let model: String?

    var content: String? {
        choices.first?.message.content
    }
}

/// Request body for Morpheus chat completion API
struct MorpheusChatRequest: Codable {
    struct Message: Codable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let maxTokens: Int?
    let temperature: Double?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case maxTokens = "max_tokens"
        case temperature
    }
}

/// Service for interacting with the Morpheus AI Gateway
final class MorpheusAIService {
    static let shared = MorpheusAIService()

    private let session: URLSession
    private var conversationHistory: [MorpheusChatRequest.Message] = []
    private let maxHistoryMessages = 10 // Keep last N messages for context

    // Keychain storage
    private let keychainService = "morpheus.ai"
    private let apiKeyKey = "morpheus_api_key"
    private let modelKey = "morpheus_model"

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = MorpheusAIConfig.timeoutSeconds
        config.timeoutIntervalForResource = MorpheusAIConfig.timeoutSeconds * 2
        self.session = URLSession(configuration: config)

        // Load stored API key and model from keychain
        loadStoredSettings()
    }

    /// Load stored settings from keychain
    private func loadStoredSettings() {
        let keychain = KeychainManager()

        // Load API key
        if let apiKeyData = keychain.load(key: apiKeyKey, service: keychainService),
           let apiKey = String(data: apiKeyData, encoding: .utf8) {
            MorpheusAIConfig.apiKey = apiKey
        }

        // Load preferred model
        if let modelData = keychain.load(key: modelKey, service: keychainService),
           let model = String(data: modelData, encoding: .utf8) {
            MorpheusAIConfig.defaultModel = model
        }
    }

    /// Save API key to keychain
    private func saveAPIKeyToKeychain(_ key: String) {
        let keychain = KeychainManager()
        if let data = key.data(using: .utf8) {
            keychain.save(key: apiKeyKey, data: data, service: keychainService, accessible: kSecAttrAccessibleWhenUnlocked)
        }
    }

    /// Save model preference to keychain
    private func saveModelToKeychain(_ model: String) {
        let keychain = KeychainManager()
        if let data = model.data(using: .utf8) {
            keychain.save(key: modelKey, data: data, service: keychainService, accessible: kSecAttrAccessibleWhenUnlocked)
        }
    }

    /// Check if the user's location allows access to Morpheus AI
    /// - Parameter geohash: The user's current geohash
    /// - Returns: Always true (country restriction removed)
    func isLocationAllowed(geohash: String) -> Bool {
        // Country restriction removed - all locations allowed
        return true
    }

    /// Send a message to Morpheus AI and get a response
    /// - Parameters:
    ///   - message: The user's message
    ///   - geohash: The user's current geohash for location verification
    /// - Returns: The AI's response
    func sendMessage(_ message: String, geohash: String) async throws -> String {
        return try await sendMessageWithHistory(message, history: [], geohash: geohash)
    }

    /// Send a message with custom conversation history (for multi-user bot scenarios)
    /// - Parameters:
    ///   - message: The user's message
    ///   - history: Previous conversation messages as (role, content) tuples
    ///   - geohash: The user's current geohash for location verification
    /// - Returns: The AI's response
    func sendMessageWithHistory(_ message: String, history: [(role: String, content: String)], geohash: String) async throws -> String {
        // Check location restriction only if geohash is provided
        if !geohash.isEmpty && !isLocationAllowed(geohash: geohash) {
            throw MorpheusAIError.countryRestricted
        }

        // Check API key
        guard let apiKey = MorpheusAIConfig.apiKey, !apiKey.isEmpty else {
            throw MorpheusAIError.noAPIKey
        }

        // Build messages array with provided history
        var messages: [MorpheusChatRequest.Message] = [
            MorpheusChatRequest.Message(role: "system", content: MorpheusAIConfig.systemPrompt)
        ]

        // Add provided history
        for (role, content) in history {
            messages.append(MorpheusChatRequest.Message(role: role, content: content))
        }

        // Add current message
        messages.append(MorpheusChatRequest.Message(role: "user", content: message))

        // Create request body
        let requestBody = MorpheusChatRequest(
            model: MorpheusAIConfig.defaultModel,
            messages: messages,
            maxTokens: MorpheusAIConfig.maxTokens,
            temperature: MorpheusAIConfig.temperature,
            stream: false
        )

        // Encode request
        guard let bodyData = try? JSONEncoder().encode(requestBody) else {
            throw MorpheusAIError.encodingError
        }

        // Build URL request
        guard let url = URL(string: "\(MorpheusAIConfig.baseURL)/chat/completions") else {
            throw MorpheusAIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        // Send request
        let (data, response) = try await session.data(for: request)

        // Check response status
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200...299:
                break // Success
            case 429:
                throw MorpheusAIError.rateLimited
            default:
                if let errorMessage = String(data: data, encoding: .utf8) {
                    throw MorpheusAIError.serverError(errorMessage)
                }
                throw MorpheusAIError.invalidResponse
            }
        }

        // Decode response
        let decoder = JSONDecoder()
        guard let chatResponse = try? decoder.decode(MorpheusChatResponse.self, from: data),
              let content = chatResponse.content else {
            throw MorpheusAIError.invalidResponse
        }

        return content
    }

    /// Clear conversation history
    func clearHistory() {
        conversationHistory.removeAll()
    }

    /// Set the API key (also persists to keychain)
    func setAPIKey(_ key: String) {
        MorpheusAIConfig.apiKey = key
        saveAPIKeyToKeychain(key)
    }

    /// Set the default model (also persists to keychain)
    func setModel(_ model: String) {
        MorpheusAIConfig.defaultModel = model
        saveModelToKeychain(model)
    }

    /// Check if API key is configured
    var hasAPIKey: Bool {
        guard let key = MorpheusAIConfig.apiKey else { return false }
        return !key.isEmpty
    }

    /// Get list of available models
    func fetchAvailableModels() async throws -> [String] {
        guard let apiKey = MorpheusAIConfig.apiKey, !apiKey.isEmpty else {
            throw MorpheusAIError.noAPIKey
        }

        guard let url = URL(string: "\(MorpheusAIConfig.baseURL)/models") else {
            throw MorpheusAIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.data(for: request)

        struct ModelsResponse: Codable {
            struct Model: Codable {
                let id: String
                let modelType: String?
            }
            let data: [Model]
        }

        let decoder = JSONDecoder()
        guard let modelsResponse = try? decoder.decode(ModelsResponse.self, from: data) else {
            throw MorpheusAIError.invalidResponse
        }

        // Return only LLM models
        return modelsResponse.data
            .filter { $0.modelType == "LLM" }
            .map { $0.id }
    }
}
