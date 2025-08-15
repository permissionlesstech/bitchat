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
    dependencies: [
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.21.1"),
        .package(url: "https://github.com/ybrid/opus-swift.git", from: "0.8.0")
    ],
    targets: [
        .executableTarget(
            name: "bitchat",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "YbridOpus", package: "opus-swift")
            ],
            path: "bitchat",
            exclude: [
                "Info.plist",
                "Info.plist.backup",
                "Assets.xcassets",
                "bitchat.entitlements",
                "bitchat-macOS.entitlements",
                "Frameworks/",
                "Test/",
                "LaunchScreen.storyboard",
                "Wrappers/OpusWrapper_Ybrid.swift.backup",
                "Wrappers/OpusImplementation.swift.backup"
            ]
        ),
    ]
)
