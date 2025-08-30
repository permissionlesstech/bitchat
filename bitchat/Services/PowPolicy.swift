import Foundation

/// Simple default policy for NIP-13 difficulty on geohash chats.
/// Progressive by geohash precision; adjustable later by live activity.
enum PowPolicy {
    /// Determine target bits for a given geohash string.
    /// Clamped to a sane range to keep UX responsive on phones.
    static func requiredBits(forGeohash geohash: String) -> Int {
        let precision = geohash.count
        // Start at 16 and go down with higher precision (smaller areas)
        switch precision {
        case ...5: return 10
        case 6:    return 9
        default:   return 8
        }
    }
}
