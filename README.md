# ArasanEmbedded

`ArasanEmbedded` embeds the MIT-licensed Arasan chess engine in a Swift package
for Apple-platform chess apps. It exposes a small Swift API for starting Arasan,
configuring runtime assets, sending UCI commands, and receiving UCI output.

This package is intentionally narrow. It is not a chess rules library, not a
SwiftUI board, and not a full analysis framework. Use `SwiftChessTools` for
rules, notation, UI, and UCI parsing helpers; use `ArasanEmbedded` when an app
needs a permissively licensed in-process engine.

## Status

This repository is a SwiftPM-first embedded Arasan package for iOS, iPadOS, and
macOS. It includes a root `Package.swift`, SPI metadata, semantic-versioned
releases, package tests, CI, and product documentation.

`ArasanEmbedded` is suitable for Swift Package Index submission. SPI indexing
requires the GitHub repository to be public and a semantic version tag to be
available on the default branch.

## Requirements

- Swift 6.2 or newer
- Xcode 26 or newer
- iOS/iPadOS 26 or newer
- macOS 26 or newer

## Installation

Add the package through SwiftPM or Xcode:

```swift
.package(url: "https://github.com/Trickfest/ArasanEmbedded.git", from: "1.0.0")
```

Then depend on the library product:

```swift
.product(name: "ArasanEmbedded", package: "ArasanEmbedded")
```

## Quick Start

```swift
import ArasanEmbedded

let engine = ArasanEngine { line in
    print(line)
}

try engine.start()
engine.sendCommand("position startpos moves e2e4")
engine.sendCommand("go depth 8")

// Watch the line handler for `bestmove ...`, then stop when finished.
engine.stop()
```

`start()` sends `uci`, applies the configured resource options, and sends
`isready`. A production app should wait for `uciok` and `readyok` before
starting a search.

## Runtime Assets

Arasan uses several optional or required runtime assets. `ArasanEmbedded` makes
those choices explicit:

- NNUE network: bundled by default.
- Opening book: supported, but disabled by default.
- Syzygy tablebases: supported through caller-provided paths, but not bundled.

The default configuration is intentionally predictable:

```swift
let engine = ArasanEngine(configuration: .default) { line in
    print(line)
}
```

That uses the bundled NNUE file, disables opening book moves, and disables
tablebase probing.

## Opening Book

Opening books make the engine play precomputed opening moves instead of
searching from the first move. `ArasanEmbedded` leaves this off by default so
tests and examples are deterministic.

Enable a caller-provided Arasan `book.bin` file:

```swift
let bookURL = Bundle.main.url(forResource: "book", withExtension: "bin")!

let configuration = ArasanEngine.Configuration(
    useOpeningBook: true,
    openingBookURL: bookURL
)

let engine = ArasanEngine(configuration: configuration) { line in
    print(line)
}
```

This maps to Arasan's UCI options:

```text
setoption name BookPath value /path/to/book.bin
setoption name OwnBook value true
```

## Syzygy Tablebases

Syzygy tablebases provide perfect endgame knowledge for positions with a small
number of pieces. They are useful, but too large to bundle in a normal Swift
package. Even 5-piece Syzygy is close to a gigabyte; 6-piece and 7-piece sets
are far larger.

Enable a user-provided tablebase directory:

```swift
let tablebaseURL = URL(fileURLWithPath: "/Users/me/Chess/Syzygy345")

let configuration = ArasanEngine.Configuration(
    useTablebases: true,
    tablebaseDirectoryURL: tablebaseURL,
    tablebaseProbeDepth: 4,
    syzygyUses50MoveRule: true
)

let engine = ArasanEngine(configuration: configuration) { line in
    print(line)
}
```

This maps to Arasan's UCI options:

```text
setoption name SyzygyPath value /Users/me/Chess/Syzygy345
setoption name SyzygyProbeDepth value 4
setoption name SyzygyUse50MoveRule value true
setoption name Use tablebases value true
```

See `Docs/Tablebases.md` for iOS/macOS storage guidance and failure behavior.

## Testing

See `Docs/Testing.md` for the full local release gate, XCTest suite structure,
`arasan-smoke`, `arasan-soak`, CI coverage, and the Lichess-derived regression
corpus.

## Relationship To SwiftChessTools

`ArasanEmbedded` speaks UCI. `SwiftChessTools` provides reusable chess rules,
notation, UI, and `ChessUCI` helpers that can parse or format UCI around an
engine. A realistic app should usually combine both packages rather than making
the engine wrapper responsible for game state or UI.

## Relationship To SwiftChessDemo

`SwiftChessDemo` shows how a real app can combine Swift chess rules/UI with an
embedded engine. Today it uses `StockfishEmbedded`; `ArasanEmbedded` is intended
to provide a permissively licensed alternative with a similar integration shape.

## Licensing

Package-owned code is MIT licensed. The vendored Arasan engine source, selected
upstream documentation, bundled NNUE file, and Fathom Syzygy probing source keep
their upstream notices. GUI/font assets, upstream test suites, tools, and
opening-book source material are intentionally not vendored into this package.
See `LICENSE` and `Docs/Provenance.md`.
