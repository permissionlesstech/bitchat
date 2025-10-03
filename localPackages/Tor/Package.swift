// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Tor",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "Tor",
            targets: ["Tor"]
        )
    ],
    dependencies:[
        .package(path: "../BitLogger"),
    ],
    targets: [
        .target(
            name: "Tor",
            dependencies: [
                .product(name: "BitLogger", package: "BitLogger"),
                .target(name: "TorC"),
            ],
            path: "Sources",
            exclude: ["C"]
        ),
        .target(
            name: "TorC",
            dependencies: [
                .target(name: "tor-nolzma")
            ],
            path: "Sources/C",
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .binaryTarget(
            name: "tor-nolzma",
            path: "Frameworks/tor-nolzma.xcframework"
        ),
    ]
)
