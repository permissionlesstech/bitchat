// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Nostr",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "Nostr",
            targets: ["Nostr"]
        ),
    ],
    dependencies: [
        .package(path: "../BitLogger"),
        .package(path: "../BitFoundation"),
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.21.1"),
    ],
    targets: [
        .target(
            name: "Nostr",
            dependencies: [
                .product(name: "BitLogger", package: "BitLogger"),
                .product(name: "BitFoundation", package: "BitFoundation"),
                .product(name: "P256K", package: "swift-secp256k1"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "NostrTests",
            dependencies: ["Nostr"]
        ),
    ]
)
