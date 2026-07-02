# AGENTS.md

This repo embeds the Arasan chess engine as an in-process Swift package for
iOS/iPadOS and macOS. It is intended to feel similar to `StockfishEmbedded`,
but it is SwiftPM-first and uses Arasan's MIT-licensed engine code.

## Layout

- `Package.swift` - SwiftPM manifest and package product definitions.
- `Sources/CArasanEmbedded/` - Objective-C++ bridge and Arasan UCI shim.
- `Sources/ArasanEmbedded/` - Swift-facing public API.
- `Sources/ArasanSmoke/` - command-line smoke test executable.
- `Sources/ArasanSoak/` - command-line soak test executable.
- `Tests/ArasanEmbeddedTests/` - package tests.
- `Resources/Soak/` - curated Lichess-derived CC0 positions for soak and
  regression tests.
- `ThirdParty/Arasan/` - vendored Arasan engine source, selected docs, current
  NNUE network file, and Fathom Syzygy probing source from upstream.
- `Docs/` - product documentation and advanced runtime asset guidance.

## Build And Test

Run the normal local release gate before committing behavior changes:

```sh
swift package dump-package
swift build
swift test
swift run arasan-smoke --depth 1
swift run arasan-soak --iterations 5 --movetime 500
xcodebuild -scheme ArasanEmbedded -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -derivedDataPath .build/xcode-ios build
```

Optional external asset coverage downloads and caches a tiny Syzygy fixture:

```sh
Scripts/test-external-assets.sh
```

## Vendored Arasan

Arasan is vendored from `https://github.com/jdart1/arasan-chess`.
The current vendored upstream commit is:

```text
36774cd7581685491ad0e0f77ec7b3a0a5763376
```

The Fathom Syzygy probing submodule is materialized as normal files under
`ThirdParty/Arasan/src/syzygy` so this repo is self-contained.

When updating Arasan:

1. Fetch latest upstream `master`.
2. Re-vendor only the engine source, selected upstream docs, required NNUE, and
   materialized Fathom source; do not vendor GUI/font assets, tools, upstream
   tests, opening-book source material, or nested `.git` directories.
3. Check whether the default NNUE filename changed.
4. Keep only the NNUE file required by the current vendored Arasan snapshot.
5. Update `README.md`, `Docs/UpdatingArasan.md`, and `Docs/Provenance.md`.
6. Run the local release gate.

## Product Boundaries

`ArasanEmbedded` starts Arasan, applies resource-related UCI options, sends UCI
commands, and returns UCI output lines. It does not parse rich UCI models, own
chess rules, mutate FEN, choose engine policy, or render UI. Those concerns
belong in `SwiftChessTools` or the consuming app.

## Licensing

The package-owned wrapper code is MIT licensed. Vendored Arasan source and the
bundled network file are MIT licensed by Jon Dart. Preserve upstream notices and
do not remove provenance files from `ThirdParty/Arasan`.
