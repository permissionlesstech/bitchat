// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tor",  // Keep name "Tor" for drop-in compatibility
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
    dependencies: [
        .package(path: "../BitLogger")
    ],
    targets: [
        // Main Swift target
        .target(
            name: "Tor",
            dependencies: [
                "arti",
                .target(
                    name: "IPtProxy",
                    condition: .when(platforms: [.iOS])
                ),
                .product(name: "BitLogger", package: "BitLogger")
            ],
            path: "Sources",
            exclude: ["C"],
            sources: [
                "TorManager.swift",
                "TorTransport.swift",
                "TorTransportDiagnostic.swift",
                "TorURLSession.swift",
                "TorNotifications.swift"
            ],
            linkerSettings: [
                .linkedLibrary("resolv"),
                .linkedLibrary("z"),
                .linkedLibrary("sqlite3")
            ]
        ),
        // Binary framework containing the Rust static library.
        // Provenance and rebuild steps: repo-root docs/ARTI-BINARY-PROVENANCE.md
        .binaryTarget(
            name: "arti",
            path: "Frameworks/arti.xcframework"
        ),
        // Contains iOS device and simulator slices only. Pluggable transports
        // are not built for macOS, and the Swift callers compile only on iOS.
        .binaryTarget(
            name: "IPtProxy",
            path: "Frameworks/IPtProxy.xcframework"
        )
    ]
)
