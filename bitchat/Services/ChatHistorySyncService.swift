//
//  ChatHistorySyncService.swift
//  bitchat
//
//  Created by Waluya Juang Husada on 20/08/25.
//


//
// ChatHistorySyncService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Service responsible for managing chat history synchronization between peers
class ChatHistorySyncService {
    static let shared = ChatHistorySyncService()
    
    private var syncInProgress: Set<String> = []
    private var pendingRequests: [String: HistoryRequest] = [:]
    private let maxRetries = 3
    private var retryCount: [String: Int] = [:]
    
    private init() {}
    
    // MARK: - Sync Status Management
    
    /// Check if sync is in progress for a specific peer
    func isSyncInProgress(for peerID: String) -> Bool {
        return syncInProgress.contains(peerID)
    }
    
    /// Mark sync as started for a peer
    func startSync(for peerID: String) {
        syncInProgress.insert(peerID)
    }
    
    /// Mark sync as completed for a peer
    func completeSync(for peerID: String) {
        syncInProgress.remove(peerID)
        pendingRequests.removeValue(forKey: peerID)
        retryCount.removeValue(forKey: peerID)
    }
    
    /// Mark sync as failed for a peer
    func failSync(for peerID: String) {
        let currentRetries = retryCount[peerID] ?? 0
        if currentRetries < maxRetries {
            retryCount[peerID] = currentRetries + 1
            // Keep sync in progress for retry
        } else {
            // Max retries reached, give up
            completeSync(for: peerID)
        }
    }
    
    // MARK: - Request Management
    
    /// Store a pending request
    func storePendingRequest(_ request: HistoryRequest, for peerID: String) {
        pendingRequests[peerID] = request
    }
    
    /// Get pending request for a peer
    func getPendingRequest(for peerID: String) -> HistoryRequest? {
        return pendingRequests[peerID]
    }
    
    /// Remove pending request for a peer
    func removePendingRequest(for peerID: String) {
        pendingRequests.removeValue(forKey: peerID)
    }
    
    // MARK: - Utility Methods
    
    /// Get the last message ID for a peer to request incremental sync
    func getLastMessageID(for peerID: String, from messages: [BitchatMessage]) -> String? {
        return messages.last?.id
    }
    
    /// Merge received messages with existing messages, avoiding duplicates
    func mergeMessages(_ newMessages: [BitchatMessage], with existingMessages: [BitchatMessage]) -> [BitchatMessage] {
        var mergedMessages = existingMessages
        
        for newMessage in newMessages {
            // Check if message already exists
            if !mergedMessages.contains(where: { $0.id == newMessage.id }) {
                mergedMessages.append(newMessage)
            }
        }
        
        // Sort by timestamp
        mergedMessages.sort { $0.timestamp < $1.timestamp }
        
        return mergedMessages
    }
    
    // MARK: - Request/Response Encoding
    
    /// Encode history request to binary data
    func encodeHistoryRequest(_ request: HistoryRequest) -> Data? {
        do {
            let data = try JSONEncoder().encode(request)
            return data
        } catch {
            print("Failed to encode history request: \(error)")
            return nil
        }
    }
    
    /// Decode history request from binary data
    func decodeHistoryRequest(from data: Data) -> HistoryRequest? {
        do {
            let request = try JSONDecoder().decode(HistoryRequest.self, from: data)
            return request
        } catch {
            print("Failed to decode history request: \(error)")
            return nil
        }
    }
    
    /// Encode history response to binary data
    func encodeHistoryResponse(_ response: HistoryResponse) -> Data? {
        do {
            let data = try JSONEncoder().encode(response)
            return data
        } catch {
            print("Failed to encode history response: \(error)")
            return nil
        }
    }
    
    /// Decode history response from binary data
    func decodeHistoryResponse(from data: Data) -> HistoryResponse? {
        do {
            let response = try JSONDecoder().decode(HistoryResponse.self, from: data)
            return response
        } catch {
            print("Failed to decode history response: \(error)")
            return nil
        }
    }
    
    /// Encode history sync to binary data
    func encodeHistorySync(_ sync: HistorySync) -> Data? {
        do {
            let data = try JSONEncoder().encode(sync)
            return data
        } catch {
            print("Failed to encode history sync: \(error)")
            return nil
        }
    }
    
    /// Decode history sync from binary data
    func decodeHistorySync(from data: Data) -> HistorySync? {
        do {
            let sync = try JSONDecoder().decode(HistorySync.self, from: data)
            return sync
        } catch {
            print("Failed to decode history sync: \(error)")
            return nil
        }
    }
    
    /// End sync for a peer (alias for completeSync for backward compatibility)
    func endSync(for peerID: String) {
        completeSync(for: peerID)
    }
    
    // MARK: - Message Comparison
    
    /// Compare two message arrays and find missing messages
    func findMissingMessages(local: [BitchatMessage], remote: [BitchatMessage]) -> [BitchatMessage] {
        let localIDs = Set(local.map { $0.id })
        let missing = remote.filter { !localIDs.contains($0.id) }
        return missing.sorted { $0.timestamp < $1.timestamp }
    }
    
    /// Clean up old sync data
    func cleanup() {
        syncInProgress.removeAll()
        pendingRequests.removeAll()
        retryCount.removeAll()
    }
}
