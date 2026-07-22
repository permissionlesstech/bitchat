import Foundation

/// One-tap "quick join" targets for people in countries with heavy internet
/// censorship. First-time users there may be unable or unwilling to grant
/// location access, so the channel sheet offers their country's region-level
/// geohash channel directly — same effect as typing the geohash and
/// teleporting, no GPS involved.
///
/// Codes are ISO 3166-1 alpha-2 so display names localize for free through
/// Locale; each geohash is the 2-character (region) cell over the country's
/// main population center.
struct QuickJoinRegion: Identifiable {
    let regionCode: String
    let geohash: String
    var id: String { regionCode }

    /// Regional-indicator flag emoji derived from the ISO code.
    var flag: String {
        regionCode.unicodeScalars.reduce(into: "") { result, scalar in
            if let indicator = Unicode.Scalar(127397 + scalar.value) {
                result.unicodeScalars.append(indicator)
            }
        }
    }

    var localizedName: String {
        Locale.current.localizedString(forRegionCode: regionCode) ?? regionCode
    }

    /// Countries consistently rated worst for internet freedom (Freedom
    /// House "not free" tier / RSF), each with the region geohash of its
    /// largest population center.
    static let all: [QuickJoinRegion] = [
        QuickJoinRegion(regionCode: "BY", geohash: "u9"),  // Minsk
        QuickJoinRegion(regionCode: "CN", geohash: "wx"),  // Beijing
        QuickJoinRegion(regionCode: "CU", geohash: "dh"),  // Havana
        QuickJoinRegion(regionCode: "ER", geohash: "sf"),  // Asmara
        QuickJoinRegion(regionCode: "IR", geohash: "tn"),  // Tehran
        QuickJoinRegion(regionCode: "KP", geohash: "wy"),  // Pyongyang
        QuickJoinRegion(regionCode: "MM", geohash: "w4"),  // Yangon
        QuickJoinRegion(regionCode: "RU", geohash: "uc"),  // Moscow
        QuickJoinRegion(regionCode: "SY", geohash: "sv"),  // Damascus
        QuickJoinRegion(regionCode: "TM", geohash: "tq"),  // Ashgabat
        QuickJoinRegion(regionCode: "VE", geohash: "d9"),  // Caracas
        QuickJoinRegion(regionCode: "VN", geohash: "w7"),  // Hanoi
    ]

    static var sortedByName: [QuickJoinRegion] {
        all.sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
    }
}
