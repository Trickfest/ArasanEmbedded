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
releases, package tests, an optional manually dispatched GitHub Actions
workflow, and product documentation.

`ArasanEmbedded` is suitable for Swift Package Index submission. SPI indexing
requires the GitHub repository to be public and a semantic version tag to be
available on the default branch.

## Requirements

- Swift 6.2 or newer
- Xcode 26 or newer
- iOS/iPadOS 26 or newer
- macOS 26 or newer
- Apple Silicon/arm64 build targets. Intel macOS and x86_64 simulator builds
  are not supported by the current package build configuration.

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

## Runtime Contract

Arasan uses process-global state and temporarily redirects the process's C++
standard streams. Run only one `ArasanEngine` at a time in a process. The
wrapper enforces that policy within one linked copy of this package; an app
must not load multiple copies and run them concurrently.

The line handler runs in protocol order on a wrapper-owned serial background
queue, not the main actor. Dispatch UI updates to the main actor. `stop()` is
idempotent and safe to call from the line handler, but it blocks until native
teardown completes, so UI code should call it away from the main actor. A
stopped instance can be started again.

The engine receives an explicit 4 MiB pthread stack without changing the host
process's stack resource limit. The embedded entry point intentionally calls the
package-owned `initArasanEmbeddedGlobals()` instead of upstream
`globals::initGlobals()`: upstream's version attempts a process-wide stack-limit
increase that physical Apple devices can reject even though the explicitly
sized engine thread is valid. The package-owned initializer mirrors the
upstream function's non-stack initialization and must be reconciled whenever
the vendored engine is updated.

`sendCommand(_:)` accepts one trusted UCI command line. It rejects multiline
input, embedded NULs, commands larger than 1 MiB, and runtime attempts to
replace the NNUE network. Create a newly configured engine when changing NNUE,
and do not pass untrusted user text directly to UCI. The wrapper also fixes
Arasan's `Threads` option at `1`: the current vendored pool cannot safely shrink
an in-process worker during teardown without a vendor change.

`ArasanSoakRunner` also serializes its event handler on the protocol-consumption
path. Keep that handler fast and dispatch logging or other slow work elsewhere;
blocking it can delay response recognition and grow the in-memory output
backlog.

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

Before startup, the wrapper checks that the configured NNUE is a regular file
with the byte count and format header required by this vendored Arasan
snapshot. Caller-provided NNUE paths must remain stable until startup has
finished. Opening-book and tablebase paths are also constrained to one safe UCI
line; the wrapper validates their existence when the related feature is
enabled, but it does not checksum caller-provided assets.

## Opening Book

Opening books make the engine play precomputed opening moves instead of
searching from the first move. `ArasanEmbedded` leaves opening books disabled by
default so normal tests and examples do not depend on an external `book.bin` or
book-move selection policy. Apps can opt in explicitly when they want book play.

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

Run `Scripts/validate.sh` for the complete offline release gate. See
`Docs/Testing.md` for its individual checks, Swift Testing suite structure,
`arasan-smoke`, `arasan-soak`, optional external-asset coverage, optional manual
GitHub-hosted validation, and the Lichess-derived regression corpus.

GitHub-hosted validation is optional, manual-only, and nonblocking. Dispatch an
already-published branch or tag with `Scripts/run-github-ci.sh [branch-or-tag]`;
the helper never commits or pushes local work.

## Relationship To SwiftChessTools

`ArasanEmbedded` speaks UCI. `SwiftChessTools` provides reusable chess rules,
notation, UI, and `ChessUCI` helpers that can parse or format UCI around an
engine. A realistic app should usually combine both packages rather than making
the engine wrapper responsible for game state or UI.

## Relationship To SwiftChessDemo

`SwiftChessDemo` shows how a real app can combine Swift chess rules/UI with an
embedded engine. It can run games with either `StockfishEmbedded` or
`ArasanEmbedded`, which makes it the best reference app for seeing this package
used in a realistic SwiftUI chess-playing experience.

## Licensing

Package-owned code is MIT licensed. The vendored Arasan engine source, selected
upstream documentation, bundled NNUE file, and Fathom Syzygy probing source keep
their upstream notices. The retained core source tree includes upstream utility
sources used to regenerate the opening-book fixture; those utilities are not
library products. GUI/font assets, external upstream test corpora, and
opening-book source material are intentionally not vendored.

Source and binary distributions must preserve the package, Arasan, and Fathom
license notices. See `LICENSE`, `ThirdParty/Arasan/LICENSE`,
`ThirdParty/Arasan/src/syzygy/LICENSE`, and `Docs/Provenance.md`.
