import Foundation
import CoreBluetooth
import CryptoKit
import SwiftUI
import Security
import LocalAuthentication

/// Service responsible for secure Bluetooth device authentication and pairing
class BluetoothAuthenticationService: NSObject, ObservableObject {
    
    // MARK: - Properties
    
    @Published private(set) var isPairing = false
    @Published private(set) var pendingConnections: [PendingConnection] = []
    @Published private(set) var whitelistedDevices: Set<WhitelistedDevice> = []
    
    private let keychain = KeychainService()
    private let secureStorage: SecureStorageService
    private var activeChallenges: [UUID: ChallengeData] = [:]
    private var connectionCallbacks: [UUID: (Bool) -> Void] = [:]
    
    // MARK: - Constants
    
    private enum Constants {
        static let pinLength = 6
        static let challengeLength = 32
        static let challengeTimeout: TimeInterval = 30
        static let maxPairingAttempts = 3
        static let whitelistKey = "bluetooth_whitelist"
        static let deviceKeysPrefix = "device_key_"
    }
    
    // MARK: - Models
    
    struct PendingConnection: Identifiable {
        let id = UUID()
        let peripheral: CBPeripheral
        let timestamp: Date
        let rssi: Int
        var attempts: Int = 0
    }
    
    struct WhitelistedDevice: Codable, Hashable {
        let identifier: UUID
        let name: String
        let publicKeyBase64: String
        let addedDate: Date
        let lastConnected: Date?
        
        var publicKey: Data {
            return Data(base64Encoded: publicKeyBase64) ?? Data()
        }
        
        init(identifier: UUID, name: String, publicKey: Data, addedDate: Date, lastConnected: Date?) {
            self.identifier = identifier
            self.name = name
            self.publicKeyBase64 = publicKey.base64EncodedString()
            self.addedDate = addedDate
            self.lastConnected = lastConnected
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(identifier)
        }
        
        static func == (lhs: WhitelistedDevice, rhs: WhitelistedDevice) -> Bool {
            lhs.identifier == rhs.identifier
        }
    }
    
    private struct ChallengeData {
        let challenge: Data
        let timestamp: Date
        let peripheral: CBPeripheral
    }
    
    // MARK: - Initialization
    
    override init() throws {
        self.secureStorage = try SecureStorageService()
        super.init()
        loadWhitelist()
        startChallengeCleanupTimer()
    }
    
    // MARK: - Public Methods
    
    /// Initiates pairing with a peripheral device
    func initiatePairing(with peripheral: CBPeripheral, completion: @escaping (Bool, Error?) -> Void) {
        guard !isPairing else {
            completion(false, BluetoothError.alreadyPairing)
            return
        }
        
        isPairing = true
        
        // Generate and display PIN for user verification
        let pin = generatePIN()
        
        DispatchQueue.main.async {
            self.showPairingDialog(peripheral: peripheral, pin: pin) { [weak self] approved in
                guard let self = self else { return }
                
                if approved {
                    self.performPairing(peripheral: peripheral, pin: pin, completion: completion)
                } else {
                    self.isPairing = false
                    completion(false, BluetoothError.pairingRejectedByUser)
                }
            }
        }
    }
    
    /// Authenticates an incoming connection request
    func authenticateConnection(from peripheral: CBPeripheral, completion: @escaping (Bool) -> Void) {
        // Check if device is whitelisted
        if isWhitelisted(peripheral) {
            // Perform challenge-response authentication
            performChallengeResponse(with: peripheral, completion: completion)
        } else {
            // Add to pending connections for user approval
            let pending = PendingConnection(
                peripheral: peripheral,
                timestamp: Date(),
                rssi: -50 // Default RSSI, should be provided by actual scan
            )
            
            DispatchQueue.main.async {
                self.pendingConnections.append(pending)
                self.showConnectionApprovalDialog(for: pending, completion: completion)
            }
        }
    }
    
    /// Verifies identity during key exchange
    func verifyIdentityForKeyExchange(peripheral: CBPeripheral, publicKey: Data) -> Bool {
        guard let whitelistedDevice = getWhitelistedDevice(for: peripheral) else {
            return false
        }
        
        // Verify the public key matches the stored one
        return whitelistedDevice.publicKey == publicKey
    }
    
    /// Adds a device to the whitelist
    func addToWhitelist(peripheral: CBPeripheral, publicKey: Data, name: String) {
        let device = WhitelistedDevice(
            identifier: peripheral.identifier,
            name: name,
            publicKey: publicKey,
            addedDate: Date(),
            lastConnected: nil
        )
        
        whitelistedDevices.insert(device)
        saveWhitelist()
    }
    
    /// Removes a device from the whitelist
    func removeFromWhitelist(deviceId: UUID) {
        whitelistedDevices.removeAll { $0.identifier == deviceId }
        saveWhitelist()
        
        // Remove stored keys
        try? keychain.deleteItem(key: Constants.deviceKeysPrefix + deviceId.uuidString)
    }
    
    /// Updates last connected time for a whitelisted device
    func updateLastConnected(for peripheral: CBPeripheral) {
        guard var device = getWhitelistedDevice(for: peripheral) else { return }
        
        whitelistedDevices.remove(device)
        device = WhitelistedDevice(
            identifier: device.identifier,
            name: device.name,
            publicKey: device.publicKey,
            addedDate: device.addedDate,
            lastConnected: Date()
        )
        whitelistedDevices.insert(device)
        saveWhitelist()
    }
    
    // MARK: - Private Methods
    
    private func generatePIN() -> String {
        let digits = "0123456789"
        return String((0..<Constants.pinLength).map { _ in
            digits.randomElement()!
        })
    }
    
    private func generateChallenge() -> Data {
        var bytes = [UInt8](repeating: 0, count: Constants.challengeLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, Constants.challengeLength, &bytes)
        return Data(bytes)
    }
    
    private func performPairing(peripheral: CBPeripheral, pin: String, completion: @escaping (Bool, Error?) -> Void) {
        // This would integrate with the actual Bluetooth pairing process
        // For now, we'll simulate the pairing flow
        
        // Generate key pair for this device
        let privateKey = P256.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey
        
        // Store the keys securely
        do {
            let keyData = try JSONEncoder().encode([
                "private": privateKey.rawRepresentation.base64EncodedString(),
                "public": publicKey.rawRepresentation.base64EncodedString()
            ])
            
            try keychain.storeItem(
                keyData,
                key: Constants.deviceKeysPrefix + peripheral.identifier.uuidString,
                accessibility: .whenUnlockedThisDeviceOnly
            )
            
            // Add to whitelist
            addToWhitelist(
                peripheral: peripheral,
                publicKey: publicKey.rawRepresentation,
                name: peripheral.name ?? "Unknown Device"
            )
            
            isPairing = false
            completion(true, nil)
        } catch {
            isPairing = false
            completion(false, error)
        }
    }
    
    private func performChallengeResponse(with peripheral: CBPeripheral, completion: @escaping (Bool) -> Void) {
        // Generate challenge
        let challenge = generateChallenge()
        let challengeData = ChallengeData(
            challenge: challenge,
            timestamp: Date(),
            peripheral: peripheral
        )
        
        activeChallenges[peripheral.identifier] = challengeData
        connectionCallbacks[peripheral.identifier] = completion
        
        // Send challenge to peripheral (this would be done through the Bluetooth service)
        // For now, we'll simulate the response
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.handleChallengeResponse(
                from: peripheral,
                response: challenge // In reality, this would be signed/encrypted
            )
        }
    }
    
    private func handleChallengeResponse(from peripheral: CBPeripheral, response: Data) {
        guard let challengeData = activeChallenges[peripheral.identifier],
              let completion = connectionCallbacks[peripheral.identifier] else {
            return
        }
        
        // Verify response timing
        let elapsed = Date().timeIntervalSince(challengeData.timestamp)
        guard elapsed < Constants.challengeTimeout else {
            completion(false)
            cleanupChallenge(for: peripheral.identifier)
            return
        }
        
        // Verify response (in reality, this would check cryptographic signature)
        let isValid = response == challengeData.challenge
        
        if isValid {
            updateLastConnected(for: peripheral)
        }
        
        completion(isValid)
        cleanupChallenge(for: peripheral.identifier)
    }
    
    private func cleanupChallenge(for identifier: UUID) {
        activeChallenges.removeValue(forKey: identifier)
        connectionCallbacks.removeValue(forKey: identifier)
    }
    
    private func startChallengeCleanupTimer() {
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.cleanupExpiredChallenges()
        }
    }
    
    private func cleanupExpiredChallenges() {
        let now = Date()
        let expiredIds = activeChallenges.compactMap { (id, data) -> UUID? in
            let elapsed = now.timeIntervalSince(data.timestamp)
            return elapsed > Constants.challengeTimeout ? id : nil
        }
        
        for id in expiredIds {
            if let completion = connectionCallbacks[id] {
                completion(false)
            }
            cleanupChallenge(for: id)
        }
    }
    
    private func isWhitelisted(_ peripheral: CBPeripheral) -> Bool {
        whitelistedDevices.contains { $0.identifier == peripheral.identifier }
    }
    
    private func getWhitelistedDevice(for peripheral: CBPeripheral) -> WhitelistedDevice? {
        whitelistedDevices.first { $0.identifier == peripheral.identifier }
    }
    
    private func loadWhitelist() {
        guard let data = try? secureStorage.retrieveData(for: Constants.whitelistKey),
              let devices = try? JSONDecoder().decode(Set<WhitelistedDevice>.self, from: data) else {
            return
        }
        whitelistedDevices = devices
    }
    
    private func saveWhitelist() {
        guard let data = try? JSONEncoder().encode(whitelistedDevices) else { return }
        try? secureStorage.storeData(data, for: Constants.whitelistKey)
    }
    
    // MARK: - UI Dialogs
    
    private func showPairingDialog(peripheral: CBPeripheral, pin: String, completion: @escaping (Bool) -> Void) {
        // This would show a SwiftUI dialog
        // For now, we'll use a placeholder implementation
        let alert = PairingAlert(
            deviceName: peripheral.name ?? "Unknown Device",
            pin: pin,
            onConfirm: { completion(true) },
            onCancel: { completion(false) }
        )
        
        // Present the alert (this would be done through the app's UI layer)
        NotificationCenter.default.post(
            name: .showPairingAlert,
            object: alert
        )
    }
    
    private func showConnectionApprovalDialog(for connection: PendingConnection, completion: @escaping (Bool) -> Void) {
        let alert = ConnectionApprovalAlert(
            deviceName: connection.peripheral.name ?? "Unknown Device",
            deviceId: connection.peripheral.identifier,
            rssi: connection.rssi,
            onApprove: { [weak self] in
                self?.pendingConnections.removeAll { $0.id == connection.id }
                self?.initiatePairing(with: connection.peripheral) { success, _ in
                    completion(success)
                }
            },
            onDeny: { [weak self] in
                self?.pendingConnections.removeAll { $0.id == connection.id }
                completion(false)
            }
        )
        
        NotificationCenter.default.post(
            name: .showConnectionApprovalAlert,
            object: alert
        )
    }
}

// MARK: - Alert Models

struct PairingAlert {
    let deviceName: String
    let pin: String
    let onConfirm: () -> Void
    let onCancel: () -> Void
}

struct ConnectionApprovalAlert {
    let deviceName: String
    let deviceId: UUID
    let rssi: Int
    let onApprove: () -> Void
    let onDeny: () -> Void
}

// MARK: - Notification Names

extension Notification.Name {
    static let showPairingAlert = Notification.Name("showPairingAlert")
    static let showConnectionApprovalAlert = Notification.Name("showConnectionApprovalAlert")
}

// MARK: - Error Types

enum BluetoothError: LocalizedError {
    case alreadyPairing
    case pairingRejectedByUser
    case pairingTimeout
    case invalidChallenge
    case deviceNotWhitelisted
    
    var errorDescription: String? {
        switch self {
        case .alreadyPairing:
            return "Already pairing with another device"
        case .pairingRejectedByUser:
            return "Pairing rejected by user"
        case .pairingTimeout:
            return "Pairing timeout"
        case .invalidChallenge:
            return "Invalid authentication challenge"
        case .deviceNotWhitelisted:
            return "Device not in whitelist"
        }
    }
}