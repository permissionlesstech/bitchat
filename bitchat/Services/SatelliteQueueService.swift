//
// SatelliteQueueService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Combine

// Queue priority levels
enum QueuePriority: Int, Codable, CaseIterable {
    case emergency = 0
    case high = 1
    case normal = 2
    case low = 3
    case background = 4
    
    var displayName: String {
        switch self {
        case .emergency: return "Emergency"
        case .high: return "High"
        case .normal: return "Normal"
        case .low: return "Low"
        case .background: return "Background"
        }
    }
    
    var maxQueueSize: Int {
        switch self {
        case .emergency: return 100
        case .high: return 500
        case .normal: return 1000
        case .low: return 2000
        case .background: return 5000
        }
    }
    
    var maxWaitTime: TimeInterval {
        switch self {
        case .emergency: return 30 // 30 seconds
        case .high: return 300 // 5 minutes
        case .normal: return 1800 // 30 minutes
        case .low: return 7200 // 2 hours
        case .background: return 86400 // 24 hours
        }
    }
}

// Queued message structure
struct QueuedMessage: Codable, Identifiable {
    let id: String
    let messageData: Data
    let priority: QueuePriority
    let timestamp: Date
    let expiresAt: Date
    let senderID: String
    let recipientID: String?
    let messageType: String
    let retryCount: Int
    let estimatedCost: Double
    let compressionRatio: Double
    let isEmergency: Bool
    
    init(messageData: Data, priority: QueuePriority, senderID: String, recipientID: String? = nil, messageType: String, estimatedCost: Double = 0.0, compressionRatio: Double = 1.0, isEmergency: Bool = false) {
        self.id = UUID().uuidString
        self.messageData = messageData
        self.priority = priority
        self.timestamp = Date()
        self.expiresAt = Date().addingTimeInterval(priority.maxWaitTime)
        self.senderID = senderID
        self.recipientID = recipientID
        self.messageType = messageType
        self.retryCount = 0
        self.estimatedCost = estimatedCost
        self.compressionRatio = compressionRatio
        self.isEmergency = isEmergency
    }
    
    var isExpired: Bool {
        return Date() > expiresAt
    }
    
    var age: TimeInterval {
        return Date().timeIntervalSince(timestamp)
    }
    
    var shouldRetry: Bool {
        return retryCount < maxRetryCount && !isExpired
    }
    
    private var maxRetryCount: Int {
        switch priority {
        case .emergency: return 10
        case .high: return 5
        case .normal: return 3
        case .low: return 2
        case .background: return 1
        }
    }
}

// Queue statistics
struct QueueStatistics: Codable {
    let totalMessages: Int
    let messagesByPriority: [QueuePriority: Int]
    let averageWaitTime: TimeInterval
    let totalCost: Double
    let successRate: Double
    let lastTransmission: Date?
    let nextScheduledTransmission: Date?
    let queueHealth: QueueHealth
    
    enum QueueHealth: String, Codable {
        case excellent = "excellent"
        case good = "good"
        case fair = "fair"
        case poor = "poor"
        case critical = "critical"
    }
}

// Transmission window
struct TransmissionWindow: Codable {
    let startTime: Date
    let endTime: Date
    let duration: TimeInterval
    let bandwidth: Double // bits per second
    let costPerByte: Double
    let isEmergency: Bool
    
    var isActive: Bool {
        let now = Date()
        return now >= startTime && now <= endTime
    }
    
    var timeRemaining: TimeInterval {
        let now = Date()
        return max(0, endTime.timeIntervalSince(now))
    }
}

protocol SatelliteQueueServiceDelegate: AnyObject {
    func didQueueMessage(_ message: QueuedMessage)
    func didTransmitMessage(_ message: QueuedMessage)
    func didFailToTransmitMessage(_ message: QueuedMessage, error: Error)
    func queueStatisticsUpdated(_ stats: QueueStatistics)
    func transmissionWindowOpened(_ window: TransmissionWindow)
    func transmissionWindowClosed(_ window: TransmissionWindow)
}

class SatelliteQueueService: ObservableObject {
    static let shared = SatelliteQueueService()
    
    @Published var queueStatistics: QueueStatistics
    @Published var currentTransmissionWindow: TransmissionWindow?
    @Published var isTransmitting: Bool = false
    
    weak var delegate: SatelliteQueueServiceDelegate?
    
    // Priority queues
    private var emergencyQueue: [QueuedMessage] = []
    private var highPriorityQueue: [QueuedMessage] = []
    private var normalQueue: [QueuedMessage] = []
    private var lowPriorityQueue: [QueuedMessage] = []
    private var backgroundQueue: [QueuedMessage] = []
    
    // Configuration
    private let maxTotalQueueSize = 10000
    private let transmissionBatchSize = 50
    private let transmissionInterval: TimeInterval = 60 // 1 minute
    private let emergencyTransmissionInterval: TimeInterval = 10 // 10 seconds
    
    // Timers and state
    private var transmissionTimer: Timer?
    private var emergencyTimer: Timer?
    private var cleanupTimer: Timer?
    private var statisticsTimer: Timer?
    
    // Statistics tracking
    private var totalMessagesTransmitted: Int = 0
    private var totalMessagesFailed: Int = 0
    private var totalCostIncurred: Double = 0
    private var lastTransmissionTime: Date?
    
    init() {
        self.queueStatistics = QueueStatistics(
            totalMessages: 0,
            messagesByPriority: [:],
            averageWaitTime: 0,
            totalCost: 0,
            successRate: 0,
            lastTransmission: nil,
            nextScheduledTransmission: nil,
            queueHealth: .excellent
        )
        
        startQueueServices()
    }
    
    // MARK: - Queue Management
    
    func enqueueMessage(_ message: QueuedMessage) {
        // Add to appropriate priority queue
        switch message.priority {
        case .emergency:
            emergencyQueue.append(message)
        case .high:
            highPriorityQueue.append(message)
        case .normal:
            normalQueue.append(message)
        case .low:
            lowPriorityQueue.append(message)
        case .background:
            backgroundQueue.append(message)
        }
        
        // Maintain queue size limits
        enforceQueueSizeLimits()
        
        // Update statistics
        updateQueueStatistics()
        
        // Notify delegate
        delegate?.didQueueMessage(message)
        
        // Trigger immediate transmission for emergency messages
        if message.isEmergency {
            scheduleEmergencyTransmission()
        }
    }
    
    func dequeueMessage() -> QueuedMessage? {
        // Priority order: emergency -> high -> normal -> low -> background
        if let message = emergencyQueue.first {
            emergencyQueue.removeFirst()
            return message
        }
        
        if let message = highPriorityQueue.first {
            highPriorityQueue.removeFirst()
            return message
        }
        
        if let message = normalQueue.first {
            normalQueue.removeFirst()
            return message
        }
        
        if let message = lowPriorityQueue.first {
            lowPriorityQueue.removeFirst()
            return message
        }
        
        if let message = backgroundQueue.first {
            backgroundQueue.removeFirst()
            return message
        }
        
        return nil
    }
    
    func dequeueBatch(size: Int) -> [QueuedMessage] {
        var batch: [QueuedMessage] = []
        let targetSize = min(size, transmissionBatchSize)
        
        while batch.count < targetSize {
            if let message = dequeueMessage() {
                batch.append(message)
            } else {
                break
            }
        }
        
        return batch
    }
    
    // MARK: - Transmission Management
    
    func startTransmission() {
        guard !isTransmitting else { return }
        
        isTransmitting = true
        
        // Start transmission timer
        transmissionTimer = Timer.scheduledTimer(withTimeInterval: transmissionInterval, repeats: true) { [weak self] _ in
            self?.processTransmission()
        }
        
        // Start emergency timer
        emergencyTimer = Timer.scheduledTimer(withTimeInterval: emergencyTransmissionInterval, repeats: true) { [weak self] _ in
            self?.processEmergencyTransmission()
        }
        
        // Process initial transmission
        processTransmission()
    }
    
    func stopTransmission() {
        isTransmitting = false
        
        transmissionTimer?.invalidate()
        transmissionTimer = nil
        
        emergencyTimer?.invalidate()
        emergencyTimer = nil
    }
    
    private func processTransmission() {
        guard isTransmitting else { return }
        
        // Check for transmission window
        guard let window = currentTransmissionWindow, window.isActive else {
            print("No active transmission window")
            return
        }
        
        // Get batch of messages to transmit
        let batch = dequeueBatch(size: transmissionBatchSize)
        
        guard !batch.isEmpty else {
            print("No messages to transmit")
            return
        }
        
        // Calculate total size and cost
        let totalSize = batch.reduce(0) { $0 + $1.messageData.count }
        let totalCost = batch.reduce(0.0) { $0 + $1.estimatedCost }
        
        // Check if we have enough bandwidth and budget
        if canTransmit(size: totalSize, cost: totalCost, in: window) {
            transmitBatch(batch)
        } else {
            // Re-queue messages that can't be transmitted
            for message in batch {
                reQueueMessage(message)
            }
        }
    }
    
    private func processEmergencyTransmission() {
        guard isTransmitting else { return }
        
        // Process emergency messages immediately
        let emergencyBatch = emergencyQueue.prefix(10) // Limit emergency batch size
        let emergencyMessages = Array(emergencyBatch)
        
        for message in emergencyMessages {
            emergencyQueue.removeAll { $0.id == message.id }
            transmitMessage(message)
        }
    }
    
    private func transmitBatch(_ batch: [QueuedMessage]) {
        for message in batch {
            transmitMessage(message)
        }
    }
    
    private func transmitMessage(_ message: QueuedMessage) {
        // Simulate transmission (in real implementation, this would send via satellite)
        print("Transmitting message: \(message.id) with priority: \(message.priority.displayName)")
        
        // Simulate transmission delay
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
            DispatchQueue.main.async {
                self?.handleTransmissionResult(message, success: true, error: nil)
            }
        }
    }
    
    private func handleTransmissionResult(_ message: QueuedMessage, success: Bool, error: Error?) {
        if success {
            totalMessagesTransmitted += 1
            totalCostIncurred += message.estimatedCost
            lastTransmissionTime = Date()
            
            delegate?.didTransmitMessage(message)
        } else {
            totalMessagesFailed += 1
            
            // Re-queue with retry if appropriate
            if message.shouldRetry {
                var retryMessage = message
                retryMessage.retryCount += 1
                reQueueMessage(retryMessage)
            }
            
            delegate?.didFailToTransmitMessage(message, error: error ?? NSError(domain: "SatelliteQueue", code: -1, userInfo: nil))
        }
        
        updateQueueStatistics()
    }
    
    // MARK: - Queue Maintenance
    
    private func enforceQueueSizeLimits() {
        // Check total queue size
        let totalSize = emergencyQueue.count + highPriorityQueue.count + normalQueue.count + lowPriorityQueue.count + backgroundQueue.count
        
        if totalSize > maxTotalQueueSize {
            // Remove oldest background messages first
            while totalSize > maxTotalQueueSize && !backgroundQueue.isEmpty {
                backgroundQueue.removeLast()
            }
            
            // Then remove low priority messages
            while totalSize > maxTotalQueueSize && !lowPriorityQueue.isEmpty {
                lowPriorityQueue.removeLast()
            }
        }
        
        // Enforce individual queue limits
        if emergencyQueue.count > QueuePriority.emergency.maxQueueSize {
            emergencyQueue = Array(emergencyQueue.prefix(QueuePriority.emergency.maxQueueSize))
        }
        
        if highPriorityQueue.count > QueuePriority.high.maxQueueSize {
            highPriorityQueue = Array(highPriorityQueue.prefix(QueuePriority.high.maxQueueSize))
        }
        
        if normalQueue.count > QueuePriority.normal.maxQueueSize {
            normalQueue = Array(normalQueue.prefix(QueuePriority.normal.maxQueueSize))
        }
        
        if lowPriorityQueue.count > QueuePriority.low.maxQueueSize {
            lowPriorityQueue = Array(lowPriorityQueue.prefix(QueuePriority.low.maxQueueSize))
        }
        
        if backgroundQueue.count > QueuePriority.background.maxQueueSize {
            backgroundQueue = Array(backgroundQueue.prefix(QueuePriority.background.maxQueueSize))
        }
    }
    
    private func reQueueMessage(_ message: QueuedMessage) {
        // Re-queue with potentially lower priority
        var requeuedMessage = message
        
        // Lower priority for retries (except emergency)
        if message.retryCount > 0 && message.priority != .emergency {
            switch message.priority {
            case .high:
                requeuedMessage.priority = .normal
            case .normal:
                requeuedMessage.priority = .low
            case .low:
                requeuedMessage.priority = .background
            default:
                break
            }
        }
        
        enqueueMessage(requeuedMessage)
    }
    
    private func cleanupExpiredMessages() {
        let allQueues = [emergencyQueue, highPriorityQueue, normalQueue, lowPriorityQueue, backgroundQueue]
        
        for (index, queue) in allQueues.enumerated() {
            let validMessages = queue.filter { !$0.isExpired }
            
            switch index {
            case 0:
                emergencyQueue = validMessages
            case 1:
                highPriorityQueue = validMessages
            case 2:
                normalQueue = validMessages
            case 3:
                lowPriorityQueue = validMessages
            case 4:
                backgroundQueue = validMessages
            default:
                break
            }
        }
        
        updateQueueStatistics()
    }
    
    // MARK: - Transmission Window Management
    
    func setTransmissionWindow(_ window: TransmissionWindow) {
        let wasActive = currentTransmissionWindow?.isActive ?? false
        let isActive = window.isActive
        
        currentTransmissionWindow = window
        
        if !wasActive && isActive {
            delegate?.transmissionWindowOpened(window)
        } else if wasActive && !isActive {
            delegate?.transmissionWindowClosed(window)
        }
    }
    
    private func canTransmit(size: Int, cost: Double, in window: TransmissionWindow) -> Bool {
        // Check bandwidth constraints
        let transmissionTime = Double(size * 8) / window.bandwidth // Convert bytes to bits
        guard transmissionTime <= window.timeRemaining else { return false }
        
        // Check cost constraints (if any)
        let totalCost = Double(size) * window.costPerByte
        // Add any additional cost constraints here
        
        return true
    }
    
    // MARK: - Statistics and Monitoring
    
    private func updateQueueStatistics() {
        let messagesByPriority: [QueuePriority: Int] = [
            .emergency: emergencyQueue.count,
            .high: highPriorityQueue.count,
            .normal: normalQueue.count,
            .low: lowPriorityQueue.count,
            .background: backgroundQueue.count
        ]
        
        let totalMessages = messagesByPriority.values.reduce(0, +)
        
        // Calculate average wait time
        let allMessages = emergencyQueue + highPriorityQueue + normalQueue + lowPriorityQueue + backgroundQueue
        let averageWaitTime = allMessages.isEmpty ? 0 : allMessages.reduce(0) { $0 + $1.age } / Double(allMessages.count)
        
        // Calculate success rate
        let totalAttempts = totalMessagesTransmitted + totalMessagesFailed
        let successRate = totalAttempts > 0 ? Double(totalMessagesTransmitted) / Double(totalAttempts) : 0
        
        // Determine queue health
        let queueHealth = determineQueueHealth(totalMessages: totalMessages, averageWaitTime: averageWaitTime)
        
        // Calculate next scheduled transmission
        let nextTransmission = currentTransmissionWindow?.startTime ?? Date().addingTimeInterval(transmissionInterval)
        
        queueStatistics = QueueStatistics(
            totalMessages: totalMessages,
            messagesByPriority: messagesByPriority,
            averageWaitTime: averageWaitTime,
            totalCost: totalCostIncurred,
            successRate: successRate,
            lastTransmission: lastTransmissionTime,
            nextScheduledTransmission: nextTransmission,
            queueHealth: queueHealth
        )
        
        delegate?.queueStatisticsUpdated(queueStatistics)
    }
    
    private func determineQueueHealth(totalMessages: Int, averageWaitTime: TimeInterval) -> QueueStatistics.QueueHealth {
        if totalMessages == 0 {
            return .excellent
        } else if totalMessages < 100 && averageWaitTime < 300 {
            return .excellent
        } else if totalMessages < 500 && averageWaitTime < 1800 {
            return .good
        } else if totalMessages < 1000 && averageWaitTime < 3600 {
            return .fair
        } else if totalMessages < 5000 && averageWaitTime < 7200 {
            return .poor
        } else {
            return .critical
        }
    }
    
    // MARK: - Service Management
    
    private func startQueueServices() {
        // Start cleanup timer
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.cleanupExpiredMessages()
        }
        
        // Start statistics timer
        statisticsTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.updateQueueStatistics()
        }
    }
    
    private func scheduleEmergencyTransmission() {
        // Emergency messages are handled by the emergency timer
        // This method can be used for additional emergency processing
    }
    
    // MARK: - Public Interface
    
    func getQueueStatus() -> (emergency: Int, high: Int, normal: Int, low: Int, background: Int) {
        return (
            emergency: emergencyQueue.count,
            high: highPriorityQueue.count,
            normal: normalQueue.count,
            low: lowPriorityQueue.count,
            background: backgroundQueue.count
        )
    }
    
    func clearQueue(priority: QueuePriority? = nil) {
        if let priority = priority {
            switch priority {
            case .emergency:
                emergencyQueue.removeAll()
            case .high:
                highPriorityQueue.removeAll()
            case .normal:
                normalQueue.removeAll()
            case .low:
                lowPriorityQueue.removeAll()
            case .background:
                backgroundQueue.removeAll()
            }
        } else {
            emergencyQueue.removeAll()
            highPriorityQueue.removeAll()
            normalQueue.removeAll()
            lowPriorityQueue.removeAll()
            backgroundQueue.removeAll()
        }
        
        updateQueueStatistics()
    }
    
    func getMessageById(_ id: String) -> QueuedMessage? {
        let allQueues = [emergencyQueue, highPriorityQueue, normalQueue, lowPriorityQueue, backgroundQueue]
        
        for queue in allQueues {
            if let message = queue.first(where: { $0.id == id }) {
                return message
            }
        }
        
        return nil
    }
    
    func removeMessageById(_ id: String) -> Bool {
        let allQueues = [emergencyQueue, highPriorityQueue, normalQueue, lowPriorityQueue, backgroundQueue]
        
        for (index, queue) in allQueues.enumerated() {
            if let messageIndex = queue.firstIndex(where: { $0.id == id }) {
                switch index {
                case 0:
                    emergencyQueue.remove(at: messageIndex)
                case 1:
                    highPriorityQueue.remove(at: messageIndex)
                case 2:
                    normalQueue.remove(at: messageIndex)
                case 3:
                    lowPriorityQueue.remove(at: messageIndex)
                case 4:
                    backgroundQueue.remove(at: messageIndex)
                default:
                    break
                }
                
                updateQueueStatistics()
                return true
            }
        }
        
        return false
    }
} 