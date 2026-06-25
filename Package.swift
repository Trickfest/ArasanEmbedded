// swift-tools-version: 6.2

import PackageDescription

let arasanCoreSources = [
    "Sources/CArasanEmbedded/AEEngine.mm",
    "Sources/CArasanEmbedded/ArasanEmbeddedUCI.cpp",
    "Sources/CArasanEmbedded/ArasanSyzygyProbe.cpp",
    "ThirdParty/Arasan/src/tester.cpp",
    "ThirdParty/Arasan/src/bench.cpp",
    "ThirdParty/Arasan/src/protocol.cpp",
    "ThirdParty/Arasan/src/input.cpp",
    "ThirdParty/Arasan/src/globals.cpp",
    "ThirdParty/Arasan/src/board.cpp",
    "ThirdParty/Arasan/src/boardio.cpp",
    "ThirdParty/Arasan/src/material.cpp",
    "ThirdParty/Arasan/src/chess.cpp",
    "ThirdParty/Arasan/src/attacks.cpp",
    "ThirdParty/Arasan/src/bitutil.cpp",
    "ThirdParty/Arasan/src/chessio.cpp",
    "ThirdParty/Arasan/src/epdrec.cpp",
    "ThirdParty/Arasan/src/bhash.cpp",
    "ThirdParty/Arasan/src/scoring.cpp",
    "ThirdParty/Arasan/src/see.cpp",
    "ThirdParty/Arasan/src/movearr.cpp",
    "ThirdParty/Arasan/src/notation.cpp",
    "ThirdParty/Arasan/src/options.cpp",
    "ThirdParty/Arasan/src/bitprobe.cpp",
    "ThirdParty/Arasan/src/bookread.cpp",
    "ThirdParty/Arasan/src/bookwrit.cpp",
    "ThirdParty/Arasan/src/search.cpp",
    "ThirdParty/Arasan/src/searchc.cpp",
    "ThirdParty/Arasan/src/learn.cpp",
    "ThirdParty/Arasan/src/movegen.cpp",
    "ThirdParty/Arasan/src/hash.cpp",
    "ThirdParty/Arasan/src/calctime.cpp",
    "ThirdParty/Arasan/src/eco.cpp",
    "ThirdParty/Arasan/src/legal.cpp",
    "ThirdParty/Arasan/src/stats.cpp",
    "ThirdParty/Arasan/src/threadp.cpp",
    "ThirdParty/Arasan/src/threadc.cpp",
    "ThirdParty/Arasan/src/evaluate.cpp",
    "ThirdParty/Arasan/src/syzygy.cpp",
]

let package = Package(
    name: "ArasanEmbedded",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "ArasanEmbedded",
            targets: ["ArasanEmbedded"]
        ),
        .executable(
            name: "arasan-smoke",
            targets: ["ArasanSmoke"]
        ),
    ],
    targets: [
        .target(
            name: "CArasanEmbedded",
            path: ".",
            sources: arasanCoreSources,
            publicHeadersPath: "Sources/CArasanEmbedded/include",
            cxxSettings: [
                .headerSearchPath("ThirdParty/Arasan/src"),
                .headerSearchPath("ThirdParty/Arasan/src/nnue"),
                .headerSearchPath("ThirdParty/Arasan/src/syzygy/src"),
                .define("_64BIT"),
                .define("SYZYGY_TBS"),
                .define("SIMD"),
                .define("NEON"),
                .define("ARASAN_VERSION", to: "embedded-master-ac0b2c14"),
                .define("NETWORK", to: "arasanv8-20260622.nnue"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "ArasanEmbedded",
            dependencies: ["CArasanEmbedded"],
            resources: [
                .copy("../../ThirdParty/Arasan/network/arasanv8-20260622.nnue"),
            ]
        ),
        .executableTarget(
            name: "ArasanSmoke",
            dependencies: ["ArasanEmbedded"]
        ),
        .testTarget(
            name: "ArasanEmbeddedTests",
            dependencies: ["ArasanEmbedded"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
