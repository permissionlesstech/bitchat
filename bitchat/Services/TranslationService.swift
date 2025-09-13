import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
class TranslationService: ObservableObject {
    static let shared = TranslationService()
    
    private var translationCache: [String: String] = [:]
    private var translatingMessages: Set<String> = []
    
    // Platform-specific translation services
    #if os(iOS)
    @available(iOS 16.0, *)
    private lazy var mlxService: MLXTranslationService = {
        return MLXTranslationService.shared
    }()
    #endif
    
    @Published var preferredLanguage: String = "English" {
        didSet {
            UserDefaults.standard.set(preferredLanguage, forKey: "preferredTranslationLanguage")
        }
    }
    
    private init() {
        self.preferredLanguage = UserDefaults.standard.string(forKey: "preferredTranslationLanguage") ?? "English"
    }
    
    func translateText(_ text: String) async -> String {
        return await translateTo(text, targetLanguage: preferredLanguage)
    }
    
    func translateTo(_ text: String, targetLanguage: String) async -> String {
        let cleanText = extractMessageContent(from: text)
        let cacheKey = "\(cleanText)_\(targetLanguage)"
        
        if let cached = translationCache[cacheKey] {
            return replaceMessageContent(in: text, with: cached)
        }
        
        if translatingMessages.contains(cacheKey) {
            return text
        }
        
        translatingMessages.insert(cacheKey)
        defer { translatingMessages.remove(cacheKey) }
        
        do {
            let translated = try await performTranslation(cleanText, targetLanguage: targetLanguage)
            translationCache[cacheKey] = translated
            return replaceMessageContent(in: text, with: translated)
        } catch {
            print("Translation failed: \(error)")
            return text
        }
    }
    
    func isTranslated(_ text: String) -> Bool {
        let cleanText = extractMessageContent(from: text)
        let cacheKey = "\(cleanText)_\(preferredLanguage)"
        return translationCache[cacheKey] != nil
    }
    
    var isTranslationAvailable: Bool {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            return mlxService.hasEnoughStorageSpace
        } else {
            return false
        }
        #elseif os(macOS)
        return true // Ollama on macOS
        #else
        return false
        #endif
    }
    
    func getTranslationStatus() -> TranslationStatus {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            let storageInfo = mlxService.getStorageRequirements()
            return TranslationStatus(
                isAvailable: mlxService.hasEnoughStorageSpace,
                platform: "iOS (MLX)",
                requiresStorage: true,
                storageRequired: storageInfo.required,
                storageAvailable: storageInfo.available,
                storageNeeded: storageInfo.needsSpace
            )
        } else {
            return TranslationStatus(
                isAvailable: false,
                platform: "iOS",
                requiresStorage: false,
                reason: "Requires iOS 16.0 or later"
            )
        }
        #elseif os(macOS)
        return TranslationStatus(
            isAvailable: true,
            platform: "macOS (Ollama)",
            requiresStorage: false
        )
        #else
        return TranslationStatus(
            isAvailable: false,
            platform: "Unsupported",
            requiresStorage: false,
            reason: "Platform not supported"
        )
        #endif
    }
    
    private func extractMessageContent(from formattedText: String) -> String {
        var content = formattedText
        
        if let senderEndRange = content.range(of: "> ") {
            content = String(content[senderEndRange.upperBound...])
        }
        
        if content.hasPrefix("* ") && content.contains(" * [") {
            if let systemStartRange = content.range(of: "* "),
               let systemEndRange = content.range(of: " * [") {
                content = String(content[systemStartRange.upperBound..<systemEndRange.lowerBound])
            }
        } else {
            if let timestampRange = content.range(of: " [", options: .backwards) {
                let possibleTimestamp = String(content[timestampRange.lowerBound...])
                if possibleTimestamp.hasSuffix("]") {
                    content = String(content[..<timestampRange.lowerBound])
                }
            }
        }
        
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func replaceMessageContent(in originalText: String, with newContent: String) -> String {
        if originalText.hasPrefix("* ") && originalText.contains(" * [") {
            if let systemEndRange = originalText.range(of: " * [") {
                let timestampPart = String(originalText[systemEndRange.lowerBound...])
                return "* \(newContent) \(timestampPart)"
            }
        }
        
        if let senderEndRange = originalText.range(of: "> ") {
            let senderPart = String(originalText[..<senderEndRange.upperBound])
            
            if let timestampRange = originalText.range(of: " [", options: .backwards) {
                let possibleTimestamp = String(originalText[timestampRange.lowerBound...])
                if possibleTimestamp.hasSuffix("]") {
                    let timestampPart = possibleTimestamp
                    return "\(senderPart)\(newContent)\(timestampPart)"
                }
            }
            
            return "\(senderPart)\(newContent)"
        }
        
        return newContent
    }
    
    /// Platform-aware translation that routes to appropriate service
    private func performTranslation(_ text: String, targetLanguage: String) async throws -> String {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            do {
                return try await mlxService.translate(text, to: targetLanguage)
            } catch let error as MLXTranslationError {
                switch error {
                case .insufficientMemory:
                    let storageInfo = mlxService.getStorageRequirements()
                    print("MLX translation unavailable: Insufficient storage space")
                    print("Required: \(String(format: "%.1f", storageInfo.required)) GB")
                    print("Available: \(String(format: "%.1f", storageInfo.available)) GB")
                    print("Need to free up: \(String(format: "%.1f", storageInfo.needsSpace)) GB")
                case .modelLoadFailed(let underlyingError):
                    print("MLX translation unavailable: Model failed to load - \(underlyingError.localizedDescription)")
                default:
                    print("MLX translation unavailable: \(error.localizedDescription)")
                }
                // Return original text if MLX fails
                return text
            } catch {
                print("MLX translation not available on iOS: \(error)")
                // Return original text if MLX fails
                return text
            }
        } else {
            print("Translation requires iOS 16.0+")
            return text
        }
        #elseif os(macOS)
        // Use Ollama on macOS
        return try await performOllamaTranslation(text, targetLanguage: targetLanguage)
        #else
        // Fallback for other platforms
        return try await performOllamaTranslation(text, targetLanguage: targetLanguage)
        #endif
    }
    
    private func performOllamaTranslation(_ text: String, targetLanguage: String) async throws -> String {
        guard let url = URL(string: "http://localhost:11434/api/generate") else {
            throw TranslationError.invalidURL
        }
        
        let requestBody: [String: Any] = [
            "model": "zongwei/gemma3-translator:1b",
            "prompt": "Translate to \(targetLanguage): \(text)",
            "stream": false
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 30.0
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TranslationError.requestFailed
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? String else {
            throw TranslationError.invalidResponse
        }
        
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func setPreferredLanguage(_ language: String) {
        preferredLanguage = language
    }
    
    func clearCache() {
        translationCache.removeAll()
    }
    
    var isAvailable: Bool {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            return mlxService.isAvailable
        }
        return false
        #elseif os(macOS)
        return true // Assume Ollama is available on macOS
        #else
        return false
        #endif
    }
    
    /// Prepare translation models if needed (useful for iOS MLX)
    func prepareTranslation() async {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            do {
                try await mlxService.prepareModel()
            } catch {
                print("Failed to prepare MLX translation model: \(error)")
            }
        }
        #endif
    }
}

struct TranslationStatus {
    let isAvailable: Bool
    let platform: String
    let requiresStorage: Bool
    let storageRequired: Double?
    let storageAvailable: Double?
    let storageNeeded: Double?
    let reason: String?
    
    init(isAvailable: Bool, platform: String, requiresStorage: Bool, storageRequired: Double? = nil, storageAvailable: Double? = nil, storageNeeded: Double? = nil, reason: String? = nil) {
        self.isAvailable = isAvailable
        self.platform = platform
        self.requiresStorage = requiresStorage
        self.storageRequired = storageRequired
        self.storageAvailable = storageAvailable
        self.storageNeeded = storageNeeded
        self.reason = reason
    }
}

enum TranslationError: Error {
    case invalidURL
    case requestFailed
    case invalidResponse
}
