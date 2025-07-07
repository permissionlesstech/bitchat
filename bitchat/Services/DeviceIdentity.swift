import Foundation
import CryptoKit
import Security
#if os(iOS)
import UIKit
#elseif os(macOS)
import IOKit
#endif

/// Provides a unified device identity system with secure key management
final class DeviceIdentity {
    
    // MARK: - Singleton
    
    static let shared = DeviceIdentity()
    
    // MARK: - Properties
    
    private let keychainService = "com.bitchat.deviceidentity"
    private let deviceIDKey = "DeviceID"
    private let privateKeyKey = "PrivateKey"
    
    private var _deviceID: String?
    private var _signingKey: P256.Signing.PrivateKey?
    
    /// The unique 16-character device identifier
    var deviceID: String {
        if let cached = _deviceID {
            return cached
        }
        
        // Try to load from keychain first
        if let stored = loadDeviceID() {
            _deviceID = stored
            return stored
        }
        
        // Generate new device ID
        let newID = generateDeviceID()
        saveDeviceID(newID)
        _deviceID = newID
        return newID
    }
    
    /// The P256 signing key for this device
    var signingKey: P256.Signing.PrivateKey {
        if let cached = _signingKey {
            return cached
        }
        
        // Try to load from keychain first
        if let stored = loadSigningKey() {
            _signingKey = stored
            return stored
        }
        
        // Generate new key pair
        let newKey = P256.Signing.PrivateKey()
        saveSigningKey(newKey)
        _signingKey = newKey
        return newKey
    }
    
    /// The public key for verification
    var publicKey: P256.Signing.PublicKey {
        signingKey.publicKey
    }
    
    /// The public key in x963 representation (65 bytes)
    var publicKeyData: Data {
        signingKey.publicKey.x963Representation
    }
    
    // MARK: - Initialization
    
    private init() {
        // Pre-load device ID and key on initialization
        _ = deviceID
        _ = signingKey
    }
    
    // MARK: - Device ID Generation
    
    private func generateDeviceID() -> String {
        // Get hardware UUID
        let uuid = getHardwareUUID()
        
        // Create SHA256 hash
        let hash = SHA256.hash(data: uuid.data(using: .utf8) ?? Data())
        
        // Convert to hex string and take first 16 characters
        let hexString = hash.compactMap { String(format: "%02x", $0) }.joined()
        return String(hexString.prefix(16))
    }
    
    private func getHardwareUUID() -> String {
        #if os(iOS)
        // On iOS, use identifierForVendor
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #elseif os(macOS)
        // On macOS, use hardware UUID
        let mainPort: mach_port_t
        if #available(macOS 12.0, *) {
            mainPort = kIOMainPortDefault
        } else {
            mainPort = kIOMasterPortDefault
        }
        let platformExpert = IOServiceGetMatchingService(mainPort,
                                                         IOServiceMatching("IOPlatformExpertDevice"))
        guard platformExpert != 0 else {
            return UUID().uuidString
        }
        
        defer { IOObjectRelease(platformExpert) }
        
        guard let serialNumber = IORegistryEntryCreateCFProperty(platformExpert,
                                                                 kIOPlatformUUIDKey as CFString,
                                                                 kCFAllocatorDefault,
                                                                 0).takeRetainedValue() as? String else {
            return UUID().uuidString
        }
        
        return serialNumber
        #else
        return UUID().uuidString
        #endif
    }
    
    // MARK: - Signing and Verification
    
    /// Signs data with the device's private key
    /// - Parameter data: The data to sign
    /// - Returns: The signature
    /// - Throws: If signing fails
    func sign(_ data: Data) throws -> Data {
        let signature = try signingKey.signature(for: data)
        return signature.rawRepresentation
    }
    
    /// Verifies a signature against data using a public key
    /// - Parameters:
    ///   - signature: The signature to verify
    ///   - data: The original data
    ///   - publicKey: The public key to verify with
    /// - Returns: true if the signature is valid
    func verify(signature: Data, for data: Data, using publicKey: P256.Signing.PublicKey) -> Bool {
        guard let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else {
            return false
        }
        return publicKey.isValidSignature(sig, for: data)
    }
    
    /// Verifies a signature against data using x963 public key data
    /// - Parameters:
    ///   - signature: The signature to verify
    ///   - data: The original data
    ///   - publicKeyData: The x963 public key data (65 bytes)
    /// - Returns: true if the signature is valid
    func verify(signature: Data, for data: Data, using publicKeyData: Data) -> Bool {
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData) else {
            return false
        }
        return verify(signature: signature, for: data, using: publicKey)
    }
    
    // MARK: - Keychain Storage
    
    private func saveDeviceID(_ deviceID: String) {
        guard let data = deviceID.data(using: .utf8) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: deviceIDKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        // Delete any existing item
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        SecItemAdd(query as CFDictionary, nil)
    }
    
    private func loadDeviceID() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: deviceIDKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        guard status == errSecSuccess,
              let data = dataTypeRef as? Data,
              let deviceID = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return deviceID
    }
    
    private func saveSigningKey(_ key: P256.Signing.PrivateKey) {
        let data = key.rawRepresentation
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: privateKeyKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        // Delete any existing item
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        SecItemAdd(query as CFDictionary, nil)
    }
    
    private func loadSigningKey() -> P256.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: privateKeyKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        guard status == errSecSuccess,
              let data = dataTypeRef as? Data else {
            return nil
        }
        
        return try? P256.Signing.PrivateKey(rawRepresentation: data)
    }
    
    // MARK: - Reset
    
    /// Resets the device identity by generating new ID and keys
    /// WARNING: This will break continuity with any existing signed data
    func reset() {
        // Clear cached values
        _deviceID = nil
        _signingKey = nil
        
        // Delete from keychain
        let deviceIDQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: deviceIDKey
        ]
        SecItemDelete(deviceIDQuery as CFDictionary)
        
        let privateKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: privateKeyKey
        ]
        SecItemDelete(privateKeyQuery as CFDictionary)
        
        // Force regeneration
        _ = deviceID
        _ = signingKey
    }
}

// MARK: - Convenience Extensions

extension DeviceIdentity {
    /// Creates a signature object from raw signature data
    /// - Parameter data: Raw signature data
    /// - Returns: P256 signature object, or nil if invalid
    func signature(from data: Data) -> P256.Signing.ECDSASignature? {
        try? P256.Signing.ECDSASignature(rawRepresentation: data)
    }
    
    /// Creates a public key object from x963 public key data
    /// - Parameter data: x963 public key data (65 bytes)
    /// - Returns: P256 public key object, or nil if invalid
    func publicKey(from data: Data) -> P256.Signing.PublicKey? {
        try? P256.Signing.PublicKey(x963Representation: data)
    }
}