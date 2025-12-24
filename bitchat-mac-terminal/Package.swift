// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BitChatMacTerminal",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "bitchat-terminal", targets: ["BitChatMacTerminal"])
    ],
    targets: [
        .executableTarget(
            name: "BitChatMacTerminal",
            path: "Sources"
        )
    ]
)
