import Foundation
import SwiftUI
import Network

// NOTE: These imports require adding the MLX Swift packages to your Xcode project:
//   - https://github.com/ml-explore/mlx-swift (core MLX framework)
//   - https://github.com/ml-explore/mlx-swift-examples (MLXLLM module for LLM inference)
// Add both via File > Add Package Dependencies in Xcode.
//
// Uncomment these when the packages are added:
// import MLX
// import MLXLLM

// MARK: - MLXAIProvider
// Conforms to AIProvider for fully on-device inference. All processing stays on
// the phone -- nothing is sent anywhere. This is the provider bitchat users will
// reach for first because it aligns with the app's core privacy promise.
//
// The provider does not decide which model to use. It receives an AIProviderConfig
// and walks the localModels array in order, comparing each model's minimumRAMBytes
// against the device's available memory. The first model the device can support
// becomes the selected model. This means product decisions (which models, what
// order) live in the config, and device-capability decisions live here.

final class MLXAIProvider: ObservableObject, AIProvider {

    // MARK: - AIProvider Conformance

    let id = "local-mlx"
    let displayName = "Local AI"
    let privacyLevel: AIPrivacyLevel = .local

    var isAvailable: Bool {
        // Available if the device has enough RAM for at least one configured model.
        selectedModel != nil
    }

    var requiresSetup: Bool {
        // Setup is needed if we have a viable model but it hasn't been downloaded.
        guard let model = selectedModel else { return false }
        return !modelManager.isModelDownloaded(model)
    }

    var setupDescription: String {
        guard let model = selectedModel else {
            return "No compatible AI model found for this device."
        }
        return "Download \(model.displayName) (\(model.formattedDiskSize)) to enable offline AI."
    }

    // MARK: - Published State for UI

    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var isDownloading: Bool = false
    @Published private(set) var isModelReady: Bool = false
    @Published private(set) var downloadError: String?

    // MARK: - Internal State

    // The best model this device can run, determined once at init by walking
    // the config's localModels array against available RAM.
    private(set) var selectedModel: AIModelConfig?

    private let config: AIProviderConfig
    private let modelManager: MLXModelManager

    // MARK: - Initialization

    init(config: AIProviderConfig) {
        self.config = config
        self.modelManager = MLXModelManager(
            maxTokens: config.maxGenerationTokens,
            temperature: config.localTemperature
        )
        self.selectedModel = Self.selectBestModel(from: config.localModels)

        // FIX: Hydrate model-ready state from disk so the UI reflects reality
        // after an app restart with a previously downloaded model. Without this,
        // isModelReady stays false until the next download or respond() call,
        // causing the settings UI to show "Download" instead of "Ready/Delete".
        if let model = selectedModel {
            self.isModelReady = Self.isModelOnDisk(model)
        }
    }

    /// Synchronous check used only at init to hydrate published state.
    /// Mirrors the artifact-validation logic in MLXModelManager.isModelDownloaded
    /// without crossing the actor boundary.
    private static func isModelOnDisk(_ config: AIModelConfig) -> Bool {
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return false }
        // Check for the actual model file, not just the directory.
        // An empty directory from a failed download must not pass this check.
        let modelFile = docs
            .appendingPathComponent("ai-models/\(config.id)", isDirectory: true)
            .appendingPathComponent("model.safetensors")
        return FileManager.default.fileExists(atPath: modelFile.path)
    }

    // MARK: - Model Selection
    // Walks the config's model list (ordered by preference, best first) and
    // returns the first model whose RAM requirement the device can meet.
    // Uses os_proc_available_memory() which returns the amount of memory
    // available to this process before the system would start killing apps.

    private static func selectBestModel(from models: [AIModelConfig]) -> AIModelConfig? {
        let availableRAM = Int64(os_proc_available_memory())
        for model in models {
            if model.minimumRAMBytes <= availableRAM {
                return model
            }
        }
        return nil
    }

    // MARK: - Download

    func downloadModel() async throws {
        guard let model = selectedModel else {
            throw AIProviderError.noProviderAvailable
        }

        // Enforce WiFi-only. Model files are large and downloading over cellular
        // without the user's knowledge would be hostile, especially for users who
        // chose bitchat specifically for its respect of their resources.
        guard await NetworkMonitor.shared.isOnWiFi else {
            throw AIProviderError.wifiRequired
        }

        await MainActor.run {
            isDownloading = true
            downloadProgress = 0
            downloadError = nil
        }

        do {
            try await modelManager.downloadModel(model) { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                }
            }

            await MainActor.run {
                isDownloading = false
                downloadProgress = 1.0
                isModelReady = true
            }
        } catch {
            await MainActor.run {
                isDownloading = false
                downloadError = error.localizedDescription
            }
            throw AIProviderError.downloadFailed(underlying: error)
        }
    }

    // MARK: - AIProvider.respond
    // Delegates entirely to the actor-isolated model manager. The actor boundary
    // ensures that even if multiple UI actions trigger respond() concurrently,
    // inference calls are serialized and model state is never corrupted.

    func respond(to prompt: String) async throws -> String {
        guard let model = selectedModel else {
            throw AIProviderError.noProviderAvailable
        }
        guard modelManager.isModelDownloaded(model) else {
            throw AIProviderError.providerRequiresSetup(providerName: displayName)
        }

        do {
            let result = try await modelManager.generate(prompt: prompt, model: model)
            await MainActor.run { isModelReady = true }
            return result
        } catch {
            throw AIProviderError.inferenceError(underlying: error)
        }
    }

    // MARK: - Storage Management

    func deleteModel() async throws {
        guard let model = selectedModel else { return }
        try await modelManager.deleteModel(model)
        await MainActor.run { isModelReady = false }
    }

    var modelDiskUsage: Int64? {
        guard let model = selectedModel else { return nil }
        return modelManager.diskUsage(for: model)
    }
}

// MARK: - MLXModelManager (Actor)
// All model state -- the loaded weights, tokenizer, and generation context -- is
// isolated inside this actor. This is the concurrency safety boundary: no matter
// how many Tasks call generate() concurrently, the actor serializes them.
//
// The actor also owns the inactivity timer. After 5 minutes with no inference call,
// it unloads the model to reclaim memory. On a phone with 4-6 GB of RAM running
// a 300MB+ model, this is the difference between the app being a good citizen
// and the system killing it.

actor MLXModelManager {

    // MARK: - Model State
    // These properties represent the loaded model. When non-nil, the model is
    // ready for inference. When nil, the model needs to be loaded from disk.
    // The actual types here will come from MLXLLM -- using Any as a placeholder
    // until the MLX Swift packages are integrated.
    private var loadedModelContext: Any?
    private var loadedModelID: String?

    // MARK: - Configuration

    private let maxTokens: Int
    private let temperature: Float

    // MARK: - Inactivity Timer
    // After 5 minutes of no generate() calls, the model is unloaded. This is
    // aggressive but appropriate for a mobile app where memory is precious and
    // the user may not return to AI for hours.
    private var unloadTask: Task<Void, Never>?
    private let inactivityTimeout: TimeInterval = 300 // 5 minutes

    // MARK: - Stop Sequences
    // Many small language models do not cleanly terminate output. They may emit
    // special tokens as literal text or continue generating as if starting a new
    // conversation turn. We truncate at the first occurrence of any of these.
    private let stopSequences = [
        "<end_of_turn>",
        "<eos>",
        "</s>",
        "<|endoftext|>",
        "<|end|>",
        "<|eot_id|>",
        "\n\nUser:",
        "\n\nHuman:",
        "\n\nAssistant:"  // Prevents echoing a second turn.
    ]

    init(maxTokens: Int, temperature: Float) {
        self.maxTokens = maxTokens
        self.temperature = temperature
    }

    // MARK: - Download

    func downloadModel(
        _ config: AIModelConfig,
        progress: @escaping (Double) -> Void
    ) async throws {
        let destinationDir = try modelDirectory(for: config)

        // Create the directory if it does not exist.
        if !FileManager.default.fileExists(atPath: destinationDir.path) {
            try FileManager.default.createDirectory(
                at: destinationDir,
                withIntermediateDirectories: true
            )
        }

        // Exclude from iCloud/iTunes backup. Model files are large, re-downloadable,
        // and should not consume the user's backup quota.
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDir = destinationDir
        try mutableDir.setResourceValues(resourceValues)

        // Download model files from sourceURL.
        // In production, this uses MLXLLM's ModelRepository or a direct download
        // of a zip/tar archive. The implementation depends on how the sourceURL
        // is structured (HuggingFace repo vs direct file URL).
        //
        // Placeholder implementation using URLSession for a single archive:
        let (tempURL, response) = try await URLSession.shared.download(from: config.sourceURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            // FIX: Clean up the empty directory so isModelDownloaded does not
            // return true after a failed download.
            try? FileManager.default.removeItem(at: destinationDir)
            throw AIProviderError.downloadFailed(
                underlying: NSError(
                    domain: "MLXModelManager",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Server returned an error."]
                )
            )
        }

        // Move downloaded file into the model directory.
        let targetFile = destinationDir.appendingPathComponent("model.safetensors")
        if FileManager.default.fileExists(atPath: targetFile.path) {
            try FileManager.default.removeItem(at: targetFile)
        }

        do {
            try FileManager.default.moveItem(at: tempURL, to: targetFile)
        } catch {
            // FIX: Move failed -- clean up so the directory does not persist empty.
            try? FileManager.default.removeItem(at: destinationDir)
            throw error
        }

        progress(1.0)
    }

    // MARK: - Generation
    // This is where MLX inference happens. The actor boundary guarantees this
    // method is never called concurrently, so model state cannot be corrupted
    // by overlapping requests.

    func generate(prompt: String, model: AIModelConfig) async throws -> String {
        // Reset the inactivity timer on every call.
        resetUnloadTimer()

        // Load the model from disk if not already in memory.
        if loadedModelID != model.id {
            try await loadModel(model)
        }

        // ----- MLX INFERENCE -----
        // When mlx-swift-examples is integrated, replace this block with actual
        // MLXLLM calls. The pattern will be approximately:
        //
        //   let modelDir = try modelDirectory(for: model)
        //   let container = try await LLMModelFactory.shared.loadContainer(
        //       configuration: ModelConfiguration(directory: modelDir)
        //   )
        //   let result = try await container.perform { context in
        //       let input = try await context.processor.prepare(
        //           input: .init(prompt: prompt)
        //       )
        //       return try MLXLMCommon.generate(
        //           input: input,
        //           parameters: GenerateParameters(temperature: temperature),
        //           context: context
        //       ) { tokens in
        //           if tokens.count >= maxTokens { return .stop }
        //           return .more
        //       }
        //   }
        //   let rawOutput = result.output
        //
        // For now, return a placeholder so the full pipeline can be tested end-to-end.
        let rawOutput = "[MLX placeholder] Model \(model.displayName) would respond to: \(prompt)"
        // ----- END MLX INFERENCE -----

        return truncateAtStopSequence(rawOutput)
    }

    // MARK: - Model Loading

    private func loadModel(_ config: AIModelConfig) async throws {
        let dir = try modelDirectory(for: config)
        // FIX: Check for the actual model file, not just the directory.
        let modelFile = dir.appendingPathComponent("model.safetensors")
        guard FileManager.default.fileExists(atPath: modelFile.path) else {
            throw AIProviderError.modelNotLoaded
        }

        // In production: load model weights and tokenizer from dir using MLXLLM.
        // This is the most memory-intensive moment -- the entire model is read
        // into RAM. os_proc_available_memory() was already checked at provider
        // init time to ensure this device can handle it.
        loadedModelContext = true // Placeholder for actual MLXLLM model container.
        loadedModelID = config.id
    }

    // MARK: - Unload

    private func resetUnloadTimer() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(300) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.unloadModel()
        }
    }

    func unloadModel() {
        loadedModelContext = nil
        loadedModelID = nil
    }

    // MARK: - Stop Sequence Handling
    // Small models often do not emit a clean EOS token. Instead they may output
    // literal "<end_of_turn>" text, or start generating a fake user turn like
    // "\n\nUser: blah blah". We scan the output and cut at the first match.

    private func truncateAtStopSequence(_ text: String) -> String {
        var earliest = text.endIndex

        for sequence in stopSequences {
            if let range = text.range(of: sequence) {
                if range.lowerBound < earliest {
                    earliest = range.lowerBound
                }
            }
        }

        return String(text[text.startIndex..<earliest]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - File Management

    func isModelDownloaded(_ config: AIModelConfig) -> Bool {
        // FIX: Check for the actual model artifact, not just the directory.
        // An empty directory from a failed or interrupted download must not
        // pass this check, otherwise the router treats the provider as ready
        // and routes prompts to it without a real model payload.
        guard let dir = try? modelDirectory(for: config) else { return false }
        let modelFile = dir.appendingPathComponent("model.safetensors")
        return FileManager.default.fileExists(atPath: modelFile.path)
    }

    func deleteModel(_ config: AIModelConfig) throws {
        if loadedModelID == config.id {
            unloadModel()
        }
        let dir = try modelDirectory(for: config)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    func diskUsage(for config: AIModelConfig) -> Int64 {
        guard let dir = try? modelDirectory(for: config),
              let enumerator = FileManager.default.enumerator(
                  at: dir,
                  includingPropertiesForKeys: [.fileSizeKey]
              ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    // The model directory lives in the app's Documents folder, organized by model ID.
    // Documents/ (not Caches/) because the user explicitly chose to download this
    // and would be frustrated if the system silently purged it. But we set
    // isExcludedFromBackup to avoid bloating iCloud backups.
    private func modelDirectory(for config: AIModelConfig) throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return docs.appendingPathComponent("ai-models/\(config.id)", isDirectory: true)
    }
}

// MARK: - NetworkMonitor
// Wraps NWPathMonitor to provide a simple async check for WiFi connectivity.
// Used by MLXAIProvider to enforce WiFi-only downloads. This is a shared singleton
// because NWPathMonitor is expensive and one instance serves the whole app.

final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.network.monitor")
    private var currentPath: NWPath?

    var isOnWiFi: Bool {
        currentPath?.usesInterfaceType(.wifi) ?? false
    }

    var isConnected: Bool {
        currentPath?.status == .satisfied
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.currentPath = path
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
