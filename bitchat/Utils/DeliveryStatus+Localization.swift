import Foundation

// UI-facing localized labels for DeliveryStatus.
// Prefer using this from SwiftUI views to keep models UI-agnostic.
extension DeliveryStatus {
    var localizedLabel: String {
        switch self {
        case .sending:
            return String(localized: "delivery.sending")
        case .sent:
            return String(localized: "delivery.sent")
        case .delivered(let nickname, _):
            return String(format: String(localized: "delivery.delivered_to"), nickname)
        case .read(let nickname, _):
            return String(format: String(localized: "delivery.read_by"), nickname)
        case .failed(let reason):
            return String(format: String(localized: "delivery.failed"), reason)
        case .partiallyDelivered(let reached, let total):
            return String(format: String(localized: "delivery.partial_ratio"), reached, total)
        }
    }
}

