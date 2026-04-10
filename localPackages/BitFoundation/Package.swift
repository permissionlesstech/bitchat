// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BitFoundation",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "BitFoundation",
            targets: ["BitFoundation"]
        )
    ],
    targets: [
        .target(
            name: "BitFoundation",
            path: "Sources"
        ),
        .testTarget(
            name: "BitFoundationTests",
            dependencies: ["BitFoundation"],
        )
    ]
)
