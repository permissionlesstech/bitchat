//
// RequestSyncManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import BitLogger

/// Manages outgoing sync requests and validates incoming responses.
///
/// Allows attributing RSR (Request-Sync Response) packets to specific peers
/// that we have actively requested sync from.
final class RequestSyncManager {
    
    private let queue = DispatchQueue(label: "request.sync.manager", attributes: .concurrent)
    private var pendingRequests: [PeerID: TimeInterval] = [:]
    
    // Allow responses for 30s after request
    private let responseWindow: TimeInterval = 30.0
    
    /// Register that we are sending a sync request to a peer.
    /// - Parameter peerID: The peer we are requesting sync from
    func registerRequest(to peerID: PeerID) {
        let now = Date().timeIntervalSince1970
        queue.async(flags: .barrier) {
            SecureLogger.debug("Registering sync request to \(peerID.id.prefix(8))…", category: .sync)
            self.pendingRequests[peerID] = now
        }
    }
    
    /// Check if a packet from a peer is a valid response to a sync request.
    ///
    /// - Parameters:
    ///   - peerID: The sender of the packet
    ///   - isRSR: Whether the packet is marked as a Request-Sync Response
    /// - Returns: true if we have a pending request for this peer and the window is open
    func isValidResponse(from peerID: PeerID, isRSR: Bool) -> Bool {
        guard isRSR else { return false }
        
        return queue.sync {
            guard let requestTime = pendingRequests[peerID] else {
                SecureLogger.warning("Received unsolicited RSR packet from \(peerID.id.prefix(8))…", category: .security)
                return false
            }
            
            let now = Date().timeIntervalSince1970
            if now - requestTime > responseWindow {
                SecureLogger.warning("Received RSR packet from \(peerID.id.prefix(8))… outside of response window", category: .security)
                // We don't remove here because we might receive multiple packets for one request
                return false
            }
            
            return true
        }
    }
    
    /// Periodic cleanup of expired requests
    func cleanup() {
        let now = Date().timeIntervalSince1970
        queue.async(flags: .barrier) {
            let originalCount = self.pendingRequests.count
            self.pendingRequests = self.pendingRequests.filter { _, timestamp in
                now - timestamp <= self.responseWindow
            }
            let removed = originalCount - self.pendingRequests.count
            if removed > 0 {
                SecureLogger.debug("Cleaned up \(removed) expired sync requests", category: .sync)
            }
        }
    }
}
