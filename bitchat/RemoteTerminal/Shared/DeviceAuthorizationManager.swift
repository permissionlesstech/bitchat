//
// DeviceAuthorizationManager.swift
// Remote Terminal - Shared
//
// Manages authorized device storage and validation using Keychain
//

import Foundation
import Security

/// Manages authorized devices for remote terminal access
class DeviceAuthorizationManager {
    // MARK: - Singleton

    static let shared = DeviceAuthorizationManager()

    // MARK: - Properties

    private let service = "com.bitchat.remote-terminal"
    private let authorizedDevicesKey = "authorizedDevices"

    private var cachedAuthorizedDevices: [AuthorizedDevice] = []
    private var cacheLoaded = false

    // MARK: - Public API

    /// Get all authorized devices
    func getAuthorizedDevices() -> [AuthorizedDevice] {
        if !cacheLoaded {
            loadFromKeychain()
        }
        return cachedAuthorizedDevices
    }

    /// Check if device is authorized
    func isAuthorized(peerID: String) -> Bool {
        return getAuthorizedDevices().contains { $0.peerID == peerID }
    }

    /// Authorize a new device
    func authorize(device: AuthorizedDevice) {
        if !cacheLoaded {
            loadFromKeychain()
        }

        // Remove existing if present (update)
        cachedAuthorizedDevices.removeAll { $0.peerID == device.peerID }

        // Add new/updated device
        cachedAuthorizedDevices.append(device)

        // Save to keychain
        saveToKeychain()

        print("✅ Authorized device: \(device.displayName) (\(device.peerID.prefix(16))...)")
    }

    /// Revoke device authorization
    func revoke(peerID: String) {
        if !cacheLoaded {
            loadFromKeychain()
        }

        cachedAuthorizedDevices.removeAll { $0.peerID == peerID }
        saveToKeychain()

        print("🚫 Revoked authorization for peer: \(peerID.prefix(16))...")
    }

    /// Get device info for peer
    func getDevice(peerID: String) -> AuthorizedDevice? {
        return getAuthorizedDevices().first { $0.peerID == peerID }
    }

    /// Update last used timestamp
    func updateLastUsed(peerID: String) {
        if !cacheLoaded {
            loadFromKeychain()
        }

        if let index = cachedAuthorizedDevices.firstIndex(where: { $0.peerID == peerID }) {
            cachedAuthorizedDevices[index].lastUsedAt = Date()
            saveToKeychain()
        }
    }

    /// Clear all authorizations
    func clearAll() {
        cachedAuthorizedDevices.removeAll()
        saveToKeychain()
        print("🗑 Cleared all device authorizations")
    }

    // MARK: - Keychain Operations

    private func loadFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: authorizedDevicesKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess,
           let data = item as? Data,
           let devices = try? JSONDecoder().decode([AuthorizedDevice].self, from: data) {
            cachedAuthorizedDevices = devices
            print("📱 Loaded \(devices.count) authorized device(s) from keychain")
        } else if status == errSecItemNotFound {
            cachedAuthorizedDevices = []
            print("📱 No authorized devices found in keychain")
        } else {
            print("❌ Failed to load authorized devices: \(status)")
            cachedAuthorizedDevices = []
        }

        cacheLoaded = true
    }

    private func saveToKeychain() {
        guard let data = try? JSONEncoder().encode(cachedAuthorizedDevices) else {
            print("❌ Failed to encode authorized devices")
            return
        }

        // Delete existing item
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: authorizedDevicesKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: authorizedDevicesKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecSuccess {
            print("💾 Saved \(cachedAuthorizedDevices.count) authorized device(s) to keychain")
        } else {
            print("❌ Failed to save to keychain: \(status)")
        }
    }
}

// MARK: - Authorized Device Model

struct AuthorizedDevice: Codable, Identifiable, Equatable {
    let id: UUID
    let peerID: String
    var displayName: String
    let pairedAt: Date
    var lastUsedAt: Date
    var permissions: Set<DevicePermission>

    init(
        id: UUID = UUID(),
        peerID: String,
        displayName: String,
        pairedAt: Date = Date(),
        lastUsedAt: Date = Date(),
        permissions: Set<DevicePermission> = [.terminal]
    ) {
        self.id = id
        self.peerID = peerID
        self.displayName = displayName
        self.pairedAt = pairedAt
        self.lastUsedAt = lastUsedAt
        self.permissions = permissions
    }

    var shortPeerID: String {
        String(peerID.prefix(16))
    }

    func hasPermission(_ permission: DevicePermission) -> Bool {
        return permissions.contains(permission)
    }
}

enum DevicePermission: String, Codable, CaseIterable {
    case terminal = "terminal"
    case fileAccess = "file_access"
    case systemControl = "system_control"

    var displayName: String {
        switch self {
        case .terminal:
            return "Terminal Access"
        case .fileAccess:
            return "File Access"
        case .systemControl:
            return "System Control"
        }
    }

    var description: String {
        switch self {
        case .terminal:
            return "Execute shell commands"
        case .fileAccess:
            return "Read and write files"
        case .systemControl:
            return "Control system settings"
        }
    }
}

// MARK: - SwiftUI Views

#if os(iOS)
import SwiftUI

/// Settings view for managing authorized devices
struct AuthorizedDevicesView: View {
    @State private var devices: [AuthorizedDevice] = []
    @State private var showingDeleteConfirmation = false
    @State private var deviceToDelete: AuthorizedDevice?

    var body: some View {
        List {
            if devices.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "laptopcomputer.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    Text("No Authorized Macs")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    Text("Scan QR code to pair with Mac")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else {
                ForEach(devices) { device in
                    DeviceRow(device: device)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deviceToDelete = device
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Revoke", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .navigationTitle("Authorized Macs")
        .onAppear {
            loadDevices()
        }
        .alert("Revoke Access?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                deviceToDelete = nil
            }

            Button("Revoke", role: .destructive) {
                if let device = deviceToDelete {
                    revokeDevice(device)
                }
            }
        } message: {
            if let device = deviceToDelete {
                Text("This will remove terminal access for '\(device.displayName)'. You'll need to pair again to reconnect.")
            }
        }
    }

    private func loadDevices() {
        devices = DeviceAuthorizationManager.shared.getAuthorizedDevices()
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    private func revokeDevice(_ device: AuthorizedDevice) {
        DeviceAuthorizationManager.shared.revoke(peerID: device.peerID)
        loadDevices()
    }
}

struct DeviceRow: View {
    let device: AuthorizedDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "laptopcomputer")
                    .font(.title2)
                    .foregroundColor(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text(device.displayName)
                        .font(.headline)

                    Text("ID: \(device.shortPeerID)...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("Paired")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(device.pairedAt, style: .date)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 8) {
                ForEach(Array(device.permissions), id: \.self) { permission in
                    Text(permission.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }
            }

            if device.lastUsedAt != device.pairedAt {
                Text("Last used: \(device.lastUsedAt, style: .relative)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
}
#endif
