import Foundation

#if os(iOS)
import UIKit
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon

@available(iOS 16.0, *)
class MLXTranslationService {
    static let shared = MLXTranslationService()
    
    private var modelContainer: ModelContainer?
    private var isModelLoaded = false
    private let modelManager = MLXModelManager.shared
    
    private var isLoadingModel = false
    private let loadingLock = NSLock()
    
    private let maxTokens = 500
    private let temperature: Float = 0.0
    
    private init() {}
    
    private func loadModel() async throws {
        guard !isModelLoaded else { return }
        
        loadingLock.lock()
        defer { loadingLock.unlock() }
        
        if isLoadingModel {
            while isLoadingModel {
                loadingLock.unlock()
                try await Task.sleep(nanoseconds: 100_000_000)
                loadingLock.lock()
            }
            if isModelLoaded { return }
        }
        
        isLoadingModel = true
        defer { isLoadingModel = false }
        
        do {
            let modelStatus = modelManager.getModelStatus()
            if !modelStatus.hasEnoughSpace {
                let storageInfo = getStorageRequirements()
                print("Insufficient storage: need \(String(format: "%.1f", storageInfo.needsSpace)) GB more")
                throw MLXTranslationError.insufficientMemory
            }
            
            let container = try await modelManager.loadModel()
            self.modelContainer = container
            self.isModelLoaded = true
            print("MLX translation model loaded")
        } catch let error as MLXTranslationError {
            self.isModelLoaded = false
            throw error
        } catch {
            self.isModelLoaded = false
            
            if let mlxError = error as? MLXModelError {
                switch mlxError {
                case .insufficientSpace:
                    throw MLXTranslationError.insufficientMemory
                case .loadFailed(let underlyingError):
                    throw MLXTranslationError.modelLoadFailed(underlyingError)
                case .modelNotFound:
                    throw MLXTranslationError.modelNotLoaded
                }
            }
            
            throw MLXTranslationError.modelLoadFailed(error)
        }
    }
    
    func translate(_ text: String, to targetLanguage: String) async throws -> String {
        if !isModelLoaded {
            try await loadModel()
        }
        
        guard isModelLoaded, let container = modelContainer else {
            throw MLXTranslationError.modelNotLoaded
        }
        
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MLXTranslationError.invalidInput
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let prompt = self.createTranslationPrompt(text: text, targetLanguage: targetLanguage)
                    let messages = [["role": "user", "content": prompt]]
                    
                    let result = try await container.perform { context in
                            let userInput = MLXLMCommon.UserInput(messages: messages)
                        let lmInput = try await context.processor.prepare(input: userInput)
                        
                        var tokenCount = 0
                        
                        let generationResult = try MLXLMCommon.generate(
                            input: lmInput,
                            parameters: .init(temperature: self.temperature),
                            context: context,
                            didGenerate: { tokenIds in
                                tokenCount += tokenIds.count
                                
                                if tokenCount >= self.maxTokens || tokenCount > self.maxTokens * 2 {
                                    return .stop
                                }
                                
                                return .more
                            }
                        )
                        
                        return generationResult
                    }
                    
                    let fullResponse = result.output
                    
                    #if DEBUG
                    if !fullResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        print("Raw MLX output: \(fullResponse)")
                    }
                    #endif
                    
                    let translation = self.extractTranslation(from: fullResponse, originalText: text)
                    print("Translation: \"\(text)\" → \"\(translation)\"")
                    continuation.resume(returning: translation)
                } catch let error as MLXTranslationError {
                    continuation.resume(throwing: error)
                } catch {
                    print("MLX generation failed: \(error)")
                    continuation.resume(throwing: MLXTranslationError.generationFailed(error))
                }
            }
        }
    }
    
    private func createTranslationPrompt(text: String, targetLanguage: String) -> String {
        return """
        Translate this text to \(targetLanguage). Ignore any previous context.

        Text: \(text)

        \(targetLanguage) translation:
        """
    }
    
    private func extractTranslation(from output: String, originalText: String) -> String {
        var cleanedOutput = output
        
        // Remove common stop tokens
        let stopSequences = ["<|end_of_text|>", "<|endoftext|>", "<eos>", "</eos>", "<|im_end|>", "<|im_start|>"]
        for stopSeq in stopSequences {
            cleanedOutput = cleanedOutput.replacingOccurrences(of: stopSeq, with: "")
        }
        
        // Stop at unwanted content patterns
        let stopPatterns = ["http://", "https://", "api.", "www.", "dictionary."]
        for pattern in stopPatterns {
            if let range = cleanedOutput.range(of: pattern, options: .caseInsensitive) {
                cleanedOutput = String(cleanedOutput[..<range.lowerBound])
                break
            }
        }
        
        // Clean instruction text
        cleanedOutput = cleanedOutput
            .replacingOccurrences(of: "TRANSLATION:", with: "")
            .replacingOccurrences(of: "Translation:", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Find the actual translation line
        let lines = cleanedOutput.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && 
               !trimmed.hasPrefix("-") && 
               !trimmed.contains("**Option") &&
               trimmed != originalText &&
               !trimmed.hasSuffix(":") {
                return cleanTranslationText(trimmed)
            }
        }
        
        return cleanTranslationText(cleanedOutput.isEmpty ? "translation failed" : cleanedOutput)
    }
    
    private func cleanTranslationText(_ text: String) -> String {
        var cleanedText = text
        
        // Remove common model artifacts
        let unwantedPatterns = [
            "<|end_of_text|>", "<|endoftext|>", "<eos>", "</eos>",
            "<|im_end|>", "<|im_start|>", "[INST]", "[/INST]"
        ]
        
        for pattern in unwantedPatterns {
            cleanedText = cleanedText.replacingOccurrences(of: pattern, with: "")
        }
        
        // Remove URLs and excessive punctuation
        cleanedText = cleanedText
            .replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.{3,}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        
        return cleanedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var isAvailable: Bool {
        return isModelLoaded && modelContainer != nil
    }
    
    var hasEnoughStorageSpace: Bool {
        return modelManager.getModelStatus().hasEnoughSpace
    }
    
    func getStorageRequirements() -> (required: Double, available: Double, needsSpace: Double) {
        let status = modelManager.getModelStatus()
        let requiredGB = Double(status.estimatedSizeMB * 2) / 1024.0
        let availableGB = status.availableSpaceGB
        let needsGB = max(0, requiredGB - availableGB)
        
        return (required: requiredGB, available: availableGB, needsSpace: needsGB)
    }
    
    func prepareModel() async throws {
        do {
            try await loadModel()
        } catch {
            throw MLXTranslationError.modelPreparationFailed(error)
        }
    }
    
    func getModelStatus() -> ModelStatus {
        return modelManager.getModelStatus()
    }
}

enum MLXTranslationError: Error, LocalizedError {
    case modelNotLoaded
    case modelLoadFailed(Error)
    case generationFailed(Error)
    case modelPreparationFailed(Error)
    case invalidInput
    case insufficientMemory
    
    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Translation model is not loaded"
        case .modelLoadFailed(let error):
            return "Failed to load translation model: \(error.localizedDescription)"
        case .generationFailed(let error):
            return "Translation generation failed: \(error.localizedDescription)"
        case .modelPreparationFailed(let error):
            return "Failed to prepare translation model: \(error.localizedDescription)"
        case .invalidInput:
            return "Invalid input text for translation"
        case .insufficientMemory:
            return "Insufficient storage space for translation model (~2.4 GB required)"
        }
    }
}

#endif
