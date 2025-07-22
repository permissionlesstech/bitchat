import Foundation
import CryptoKit

class SpamProtectionService {
    
    // Device reputation tracking
    private var deviceReputations: [String: DeviceReputation] = [:]
    private let reputationThreshold: Int = -10
    private let banDuration: TimeInterval = 3600 // 1 hour
    
    // Temporary bans
    private var bannedDevices: [String: Date] = [:]
    
    // Thread safety
    private let queue = DispatchQueue(label: "chat.bitchat.spam.protection", attributes: .concurrent)
    
    struct DeviceReputation {
        var score: Int = 0
        var handshakeFailures: Int = 0
        var messageSpamCount: Int = 0
        var lastSeen: Date = Date()
        var isWhitelisted: Bool = false
    }
    
    // MARK: - Public Interface
    
    func shouldAllowConnection(from deviceID: String) -> Bool {
        return queue.sync {
            // Check if device is temporarily banned
            if let banExpiry = bannedDevices[deviceID] {
                if Date() < banExpiry {
                    return false // Still banned
                } else {
                    bannedDevices.removeValue(forKey: deviceID) // Ban expired
                }
            }
            
            // Check device reputation
            if let reputation = deviceReputations[deviceID] {
                return reputation.score > reputationThreshold || reputation.isWhitelisted
            }
            
            return true // New device gets benefit of doubt
        }
    }
    
    func recordHandshakeFailure(from deviceID: String) {
        queue.async(flags: .barrier) {
            var reputation = self.deviceReputations[deviceID] ?? DeviceReputation()
            reputation.handshakeFailures += 1
            reputation.score -= 2
            reputation.lastSeen = Date()
            self.deviceReputations[deviceID] = reputation
            
            self.checkForBan(deviceID: deviceID, reputation: reputation)
        }
    }
    
    func recordSpamAttempt(from deviceID: String) {
        queue.async(flags: .barrier) {
            var reputation = self.deviceReputations[deviceID] ?? DeviceReputation()
            reputation.messageSpamCount += 1
            reputation.score -= 5
            reputation.lastSeen = Date()
            self.deviceReputations[deviceID] = reputation
            
            self.checkForBan(deviceID: deviceID, reputation: reputation)
        }
    }
    
    func recordSuccessfulHandshake(from deviceID: String) {
        queue.async(flags: .barrier) {
            var reputation = self.deviceReputations[deviceID] ?? DeviceReputation()
            reputation.score += 1
            reputation.lastSeen = Date()
            self.deviceReputations[deviceID] = reputation
        }
    }
    
    func whitelistDevice(_ deviceID: String) {
        queue.async(flags: .barrier) {
            var reputation = self.deviceReputations[deviceID] ?? DeviceReputation()
            reputation.isWhitelisted = true
            reputation.score = max(reputation.score, 0)
            self.deviceReputations[deviceID] = reputation
            
            // Remove from ban list if present
            self.bannedDevices.removeValue(forKey: deviceID)
        }
    }
    
    // MARK: - Private Helpers
    
    private func checkForBan(deviceID: String, reputation: DeviceReputation) {
        if reputation.score <= reputationThreshold && !reputation.isWhitelisted {
            bannedDevices[deviceID] = Date().addingTimeInterval(banDuration)
            print("🚫 Device \(deviceID) temporarily banned for \(banDuration/60) minutes (score: \(reputation.score))")
        }
    }
    
    // MARK: - Cleanup
    
    func cleanupOldEntries() {
        queue.async(flags: .barrier) {
            let cutoff = Date().addingTimeInterval(-86400) // 24 hours
            
            // Remove old reputation entries
            self.deviceReputations = self.deviceReputations.filter { _, reputation in
                reputation.lastSeen > cutoff || reputation.isWhitelisted
            }
            
            // Remove expired bans
            let now = Date()
            self.bannedDevices = self.bannedDevices.filter { _, banExpiry in
                banExpiry > now
            }
        }
    }
}