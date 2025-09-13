import Foundation

#if os(iOS)
import UIKit
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon

@available(iOS 16.0, *)
class MLXModelManager {
    static let shared = MLXModelManager()
    
    private let fileManager = FileManager.default
    private var isCurrentlyLoading = false
    private let loadingLock = NSLock()
    
    private struct ModelConfig {
        let identifier: String
        let huggingFaceRepo: String
        let localName: String
        let sizeInMB: Int
    }

    private let defaultModel = ModelConfig(
        identifier: "gemma-3-1b-it",
        huggingFaceRepo: "mlx-community/gemma-3-1b-it-4bit",
        localName: "gemma-3-1b-it-4bit",
        sizeInMB: 1200
    )

    private var modelDirectory: URL {
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("MLXModels")
    }
    
    private init() {
        createModelDirectoryIfNeeded()
    }
    
    private func createModelDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: modelDirectory.path) {
            try? fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        }
    }
    
    var isModelAvailable: Bool {
        return checkModelExists(modelId: defaultModel.huggingFaceRepo)
    }
    
    var estimatedModelSize: Int64 {
        return Int64(defaultModel.sizeInMB * 1024 * 1024)
    }
    
    func ensureSpaceForModel() throws {
        guard hasEnoughSpaceForModel() else {
            throw MLXModelError.insufficientSpace
        }
    }
    
    func loadModel() async throws -> ModelContainer {
        loadingLock.lock()
        defer { loadingLock.unlock() }
        
        if isCurrentlyLoading {
            while isCurrentlyLoading {
                loadingLock.unlock()
                try await Task.sleep(nanoseconds: 100_000_000)
                loadingLock.lock()
            }
        }
        
        isCurrentlyLoading = true
        defer { isCurrentlyLoading = false }
        
        do {
            let currentModelExists = checkModelExists(modelId: defaultModel.huggingFaceRepo)
            
            if !currentModelExists {
                try ensureSpaceForModel()
                await clearAllModelsExcept(keepModel: defaultModel.huggingFaceRepo)
            }
            
            MLX.GPU.set(cacheLimit: 2048 * 1024 * 1024)
            
            let modelConfig = ModelConfiguration(id: self.defaultModel.huggingFaceRepo)
            
            var lastLoggedProgress = -1
            let modelContainer = try await LLMModelFactory.shared.loadContainer(configuration: modelConfig) { progress in
                if !currentModelExists {
                    let currentProgress = Int(progress.fractionCompleted * 100)
                    if currentProgress >= lastLoggedProgress + 10 {
                        print("Download progress: \(currentProgress)%")
                        lastLoggedProgress = currentProgress
                    }
                }
            }
            
            return modelContainer
        } catch {
            throw MLXModelError.loadFailed(error)
        }
    }
    
    private func checkModelExists(modelId: String) -> Bool {
        let cacheDirectories = getMLXCacheDirectories()
        let possibleNames = [
            modelId.replacingOccurrences(of: "/", with: "--"),
            modelId.replacingOccurrences(of: "/", with: "_"),
            String(modelId.split(separator: "/").last ?? ""),
            modelId
        ]
        
        for directory in cacheDirectories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            
            do {
                let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
                
                for item in contents {
                    let itemName = item.lastPathComponent
                    
                    for possibleName in possibleNames {
                        if !possibleName.isEmpty && (itemName.contains(possibleName) || itemName.hasPrefix(possibleName)) {
                            if let isDirectory = try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                               isDirectory {
                                let modelFiles = try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
                                let hasModelFiles = modelFiles?.contains { file in
                                    let fileName = file.lastPathComponent
                                    return fileName.hasSuffix(".safetensors") || 
                                           fileName.hasSuffix(".gguf") || 
                                           fileName == "config.json" ||
                                           fileName == "tokenizer.json" ||
                                           fileName.contains("model")
                                } ?? false
                                
                                if hasModelFiles {
                                    return true
                                }
                            }
                        }
                    }
                }
            } catch {
                continue
            }
        }
        
        return false
    }
    
    private func getMLXCacheDirectories() -> [URL] {
        var directories: [URL] = []
        
        directories.append(modelDirectory)
        
        if let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let libraryPath = documentsPath.deletingLastPathComponent()
            let cachesPath = libraryPath.appendingPathComponent("Library").appendingPathComponent("Caches")
            let appSupportPath = libraryPath.appendingPathComponent("Library").appendingPathComponent("Application Support")
            
            // Common MLX cache locations
            directories.append(cachesPath.appendingPathComponent("models"))
            directories.append(cachesPath.appendingPathComponent("MLX"))
            directories.append(cachesPath.appendingPathComponent("huggingface").appendingPathComponent("hub"))
            directories.append(cachesPath.appendingPathComponent("LLMModelFactory"))
            directories.append(appSupportPath.appendingPathComponent("MLX"))
            
            // Dynamic discovery of MLX-related directories
            if fileManager.fileExists(atPath: cachesPath.path) {
                do {
                    let cacheContents = try fileManager.contentsOfDirectory(at: cachesPath, includingPropertiesForKeys: [.isDirectoryKey])
                    for item in cacheContents {
                        let itemName = item.lastPathComponent.lowercased()
                        if itemName.contains("mlx") || itemName.contains("llm") {
                            directories.append(item)
                        }
                    }
                } catch {
                    // Continue if cache scan fails
                }
            }
        }
        
        return Array(Set(directories))
    }
    
    private func clearAllModelsExcept(keepModel: String?) async {
        let cacheDirectories = getMLXCacheDirectories()
        
        for directory in cacheDirectories {
            await clearDirectoryExcept(directory: directory, keepModel: keepModel)
        }
        
        MLX.GPU.clearCache()
    }
    
    private func clearDirectoryExcept(directory: URL, keepModel: String?) async {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            
            for item in contents {
                var shouldKeep = false
                
                if let keepModelId = keepModel {
                    let itemName = item.lastPathComponent.lowercased()
                    let possibleKeepNames = [
                        keepModelId.replacingOccurrences(of: "/", with: "--").lowercased(),
                        keepModelId.replacingOccurrences(of: "/", with: "_").lowercased(),
                        String(keepModelId.split(separator: "/").last ?? "").lowercased(),
                        keepModelId.lowercased()
                    ]
                    
                    shouldKeep = possibleKeepNames.contains { possibleName in
                        !possibleName.isEmpty && (itemName.contains(possibleName) || itemName.hasPrefix(possibleName))
                    }
                    
                    if !shouldKeep {
                        if let isDirectory = try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDirectory {
                            let subItems = try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
                            let containsOurModel = subItems?.contains { subItem in
                                let subItemName = subItem.lastPathComponent.lowercased()
                                return possibleKeepNames.contains { possibleName in
                                    !possibleName.isEmpty && subItemName.contains(possibleName)
                                }
                            } ?? false
                            
                            if containsOurModel {
                                shouldKeep = true
                            }
                        }
                    }
                }
                
                if !shouldKeep {
                    try? fileManager.removeItem(at: item)
                }
            }
            
            if directory != modelDirectory {
                let remainingContents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                if remainingContents?.isEmpty == true {
                    try? fileManager.removeItem(at: directory)
                }
            }
        } catch {
            // Continue if directory clearing fails
        }
    }
    
    private func getAvailableSpace() -> Int64 {
        do {
            let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
            let attributes = try fileManager.attributesOfFileSystem(forPath: documentsPath)
            
            if let freeSize = attributes[.systemFreeSize] as? Int64 {
                return freeSize
            } else if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                let resourceValues = try documentsURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
                return Int64(resourceValues.volumeAvailableCapacity ?? 0)
            }
            return 0
        } catch {
            return 0
        }
    }
    
    func hasEnoughSpaceForModel() -> Bool {
        let availableSpace = getAvailableSpace()
        let requiredSpace = estimatedModelSize * 2
        return availableSpace > requiredSpace
    }
    
    func getModelStatus() -> ModelStatus {
        return ModelStatus(
            isAvailable: isModelAvailable,
            modelName: defaultModel.localName,
            estimatedSizeMB: defaultModel.sizeInMB,
            hasEnoughSpace: hasEnoughSpaceForModel(),
            availableSpaceGB: Double(getAvailableSpace()) / (1024 * 1024 * 1024)
        )
    }
    
    func getTotalCachedModelSize() -> Int64 {
        var totalSize: Int64 = 0
        let cacheDirectories = getMLXCacheDirectories()
        
        for directory in cacheDirectories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            totalSize += getDirectorySize(at: directory)
        }
        
        return totalSize
    }
    
    private func getDirectorySize(at url: URL) -> Int64 {
        var totalSize: Int64 = 0
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey])
            
            for item in contents {
                let resourceValues = try item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                
                if let isDirectory = resourceValues.isDirectory, isDirectory {
                    totalSize += getDirectorySize(at: item)
                } else if let fileSize = resourceValues.fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        } catch {
            // Continue if size calculation fails
        }
        
        return totalSize
    }
    
    func getCacheInfo() -> CacheInfo {
        let totalCachedSize = getTotalCachedModelSize()
        let availableSpace = getAvailableSpace()
        let cacheDirectories = getMLXCacheDirectories()
        
        var directoryInfo: [String: Int64] = [:]
        for directory in cacheDirectories {
            if fileManager.fileExists(atPath: directory.path) {
                directoryInfo[directory.path] = getDirectorySize(at: directory)
            }
        }
        
        return CacheInfo(
            totalCachedSizeMB: Int(totalCachedSize / (1024 * 1024)),
            availableSpaceGB: Double(availableSpace) / (1024 * 1024 * 1024),
            cacheDirectories: directoryInfo,
            currentModel: defaultModel.huggingFaceRepo
        )
    }
    
    #if DEBUG
    func debugCacheDirectories() {
        print("MLX Cache Analysis")
        let cacheDirectories = getMLXCacheDirectories()
        
        for directory in cacheDirectories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            
            do {
                let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
                if !contents.isEmpty {
                    print("📂 \(directory.lastPathComponent): \(contents.count) items")
                }
            } catch {
                continue
            }
        }
        
        print("Current model: \(defaultModel.huggingFaceRepo)")
        print("Model cached: \(checkModelExists(modelId: defaultModel.huggingFaceRepo))")
    }
    #endif
}

struct ModelStatus {
    let isAvailable: Bool
    let modelName: String
    let estimatedSizeMB: Int
    let hasEnoughSpace: Bool
    let availableSpaceGB: Double
}

struct CacheInfo {
    let totalCachedSizeMB: Int
    let availableSpaceGB: Double
    let cacheDirectories: [String: Int64]
    let currentModel: String
}

enum MLXModelError: Error, LocalizedError {
    case loadFailed(Error)
    case insufficientSpace
    case modelNotFound
    
    var errorDescription: String? {
        switch self {
        case .loadFailed(let error):
            return "Model loading failed: \(error.localizedDescription)"
        case .insufficientSpace:
            return "Insufficient storage space for model"
        case .modelNotFound:
            return "Translation model not found"
        }
    }
}

#endif
