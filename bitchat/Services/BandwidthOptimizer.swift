//
// BandwidthOptimizer.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Compression
import CryptoKit

// Bandwidth optimization strategies
enum OptimizationStrategy: String, Codable {
    case maximumCompression = "maximum_compression"
    case balancedCompression = "balanced_compression"
    case minimumLatency = "minimum_latency"
    case costOptimized = "cost_optimized"
    case emergencyMode = "emergency_mode"
}

// Compression statistics
struct CompressionStats: Codable {
    let originalSize: Int
    let compressedSize: Int
    let compressionRatio: Double
    let compressionTime: TimeInterval
    let algorithm: String
    let timestamp: Date
    
    var bytesSaved: Int {
        return originalSize - compressedSize
    }
    
    var savingsPercentage: Double {
        return originalSize > 0 ? (Double(bytesSaved) / Double(originalSize)) * 100.0 : 0.0
    }
}

// Message deduplication
struct DeduplicationEntry: Codable {
    let messageHash: String
    let originalMessage: Data
    let compressedMessage: Data
    let timestamp: Date
    let accessCount: Int
    let lastAccessed: Date
}

// Bandwidth usage tracking
struct BandwidthUsage: Codable {
    let period: TimeInterval
    let bytesTransmitted: Int
    let bytesReceived: Int
    let messagesTransmitted: Int
    let messagesReceived: Int
    let averageCompressionRatio: Double
    let costIncurred: Double
    let timestamp: Date
}

class BandwidthOptimizer: ObservableObject {
    static let shared = BandwidthOptimizer()
    
    @Published var currentStrategy: OptimizationStrategy = .balancedCompression
    @Published var compressionStats: [CompressionStats] = []
    @Published var bandwidthUsage: [BandwidthUsage] = []
    @Published var isOptimizing: Bool = false
    
    // Configuration
    private let maxCompressionTime: TimeInterval = 0.1 // 100ms max compression time
    private let minCompressionRatio: Double = 0.1 // 10% minimum compression to be worth it
    private let maxDeduplicationCacheSize = 1000
    private let deduplicationCacheTimeout: TimeInterval = 3600 // 1 hour
    
    // Caches and queues
    private var deduplicationCache: [String: DeduplicationEntry] = [:]
    private var messageQueue: [OptimizedMessage] = []
    private var batchQueue: [OptimizedMessage] = []
    
    // Statistics
    private var totalBytesSaved: Int = 0
    private var totalCompressionTime: TimeInterval = 0
    private var totalMessagesProcessed: Int = 0
    
    // Timers
    private var statsUpdateTimer: Timer?
    private var cacheCleanupTimer: Timer?
    private var batchProcessingTimer: Timer?
    
    // Compression algorithms
    private let lz4Algorithm = COMPRESSION_LZ4
    private let zlibAlgorithm = COMPRESSION_ZLIB
    private let lzfseAlgorithm = COMPRESSION_LZFSE
    
    struct OptimizedMessage: Codable {
        let originalMessage: Data
        let compressedMessage: Data
        let messageHash: String
        let priority: UInt8
        let timestamp: Date
        let compressionStats: CompressionStats
        let isDuplicate: Bool
        let estimatedCost: Double
    }
    
    init() {
        startOptimizationServices()
    }
    
    // MARK: - Main Optimization Interface
    
    func optimizeMessage(_ message: Data, priority: UInt8 = 1) -> OptimizedMessage? {
        let startTime = Date()
        
        // Check for duplicates first
        let messageHash = SHA256.hash(data: message).compactMap { String(format: "%02x", $0) }.joined()
        
        if let duplicate = deduplicationCache[messageHash] {
            // Update access statistics
            var updatedEntry = duplicate
            updatedEntry.accessCount += 1
            updatedEntry.lastAccessed = Date()
            deduplicationCache[messageHash] = updatedEntry
            
            return OptimizedMessage(
                originalMessage: message,
                compressedMessage: duplicate.compressedMessage,
                messageHash: messageHash,
                priority: priority,
                timestamp: Date(),
                compressionStats: CompressionStats(
                    originalSize: message.count,
                    compressedSize: duplicate.compressedMessage.count,
                    compressionRatio: Double(duplicate.compressedMessage.count) / Double(message.count),
                    compressionTime: 0,
                    algorithm: "deduplication",
                    timestamp: Date()
                ),
                isDuplicate: true,
                estimatedCost: calculateCost(compressedSize: duplicate.compressedMessage.count)
            )
        }
        
        // Compress the message
        let (compressedData, stats) = compressMessage(message)
        
        // Create optimized message
        let optimizedMessage = OptimizedMessage(
            originalMessage: message,
            compressedMessage: compressedData,
            messageHash: messageHash,
            priority: priority,
            timestamp: Date(),
            compressionStats: stats,
            isDuplicate: false,
            estimatedCost: calculateCost(compressedSize: compressedData.count)
        )
        
        // Cache the result
        cacheOptimizedMessage(messageHash: messageHash, original: message, compressed: compressedData)
        
        // Update statistics
        updateCompressionStats(stats)
        
        return optimizedMessage
    }
    
    func optimizeBatch(_ messages: [Data], priority: UInt8 = 1) -> [OptimizedMessage] {
        var optimizedMessages: [OptimizedMessage] = []
        
        for message in messages {
            if let optimized = optimizeMessage(message, priority: priority) {
                optimizedMessages.append(optimized)
            }
        }
        
        // Apply batch-level optimizations
        return applyBatchOptimizations(optimizedMessages)
    }
    
    // MARK: - Compression Algorithms
    
    private func compressMessage(_ data: Data) -> (Data, CompressionStats) {
        let startTime = Date()
        
        // Choose compression algorithm based on strategy
        let algorithm = selectCompressionAlgorithm(for: data)
        
        let compressedData: Data
        let algorithmName: String
        
        switch algorithm {
        case lz4Algorithm:
            compressedData = compressWithLZ4(data)
            algorithmName = "LZ4"
        case zlibAlgorithm:
            compressedData = compressWithZlib(data)
            algorithmName = "ZLIB"
        case lzfseAlgorithm:
            compressedData = compressWithLZFSE(data)
            algorithmName = "LZFSE"
        default:
            compressedData = data
            algorithmName = "none"
        }
        
        let compressionTime = Date().timeIntervalSince(startTime)
        let compressionRatio = Double(compressedData.count) / Double(data.count)
        
        let stats = CompressionStats(
            originalSize: data.count,
            compressedSize: compressedData.count,
            compressionRatio: compressionRatio,
            compressionTime: compressionTime,
            algorithm: algorithmName,
            timestamp: Date()
        )
        
        return (compressedData, stats)
    }
    
    private func selectCompressionAlgorithm(for data: Data) -> compression_algorithm {
        switch currentStrategy {
        case .maximumCompression:
            return zlibAlgorithm // Best compression ratio
        case .balancedCompression:
            return lzfseAlgorithm // Good balance of speed and compression
        case .minimumLatency:
            return lz4Algorithm // Fastest compression
        case .costOptimized:
            return data.count > 1000 ? lzfseAlgorithm : lz4Algorithm // Use faster for small messages
        case .emergencyMode:
            return lz4Algorithm // Fastest for emergencies
        }
    }
    
    private func compressWithLZ4(_ data: Data) -> Data {
        let sourceSize = data.count
        let destinationSize = sourceSize + (sourceSize / 16) + 64
        
        var destination = Data(count: destinationSize)
        
        let result = destination.withUnsafeMutableBytes { destPtr in
            data.withUnsafeBytes { srcPtr in
                compression_encode_buffer(
                    destPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    destinationSize,
                    srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    sourceSize,
                    nil,
                    lz4Algorithm
                )
            }
        }
        
        if result > 0 {
            destination.count = result
            return destination
        } else {
            return data // Return original if compression failed
        }
    }
    
    private func compressWithZlib(_ data: Data) -> Data {
        let sourceSize = data.count
        let destinationSize = sourceSize + (sourceSize / 16) + 64
        
        var destination = Data(count: destinationSize)
        
        let result = destination.withUnsafeMutableBytes { destPtr in
            data.withUnsafeBytes { srcPtr in
                compression_encode_buffer(
                    destPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    destinationSize,
                    srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    sourceSize,
                    nil,
                    zlibAlgorithm
                )
            }
        }
        
        if result > 0 {
            destination.count = result
            return destination
        } else {
            return data // Return original if compression failed
        }
    }
    
    private func compressWithLZFSE(_ data: Data) -> Data {
        let sourceSize = data.count
        let destinationSize = sourceSize + (sourceSize / 16) + 64
        
        var destination = Data(count: destinationSize)
        
        let result = destination.withUnsafeMutableBytes { destPtr in
            data.withUnsafeBytes { srcPtr in
                compression_encode_buffer(
                    destPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    destinationSize,
                    srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    sourceSize,
                    nil,
                    lzfseAlgorithm
                )
            }
        }
        
        if result > 0 {
            destination.count = result
            return destination
        } else {
            return data // Return original if compression failed
        }
    }
    
    // MARK: - Deduplication
    
    private func cacheOptimizedMessage(messageHash: String, original: Data, compressed: Data) {
        let entry = DeduplicationEntry(
            messageHash: messageHash,
            originalMessage: original,
            compressedMessage: compressed,
            timestamp: Date(),
            accessCount: 1,
            lastAccessed: Date()
        )
        
        deduplicationCache[messageHash] = entry
        
        // Maintain cache size
        if deduplicationCache.count > maxDeduplicationCacheSize {
            cleanupDeduplicationCache()
        }
    }
    
    private func cleanupDeduplicationCache() {
        let now = Date()
        let staleEntries = deduplicationCache.filter { entry in
            now.timeIntervalSince(entry.value.lastAccessed) > deduplicationCacheTimeout
        }
        
        // Remove stale entries
        for (hash, _) in staleEntries {
            deduplicationCache.removeValue(forKey: hash)
        }
        
        // If still over limit, remove least accessed entries
        if deduplicationCache.count > maxDeduplicationCacheSize {
            let sortedEntries = deduplicationCache.sorted { $0.value.accessCount < $1.value.accessCount }
            let entriesToRemove = sortedEntries.prefix(deduplicationCache.count - maxDeduplicationCacheSize)
            
            for (hash, _) in entriesToRemove {
                deduplicationCache.removeValue(forKey: hash)
            }
        }
    }
    
    // MARK: - Batch Optimizations
    
    private func applyBatchOptimizations(_ messages: [OptimizedMessage]) -> [OptimizedMessage] {
        var optimized = messages
        
        // Sort by priority and estimated cost
        optimized.sort { msg1, msg2 in
            if msg1.priority != msg2.priority {
                return msg1.priority > msg2.priority
            }
            return msg1.estimatedCost < msg2.estimatedCost
        }
        
        // Apply smart batching for similar messages
        optimized = applySmartBatching(optimized)
        
        return optimized
    }
    
    private func applySmartBatching(_ messages: [OptimizedMessage]) -> [OptimizedMessage] {
        // Group similar messages for potential further optimization
        var groupedMessages: [String: [OptimizedMessage]] = [:]
        
        for message in messages {
            let groupKey = "\(message.priority)-\(message.compressionStats.algorithm)"
            if groupedMessages[groupKey] == nil {
                groupedMessages[groupKey] = []
            }
            groupedMessages[groupKey]?.append(message)
        }
        
        // Process each group
        var result: [OptimizedMessage] = []
        for (_, groupMessages) in groupedMessages {
            result.append(contentsOf: groupMessages)
        }
        
        return result
    }
    
    // MARK: - Cost Calculation
    
    private func calculateCost(compressedSize: Int) -> Double {
        // Calculate estimated cost based on compressed size
        // This would integrate with actual satellite data costs
        let bytesPerMessage = Double(compressedSize)
        let costPerByte = 0.000001 // $0.000001 per byte (example rate)
        return bytesPerMessage * costPerByte
    }
    
    // MARK: - Statistics and Monitoring
    
    private func updateCompressionStats(_ stats: CompressionStats) {
        compressionStats.append(stats)
        
        // Keep only recent stats
        let cutoffTime = Date().addingTimeInterval(-3600) // Last hour
        compressionStats = compressionStats.filter { $0.timestamp > cutoffTime }
        
        // Update totals
        totalBytesSaved += stats.bytesSaved
        totalCompressionTime += stats.compressionTime
        totalMessagesProcessed += 1
    }
    
    private func startOptimizationServices() {
        // Start statistics update timer
        statsUpdateTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.updateBandwidthStatistics()
        }
        
        // Start cache cleanup timer
        cacheCleanupTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.cleanupDeduplicationCache()
        }
        
        // Start batch processing timer
        batchProcessingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.processBatchQueue()
        }
    }
    
    private func updateBandwidthStatistics() {
        let period: TimeInterval = 60.0 // 1 minute
        
        let recentStats = compressionStats.filter { 
            $0.timestamp > Date().addingTimeInterval(-period) 
        }
        
        let totalBytesTransmitted = recentStats.reduce(0) { $0 + $1.compressedSize }
        let totalBytesOriginal = recentStats.reduce(0) { $0 + $1.originalSize }
        let averageCompressionRatio = recentStats.isEmpty ? 0.0 : 
            Double(totalBytesTransmitted) / Double(totalBytesOriginal)
        
        let usage = BandwidthUsage(
            period: period,
            bytesTransmitted: totalBytesTransmitted,
            bytesReceived: 0, // Would be updated from receive side
            messagesTransmitted: recentStats.count,
            messagesReceived: 0, // Would be updated from receive side
            averageCompressionRatio: averageCompressionRatio,
            costIncurred: calculateTotalCost(for: recentStats),
            timestamp: Date()
        )
        
        bandwidthUsage.append(usage)
        
        // Keep only recent usage data
        let cutoffTime = Date().addingTimeInterval(-86400) // Last 24 hours
        bandwidthUsage = bandwidthUsage.filter { $0.timestamp > cutoffTime }
    }
    
    private func calculateTotalCost(for stats: [CompressionStats]) -> Double {
        return stats.reduce(0.0) { total, stat in
            total + calculateCost(compressedSize: stat.compressedSize)
        }
    }
    
    private func processBatchQueue() {
        // Process any queued batch operations
        guard !batchQueue.isEmpty else { return }
        
        let messagesToProcess = batchQueue
        batchQueue.removeAll()
        
        // Process the batch
        let optimized = applyBatchOptimizations(messagesToProcess)
        
        // Add back to main queue
        messageQueue.append(contentsOf: optimized)
    }
    
    // MARK: - Public Interface
    
    func setOptimizationStrategy(_ strategy: OptimizationStrategy) {
        currentStrategy = strategy
        print("Bandwidth optimization strategy changed to: \(strategy.rawValue)")
    }
    
    func getOptimizationStatistics() -> (totalBytesSaved: Int, averageCompressionRatio: Double, totalCost: Double) {
        let averageRatio = compressionStats.isEmpty ? 0.0 : 
            compressionStats.reduce(0.0) { $0 + $1.compressionRatio } / Double(compressionStats.count)
        
        let totalCost = calculateTotalCost(for: compressionStats)
        
        return (totalBytesSaved, averageRatio, totalCost)
    }
    
    func clearCache() {
        deduplicationCache.removeAll()
        compressionStats.removeAll()
        bandwidthUsage.removeAll()
        totalBytesSaved = 0
        totalCompressionTime = 0
        totalMessagesProcessed = 0
    }
    
    func getBandwidthUsageHistory() -> [BandwidthUsage] {
        return bandwidthUsage
    }
    
    func estimateCost(for messageSize: Int) -> Double {
        // Estimate cost for a message of given size
        let estimatedCompressedSize = Int(Double(messageSize) * 0.7) // Assume 30% compression
        return calculateCost(compressedSize: estimatedCompressedSize)
    }
    
    func isOptimizationWorthwhile(for messageSize: Int) -> Bool {
        // Determine if compression is worthwhile for a given message size
        switch currentStrategy {
        case .maximumCompression:
            return messageSize > 50 // Always compress if > 50 bytes
        case .balancedCompression:
            return messageSize > 100 // Compress if > 100 bytes
        case .minimumLatency:
            return messageSize > 500 // Only compress large messages
        case .costOptimized:
            return messageSize > 200 // Balance between cost and speed
        case .emergencyMode:
            return messageSize > 1000 // Only compress very large messages
        }
    }
}

// MARK: - Extensions for Integration

extension BandwidthOptimizer {
    func optimizeForSatellite(_ message: Data, priority: UInt8 = 1) -> OptimizedMessage? {
        // Special optimization for satellite transmission
        let originalStrategy = currentStrategy
        
        // Use maximum compression for satellite to save bandwidth
        currentStrategy = .maximumCompression
        
        let result = optimizeMessage(message, priority: priority)
        
        // Restore original strategy
        currentStrategy = originalStrategy
        
        return result
    }
    
    func optimizeForEmergency(_ message: Data) -> OptimizedMessage? {
        // Special optimization for emergency messages
        let originalStrategy = currentStrategy
        
        // Use minimum latency for emergencies
        currentStrategy = .minimumLatency
        
        let result = optimizeMessage(message, priority: 3) // Emergency priority
        
        // Restore original strategy
        currentStrategy = originalStrategy
        
        return result
    }
} 