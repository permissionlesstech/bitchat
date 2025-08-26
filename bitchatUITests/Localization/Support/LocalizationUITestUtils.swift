import Foundation

enum LocalizationUITestUtils {
    static let locales: [String] = [
        "es", "fr", "zh-Hans", "ar", "ru",
        "pt-BR", "pt", "hi", "bn", "id", "ja", "de", "tr", "sw", "ur",
        "tl", "ta", "vi", "pcm", "arz", "mr", "te", "ha", "pnb", "yue"
    ]

    static let expectedLocationChannels: [String: String] = [
        "es": "canales de ubicación",
        "fr": "canaux de localisation",
        "zh-Hans": "位置频道",
        "ar": "قنوات الموقع",
        "ru": "каналы местоположения",
        "pt-BR": "canais de localização"
    ]
}
