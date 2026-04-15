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
    dependencies: [
        .package(path: "../BitLogger")
    ],
    targets: [
        .target(
            name: "BitFoundation",
            dependencies: [
                .product(name: "BitLogger", package: "BitLogger"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "BitFoundationTests",
            dependencies: ["BitFoundation"],
        )
    ]
)
