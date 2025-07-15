//
// NoiseChannelKeyRotation.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit

// MARK: - Channel Key Rotation for Forward Secrecy

/// Implements key rotation for channels to provide forward secrecy
/// This is a stepping stone toward full Double Ratchet implementation
class NoiseChannelKeyRotation {
    
    // MARK: - Types
    
    struct KeyEpoch: Codable {
        let epochNumber: UInt64
        let startTime: Date
        let endTime: Date
        let keyCommitment: String
        let previousEpochCommitment: String?
    }
    
    struct RotatedChannelKey {
        let epoch: KeyEpoch
        let key: SymmetricKey
        let isActive: Bool
    }
    
    // MARK: - Constants
    
    private static let epochDuration: TimeInterval = 24 * 60 * 60 // 24 hours
    private static let epochOverlap: TimeInterval = 60 * 60 // 1 hour overlap for late messages
    private static let maxStoredEpochs = 7 // Keep 1 week of history
    
    // MARK: - Properties
    
    private var channelEpochs: [String: [KeyEpoch]] = [:] // channel -> epochs
    private let keychainPrefix = "channel.epoch."
    
    // Thread safety
    private let queue = DispatchQueue(label: "chat.bitchat.noise.keyrotation", attributes: .concurrent)
    
    // MARK: - Public Interface
    
    /// Get the current key for a channel with rotation
    func getCurrentKey(for channel: String, basePassword: String, creatorFingerprint: String) -> RotatedChannelKey? {
        let currentTime = Date()
        
        return queue.sync {
            // Get or create current epoch
            let epoch = getCurrentOrCreateEpoch(for: channel, at: currentTime)
            
            // Derive key for this epoch
            let epochKey = deriveEpochKey(
                basePassword: basePassword,
                channel: channel,
                creatorFingerprint: creatorFingerprint,
                epochNumber: epoch.epochNumber
            )
            
            return RotatedChannelKey(
                epoch: epoch,
                key: epochKey,
                isActive: true
            )
        }
    }
    
    /// Get valid keys for decryption (current + recent epochs)
    func getValidKeysForDecryption(channel: String, basePassword: String, creatorFingerprint: String, messageTime: Date? = nil) -> [RotatedChannelKey] {
        let checkTime = messageTime ?? Date()
        
        return queue.sync {
            let epochs = getValidEpochs(for: channel, at: checkTime)
            
            return epochs.map { epoch in
                let key = deriveEpochKey(
                    basePassword: basePassword,
                    channel: channel,
                    creatorFingerprint: creatorFingerprint,
                    epochNumber: epoch.epochNumber
                )
                
                let isActive = checkTime >= epoch.startTime && checkTime < epoch.endTime
                
                return RotatedChannelKey(
                    epoch: epoch,
                    key: key,
                    isActive: isActive
                )
            }
        }
    }
    
    /// Rotate key for a channel (channel owner only)
    func rotateChannelKey(for channel: String, basePassword: String, creatorFingerprint: String) -> KeyEpoch {
        return queue.sync(flags: .barrier) {
            let currentTime = Date()
            let epochs = channelEpochs[channel] ?? []
            
            // Get current epoch
            let currentEpoch = epochs.last
            let nextEpochNumber = (currentEpoch?.epochNumber ?? 0) + 1
            
            // Create new epoch
            let newEpoch = KeyEpoch(
                epochNumber: nextEpochNumber,
                startTime: currentTime,
                endTime: currentTime.addingTimeInterval(Self.epochDuration),
                keyCommitment: computeEpochKeyCommitment(
                    basePassword: basePassword,
                    channel: channel,
                    creatorFingerprint: creatorFingerprint,
                    epochNumber: nextEpochNumber
                ),
                previousEpochCommitment: currentEpoch?.keyCommitment
            )
            
            // Add to epochs
            var updatedEpochs = epochs
            updatedEpochs.append(newEpoch)
            
            // Trim old epochs
            if updatedEpochs.count > Self.maxStoredEpochs {
                updatedEpochs.removeFirst(updatedEpochs.count - Self.maxStoredEpochs)
            }
            
            channelEpochs[channel] = updatedEpochs
            
            // Persist epochs
            saveEpochs(updatedEpochs, for: channel)
            
            return newEpoch
        }
    }
    
    /// Check if a channel needs key rotation
    func needsKeyRotation(for channel: String) -> Bool {
        return queue.sync {
            guard let epochs = channelEpochs[channel],
                  let currentEpoch = epochs.last else {
                return true // No epochs, needs initial key
            }
            
            // Check if current epoch is near expiration (within 2 hours)
            let timeUntilExpiration = currentEpoch.endTime.timeIntervalSinceNow
            return timeUntilExpiration < 2 * 60 * 60
        }
    }
    
    // MARK: - Private Methods
    
    private func getCurrentOrCreateEpoch(for channel: String, at time: Date) -> KeyEpoch {
        var epochs = channelEpochs[channel] ?? []
        
        // Find current epoch
        if let currentEpoch = epochs.first(where: { epoch in
            time >= epoch.startTime && time < epoch.endTime.addingTimeInterval(Self.epochOverlap)
        }) {
            return currentEpoch
        }
        
        // No valid epoch, create initial one
        let initialEpoch = KeyEpoch(
            epochNumber: 1,
            startTime: time,
            endTime: time.addingTimeInterval(Self.epochDuration),
            keyCommitment: "", // Will be computed when key is derived
            previousEpochCommitment: nil
        )
        
        epochs.append(initialEpoch)
        channelEpochs[channel] = epochs
        
        return initialEpoch
    }
    
    private func getValidEpochs(for channel: String, at time: Date) -> [KeyEpoch] {
        let epochs = channelEpochs[channel] ?? []
        
        // Return epochs that are valid at the given time (including overlap period)
        return epochs.filter { epoch in
            time >= epoch.startTime.addingTimeInterval(-Self.epochOverlap) &&
            time < epoch.endTime.addingTimeInterval(Self.epochOverlap)
        }
    }
    
    private func deriveEpochKey(basePassword: String, channel: String, creatorFingerprint: String, epochNumber: UInt64) -> SymmetricKey {
        // Derive epoch-specific key using base password + epoch number
        let epochSalt = "\(channel)-\(creatorFingerprint)-epoch-\(epochNumber)".data(using: .utf8)!
        let keyData = pbkdf2(
            password: basePassword,
            salt: epochSalt,
            iterations: 210_000, // Same as channel encryption
            keyLength: 32
        )
        return SymmetricKey(data: keyData)
    }
    
    private func computeEpochKeyCommitment(basePassword: String, channel: String, creatorFingerprint: String, epochNumber: UInt64) -> String {
        let epochKey = deriveEpochKey(
            basePassword: basePassword,
            channel: channel,
            creatorFingerprint: creatorFingerprint,
            epochNumber: epochNumber
        )
        
        let commitment = SHA256.hash(data: epochKey.withUnsafeBytes { Data($0) })
        return commitment.map { String(format: "%02x", $0) }.joined()
    }
    
    private func pbkdf2(password: String, salt: Data, iterations: Int, keyLength: Int) -> Data {
        guard let passwordData = password.data(using: .utf8) else {
            return Data()
        }
        
        // Use CryptoKit's safer implementation instead of CommonCrypto
        var derivedKey = Data()
        var blockNum: UInt32 = 1
        
        while derivedKey.count < keyLength {
            var block = salt
            withUnsafeBytes(of: blockNum.bigEndian) { bytes in
                block.append(contentsOf: bytes)
            }
            
            var u = Data(HMAC<SHA256>.authenticationCode(for: block, using: SymmetricKey(data: passwordData)))
            var xor = u
            
            for _ in 1..<iterations {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: SymmetricKey(data: passwordData)))
                for i in 0..<xor.count {
                    xor[i] ^= u[i]
                }
            }
            
            derivedKey.append(xor)
            blockNum += 1
        }
        
        return Data(derivedKey.prefix(keyLength))
    }
    
    // MARK: - Persistence
    
    private func saveEpochs(_ epochs: [KeyEpoch], for channel: String) {
        // Use channel password storage with special prefix for epoch data
        let epochKey = "epoch::\(channel)"
        
        if let data = try? JSONEncoder().encode(epochs),
           let epochString = String(data: data, encoding: .utf8) {
            _ = KeychainManager.shared.saveChannelPassword(epochString, for: epochKey)
        }
    }
    
    private func loadEpochs(for channel: String) -> [KeyEpoch]? {
        let epochKey = "epoch::\(channel)"
        
        guard let epochString = KeychainManager.shared.getChannelPassword(for: epochKey),
              let data = epochString.data(using: .utf8),
              let epochs = try? JSONDecoder().decode([KeyEpoch].self, from: data) else {
            return nil
        }
        
        return epochs
    }
    
    /// Load all saved epochs on initialization
    func loadSavedEpochs() {
        queue.sync(flags: .barrier) {
            // Get all channel passwords and filter for epoch data
            let allPasswords = KeychainManager.shared.getAllChannelPasswords()
            for (key, epochString) in allPasswords where key.hasPrefix("epoch::") {
                let channel = String(key.dropFirst(7)) // Remove "epoch::" prefix
                if let data = epochString.data(using: .utf8),
                   let epochs = try? JSONDecoder().decode([KeyEpoch].self, from: data) {
                    channelEpochs[channel] = epochs
                }
            }
        }
    }
    
    /// Clear all epochs for a channel
    func clearEpochs(for channel: String) {
        queue.sync(flags: .barrier) {
            channelEpochs.removeValue(forKey: channel)
            let epochKey = "epoch::\(channel)"
            _ = KeychainManager.shared.deleteChannelPassword(for: epochKey)
        }
    }
}

// MARK: - Future Double Ratchet Support

/// Placeholder for full Double Ratchet implementation
/// This would handle per-message key derivation and ratcheting
protocol DoubleRatchetProtocol {
    /// Initialize a new ratchet session
    func initializeRatchet(sharedSecret: Data, isInitiator: Bool) throws
    
    /// Ratchet forward and get next message key
    func ratchetEncrypt(_ plaintext: Data) throws -> (ciphertext: Data, header: Data)
    
    /// Ratchet forward using received header and decrypt
    func ratchetDecrypt(_ ciphertext: Data, header: Data) throws -> Data
}

/// Message header for Double Ratchet (future use)
struct RatchetHeader: Codable {
    let publicKey: Data       // Ephemeral public key
    let previousChainLength: UInt32
    let messageNumber: UInt32
}

/// Placeholder for full implementation
class ChannelDoubleRatchet {
    // This would implement the full Double Ratchet algorithm
    // adapted for multi-party channels
    // Challenges:
    // - Sender keys for multi-party
    // - Out-of-order delivery
    // - State synchronization
    // - Performance with many members
}