// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Noise",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "Noise",
            targets: ["Noise"]
        ),
    ],
    dependencies: [
        .package(path: "../BitLogger"),
        .package(path: "../BitFoundation"),
    ],
    targets: [
        .target(
            name: "Noise",
            dependencies: [
                .product(name: "BitLogger", package: "BitLogger"),
                .product(name: "BitFoundation", package: "BitFoundation"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "NoiseTests",
            dependencies: ["Noise"],
            resources: [
                .process("NoiseTestVectors.json")
            ]
        ),
    ]
)
