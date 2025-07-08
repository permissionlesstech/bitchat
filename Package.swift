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
        .library(
            name: "bitchatLib",
            targets: ["bitchatLib"]),
    ],
    dependencies: [
      .package(url: "https://github.com/apple/swift-crypto.git", .upToNextMajor(from: "1.0.1"))
    ],
    targets: [
        .executableTarget(
            name: "bitchat",
            path: "bitchat"
        ),
        .target(
            name: "bitchatLib",
            dependencies: [
              .product(name: "Crypto", package: "swift-crypto")],
            path: "bitchatLib"),
        .testTarget(
            name: "bitchatTests",
            dependencies: ["bitchatLib"],
            path: "bitchatTests",
        ),
    ]
)