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
        .executable(
            name: "arasan-soak",
            targets: ["ArasanSoak"]
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
                // The vendored NNUE implementation requires one explicit SIMD
                // backend. This package currently supports Apple arm64 targets;
                // PackageDescription has no target-architecture condition for
                // selecting NEON versus SSE on a universal macOS build.
                .define("SIMD"),
                .define("NEON"),
                .define("ARASAN_EMBEDDED_STREAM_INPUT"),
                .define("ARASAN_VERSION", to: "embedded-master-c51273aa"),
                .define("NETWORK", to: "arasanv8-20260622.nnue"),
                .define("NDEBUG", .when(configuration: .release)),
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
        .executableTarget(
            name: "ArasanSoak",
            dependencies: ["ArasanEmbedded"],
            resources: [
                .copy("../../Resources/Soak/lichess_puzzles.tsv"),
            ]
        ),
        .target(
            name: "CArasanEmbeddedTestSupport",
            dependencies: ["CArasanEmbedded"],
            path: "Tests/CArasanEmbeddedTestSupport",
            sources: ["ArasanBridgeTesting.cpp", "ArasanHashTesting.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../ThirdParty/Arasan/src"),
                .headerSearchPath("../../ThirdParty/Arasan/src/nnue"),
                .headerSearchPath("../../Sources/CArasanEmbedded"),
                .define("_64BIT"),
                .define("SIMD"),
                .define("NEON"),
                .define("SYZYGY_TBS"),
            ]
        ),
        .testTarget(
            name: "ArasanEmbeddedTests",
            dependencies: ["ArasanEmbedded", "CArasanEmbeddedTestSupport"],
            resources: [
                .copy("../../Resources/OpeningBooks/book.bin"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
