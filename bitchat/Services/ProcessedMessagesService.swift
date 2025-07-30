import Foundation

/// Service to track processed messages across app restarts to prevent duplicates
@MainActor
final class ProcessedMessagesService {
    static let shared = ProcessedMessagesService()
    
    private let userDefaults = UserDefaults.standard
    private let processedMessagesKey = "ProcessedNostrMessages"
    private let lastProcessedTimestampKey = "LastProcessedNostrTimestamp"
    private let maxStoredMessages = 1000 // Keep last 1000 message IDs
    
    private var processedMessageIDs: Set<String> = []
    private var lastProcessedTimestamp: Date?
    
    private init() {
        loadProcessedMessages()
    }
    
    /// Check if a message has already been processed
    func isMessageProcessed(_ messageID: String) -> Bool {
        return processedMessageIDs.contains(messageID)
    }
    
    /// Mark a message as processed
    func markMessageAsProcessed(_ messageID: String, timestamp: Date) {
        processedMessageIDs.insert(messageID)
        
        // Update last processed timestamp if this message is newer
        if let lastTimestamp = lastProcessedTimestamp {
            if timestamp > lastTimestamp {
                lastProcessedTimestamp = timestamp
            }
        } else {
            lastProcessedTimestamp = timestamp
        }
        
        // Trim if we have too many stored IDs
        if processedMessageIDs.count > maxStoredMessages {
            trimOldestMessages()
        }
        
        saveProcessedMessages()
    }
    
    /// Get the timestamp to use for Nostr subscription filters
    func getSubscriptionSinceDate() -> Date {
        // If we have a last processed timestamp, use it minus a small buffer
        if let lastTimestamp = lastProcessedTimestamp {
            // Go back 1 hour before last processed message for safety
            return lastTimestamp.addingTimeInterval(-3600)
        }
        
        // Default: look back 24 hours on first run
        return Date().addingTimeInterval(-86400)
    }
    
    /// Clear all processed messages (useful for debugging)
    func clearProcessedMessages() {
        processedMessageIDs.removeAll()
        lastProcessedTimestamp = nil
        saveProcessedMessages()
    }
    
    // MARK: - Private Methods
    
    private func loadProcessedMessages() {
        if let data = userDefaults.data(forKey: processedMessagesKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            processedMessageIDs = Set(decoded)
        }
        
        if let timestampInterval = userDefaults.object(forKey: lastProcessedTimestampKey) as? TimeInterval {
            lastProcessedTimestamp = Date(timeIntervalSince1970: timestampInterval)
        }
        
        SecureLogger.log("📋 Loaded \(processedMessageIDs.count) processed message IDs, last timestamp: \(lastProcessedTimestamp?.description ?? "nil")",
                        category: SecureLogger.session, level: .info)
    }
    
    private func saveProcessedMessages() {
        // Convert Set to Array for encoding
        let messageArray = Array(processedMessageIDs)
        if let encoded = try? JSONEncoder().encode(messageArray) {
            userDefaults.set(encoded, forKey: processedMessagesKey)
        }
        
        if let timestamp = lastProcessedTimestamp {
            userDefaults.set(timestamp.timeIntervalSince1970, forKey: lastProcessedTimestampKey)
        }
        
        userDefaults.synchronize()
    }
    
    private func trimOldestMessages() {
        // Since we don't track insertion order, we'll just keep the most recent N messages
        // In a production app, you might want to track timestamps for each message
        let excess = processedMessageIDs.count - maxStoredMessages
        if excess > 0 {
            // Remove random excess messages (not ideal, but simple)
            for _ in 0..<excess {
                if let first = processedMessageIDs.first {
                    processedMessageIDs.remove(first)
                }
            }
        }
    }
}