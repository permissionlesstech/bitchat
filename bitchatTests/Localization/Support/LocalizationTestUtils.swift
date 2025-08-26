import Foundation

enum LocalizationTestUtils {
    // Top languages list requested, using BCP-47 tags where appropriate.
    // Use "Base" for English Base fallback.
    static let locales: [String] = [
        "Base", // English (Base)
        "zh-Hans", // Simplified Chinese
        "hi", "es", "ar", "fr", "bn", "pt", "ru", "ur",
        "id", "ja", "de", "pcm", "arz", "mr", "vi", "te", "ha",
        "tr", "pnb", "sw", "tl", "ta", "yue"
    ]

    // Expected translations where we know exact values exist; otherwise tests assert non-empty.
    static let expected: [String: [String: String]] = [
        "accessibility.location_channels": [
            "es": "canales de ubicación",
            "fr": "canaux de localisation",
            "zh-Hans": "位置频道",
            "ar": "قنوات الموقع",
            "ru": "каналы местоположения",
            "pt-BR": "canais de localização"
        ],
        "nav.settings": [
            "es": "Ajustes",
            "fr": "Réglages",
            "zh-Hans": "设置",
            "ar": "الإعدادات",
            "ru": "Настройки",
            "pt-BR": "Ajustes"
        ],
        "help.title": [
            "es": "Cómo usar",
            "fr": "Mode d’emploi",
            "zh-Hans": "使用指南",
            "ar": "كيفية الاستخدام",
            "ru": "Как использовать",
            "pt-BR": "Como usar"
        ]
    ]
}
