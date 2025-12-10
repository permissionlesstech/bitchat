//
// PairingTypes.swift
// Remote Terminal - Shared Types
//
// Shared types for device pairing
//

import Foundation

// MARK: - Pairing Info

struct PairingInfo: Equatable {
    let peerID: String
    let deviceName: String
    let expiresAt: Date

    var isExpired: Bool {
        return Date() > expiresAt
    }

    var remainingTime: TimeInterval {
        return expiresAt.timeIntervalSince(Date())
    }

    /// Parse pairing URL components
    static func parse(_ urlString: String) -> PairingInfo? {
        guard let url = URL(string: urlString),
              url.scheme == "bitchat",
              url.host == "pair" else {
            return nil
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }

        var peerID: String?
        var deviceName: String?
        var expiresAt: Date?

        for item in queryItems {
            switch item.name {
            case "peer":
                peerID = item.value
            case "name":
                deviceName = item.value
            case "expires":
                if let timestamp = item.value, let timeInterval = TimeInterval(timestamp) {
                    expiresAt = Date(timeIntervalSince1970: timeInterval)
                }
            default:
                break
            }
        }

        guard let peerID = peerID else { return nil }

        return PairingInfo(
            peerID: peerID,
            deviceName: deviceName ?? "Unknown Mac",
            expiresAt: expiresAt ?? Date().addingTimeInterval(300)
        )
    }
}

// MARK: - Pairing Error

enum PairingError: LocalizedError {
    case noQRCode
    case imageConversionFailed
    case pairingExpired
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .noQRCode:
            return "No QR code available"
        case .imageConversionFailed:
            return "Failed to convert image"
        case .pairingExpired:
            return "Pairing request has expired"
        case .invalidURL:
            return "Invalid pairing URL"
        }
    }
}
