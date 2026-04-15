//
// DeliveryStatus.swift
// BitFoundation
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import struct Foundation.Date

public enum DeliveryStatus: Codable, Equatable, Hashable {
    case sending
    case sent  // Left our device
    case delivered(to: String, at: Date)  // Confirmed by recipient
    case read(by: String, at: Date)  // Seen by recipient
    case failed(reason: String)
    case partiallyDelivered(reached: Int, total: Int)  // For rooms
    
    public var displayText: String {
        switch self {
        case .sending:
            return "Sending..."
        case .sent:
            return "Sent"
        case .delivered(let nickname, _):
            return "Delivered to \(nickname)"
        case .read(let nickname, _):
            return "Read by \(nickname)"
        case .failed(let reason):
            return "Failed: \(reason)"
        case .partiallyDelivered(let reached, let total):
            return "Delivered to \(reached)/\(total)"
        }
    }
}
