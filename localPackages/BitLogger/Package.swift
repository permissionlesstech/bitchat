// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BitLogger",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "BitLogger",
            targets: ["BitLogger"]
        )
    ],
    targets: [
        .target(
            name: "BitLogger",
            path: "Sources"
        ),
        .testTarget(
            name: "BitLoggerTests",
            dependencies: ["BitLogger"]
        )
    ]
)
