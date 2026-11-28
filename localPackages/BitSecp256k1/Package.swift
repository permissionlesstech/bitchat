// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BitSecp256k1",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "BitSecp256k1",
            targets: ["BitSecp256k1"]
        )
    ],
    targets: [
        .target(
            name: "CLibSecp256k1",
            exclude: [
                "COPYING"
            ],
            sources: [
                "secp256k1_wrapper.c",
                "src/precomputed_ecmult.c",
                "src/precomputed_ecmult_gen.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("ECMULT_WINDOW_SIZE", to: "8"),
                .define("COMB_BLOCKS", to: "2"),
                .define("COMB_TEETH", to: "5"),
                .define("ENABLE_MODULE_EXTRAKEYS"),
                .define("ENABLE_MODULE_SCHNORRSIG"),
                .define("ENABLE_MODULE_ECDH")
            ]
        ),
        .target(
            name: "BitSecp256k1",
            dependencies: ["CLibSecp256k1"]
        ),
        .testTarget(
            name: "BitSecp256k1Tests",
            dependencies: ["BitSecp256k1"]
        )
    ],
    cLanguageStandard: .c89
)
