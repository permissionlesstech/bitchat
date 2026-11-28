// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "bitchat",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "bitchat",
            targets: ["bitchat"]
        )
    ],
    dependencies: [
        .package(path: "localPackages/Arti"),
        .package(path: "localPackages/BitFoundation"),
        .package(path: "localPackages/BitLogger"),
        .package(path: "localPackages/BitSecp256k1")
    ],
    targets: [
        .executableTarget(
            name: "bitchat",
            dependencies: [
                .product(name: "BitSecp256k1", package: "BitSecp256k1"),
                .product(name: "BitFoundation", package: "BitFoundation"),
                .product(name: "BitLogger", package: "BitLogger"),
                .product(name: "Tor", package: "Arti")
            ],
            path: "bitchat",
            exclude: [
                "Info.plist",
                "PrivacyInfo.xcprivacy",
                "Assets.xcassets",
                "_PreviewHelpers/PreviewAssets.xcassets",
                "bitchat.entitlements",
                "bitchat-macOS.entitlements",
                "LaunchScreen.storyboard",
                "ViewModels/Extensions/README.md",
                // Plural-only catalog used by the Xcode app targets alongside
                // Localizations.zlib; SwiftPM compiles Localizable.xcstrings directly.
                "Resources/LocalizablePlurals.xcstrings",
                // Globe picker geometry, bundled by the Xcode app targets and read
                // from Bundle.main; the SwiftPM build only runs tests.
                "Resources/Globe"
            ],
            resources: [
                .process("Localizable.xcstrings")
            ]
        ),
        .testTarget(
            name: "bitchatTests",
            dependencies: [
                "bitchat",
                .product(name: "BitFoundation", package: "BitFoundation")
            ],
            path: "bitchatTests",
            exclude: [
                "Info.plist",
                "README.md",
                // CI perf gate data (read by scripts/check-perf-floors.sh),
                // not a test resource.
                "Performance/perf-floors.json"
            ],
            resources: [
                .process("Localization"),
                // Only the vector fixture: declaring the whole "Noise"
                // directory would claim its .swift test files as resources
                // and silently drop them from compilation.
                .process("Noise/NoiseTestVectors.json"),
                // Frozen envelopes produced by the released iOS (733098bb)
                // and Android (b7f0b33d) private-DM implementations; prove
                // receive compatibility independently of the local generator.
                .process("Nostr/Fixtures")
            ]
        )
    ]
)
