// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "bitchat",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "bitchat",
            targets: ["bitchat"]
        ),
    ],
    dependencies:[
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.21.1")
    ],
    targets: [
        .executableTarget(
            name: "bitchat",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1"),
                .target(name: "TorC"),
                .target(name: "tor-nolzma")
            ],
            path: "bitchat",
            exclude: [
                "Info.plist",
                "Assets.xcassets",
                "bitchat.entitlements",
                "bitchat-macOS.entitlements",
                "LaunchScreen.storyboard",
                "Services/Tor/C/"
            ],
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .target(
            name: "TorC",
            path: "bitchat/Services/Tor/C"
        ),
        .binaryTarget(
            name: "tor-nolzma",
            path: "Frameworks/tor-nolzma.xcframework"
        ),
        .testTarget(
            name: "bitchatTests",
            dependencies: ["bitchat"],
            path: "bitchatTests",
            exclude: [
                "Info.plist",
                "README.md"
            ]
        )
    ]
)
