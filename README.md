# ArasanEmbedded

[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FTrickfest%2FArasanEmbedded%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Trickfest/ArasanEmbedded) [![Supported platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FTrickfest%2FArasanEmbedded%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Trickfest/ArasanEmbedded)

ArasanEmbedded runs the Arasan chess engine in-process from an iOS, iPadOS, or
macOS app. This SwiftPM-first package's small Swift API, `ArasanEngine`,
configures runtime assets, sends UCI commands, and receives UCI output.

This package is the engine bridge, not a chess rules library, board UI, or UCI
parser. Use [SwiftChessTools](https://github.com/Trickfest/SwiftChessTools) for
those pieces. [SwiftChessDemo](https://github.com/Trickfest/SwiftChessDemo)
shows both embedded engines working in one app.

## Before you start

- **License:** Package-owned code, Arasan, and the bundled network use
  permissive MIT licensing. Preserve the package, Arasan, and Fathom notices;
  see [Licensing](#licensing).
- **Requirements:** Swift 6.2 or newer and Xcode 26 or newer, targeting
  iOS/iPadOS 26 or macOS 26 and later. Apple arm64 is supported; Intel Macs and
  x86_64 simulators are not.
- **Network:** The required NNUE file is bundled as a package resource. Default
  searches need no separate download. Opening books and Syzygy tablebases are
  optional, caller-owned assets and are disabled by default.

The badges link to the Swift Package Index's compatibility results. They are
separate from this repository's local validation instructions.

## Installation

In Xcode, choose **File > Add Package Dependencies**, enter
`https://github.com/Trickfest/ArasanEmbedded.git`, and add the `ArasanEmbedded`
product to your app target.

For a manifest-based client, add these entries to its existing manifest:

```swift
dependencies: [
    .package(
        url: "https://github.com/Trickfest/ArasanEmbedded.git",
        from: "1.4.0"
    ),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "ArasanEmbedded", package: "ArasanEmbedded"),
        ]
    ),
]
```

This example selects the source generation described below. When choosing
another version, use that version's setup instructions.

## Quick start with Swift Package Manager

### Use the bundled network

NNUE stands for *Efficiently Updatable Neural Network*. It is the data Arasan
uses to evaluate chess positions, not another executable. This snapshot bundles
`arasanv8-20261005.nnue`, 25,024,576 bytes: roughly 25 MB (24 MiB).
SwiftPM copies it into the package
resource bundle; you do not add it to your app manually.

### Run one search

This example buffers output, waits for readiness, then stops after one
`bestmove`. The detached task keeps blocking shutdown off the UI actor.

```swift
import ArasanEmbedded

let searchTask = Task.detached {
    let (lines, output) = AsyncStream<String>.makeStream()
    let engine = ArasanEngine { line in
        output.yield(line)
    }
    defer {
        engine.stop()
        output.finish()
    }

    try engine.start()
    var receivedUCI = false

    for await line in lines {
        print(line)
        if line.hasPrefix("info string ArasanEmbedded error")
            || line.hasPrefix("bestmove ") {
            break
        }
        if line == "uciok" {
            receivedUCI = true
        } else if line == "readyok" && receivedUCI {
            engine.sendCommand("position startpos")
            engine.sendCommand("go depth 8")
        }
    }
}
```

Keep `searchTask` so you can cancel it when leaving the screen. In an async
command-line client, use `try await searchTask.value` to keep the process alive
and observe startup errors. A UI owner should also observe that throwing task's
result and present any error. This one-search example has no startup deadline;
a production session also needs timeouts. See [Examples](Docs/Examples.md)
and SwiftChessDemo's engine providers for a fuller lifecycle.

## Runtime assets

The default `ArasanEngine.Configuration` selects the bundled network and
disables opening books and tablebases. Before startup, the wrapper checks that
the network is a regular file with the required byte count and format header.
A custom network must match the vendored format and remain stable through startup.

Configure optional resources before creating/starting the engine:

- [Opening books](Docs/OpeningBooks.md): opt into a caller-provided Arasan
  `book.bin` file.
- [Syzygy tablebases](Docs/Tablebases.md): opt into a caller-provided directory
  of endgame tables.
- [Examples](Docs/Examples.md): configuration snippets, including custom NNUE.

Paths must be representable as a single safe UCI line. The wrapper checks
required paths but does not checksum caller-provided books or tablebases.
Bundled network identity is recorded in [Provenance](Docs/Provenance.md).

## Lifecycle and threading

- `start()` validates configuration, launches the engine, and sends `uci`,
  resource options, and `isready`. Wait for both replies before searching;
  a successful return is not a readiness signal.
- Output arrives in order on a serial background queue. Dispatch UI updates
  to the main actor, and keep handlers brief.
- `sendCommand(_:)` accepts one trusted UCI line. Generate it from validated
  app state; do not pass arbitrary user text through to native code.
- `sendCommand("stop")` requests the current search's terminal `bestmove`.
  `engine.stop()` instead shuts down the wrapper. It is safe to repeat and a
  stopped instance may be started again.
- Shutdown blocks through native teardown. Call it off the UI actor. Calling
  it from the output handler is supported.
- The embedded engine uses one search thread. Runtime `Threads` and NNUE-file
  changes are rejected. Create a newly configured engine to change NNUE.
- `isRunning` reports whether the loop is running, not whether it is ready for
  a new search.

Both embedded engines use process-wide C++ streams. Their native ownership
guards are not a cross-package scheduler: your app must serialize Stockfish
and Arasan sessions. See [Architecture](Docs/Architecture.md) for the stream
boundary, native initialization, and repository layout.

## Reference app

[SwiftChessDemo](https://github.com/Trickfest/SwiftChessDemo) combines
ArasanEmbedded, [StockfishEmbedded](https://github.com/Trickfest/StockfishEmbedded),
and SwiftChessTools for human-versus-engine and engine-versus-engine play,
evaluation display, suggestions, and move history.

Use the demo as the shared end-to-end example rather than creating a second
integration app. Neither embedded package owns the app's chess rules or UI.

## Testing and troubleshooting

From a clone on an Apple-silicon Mac, run `Scripts/validate.sh` for the full
local gate. Its default checks use bundled/offline fixtures; optional Syzygy
downloads are a separate opt-in step.

[Testing](Docs/Testing.md) distinguishes package tests, CLI smokes/soaks,
build-only checks, and physical-device checks.
[Troubleshooting](Docs/Troubleshooting.md) covers configuration failures,
readiness, engine switching, and unsupported targets. GitHub-hosted validation
is optional, manually dispatched, and nonblocking.

## Maintenance and provenance

- [Architecture](Docs/Architecture.md): wrapper design and source layout.
- [Examples](Docs/Examples.md): search and configuration patterns.
- [Provenance](Docs/Provenance.md): source and network identity.
- [Updating Arasan](Docs/UpdatingArasan.md): maintainer update procedure.
- [Changelog](CHANGELOG.md): package change history.

Current vendored upstream commit: `d013300031c382061d37941ca6acad43cd525145`,
described by upstream as `v26.0-36-gd0133000`: Arasan 26.0 plus thirty-six
subsequent commits on `master`. The DocC catalog at
`Sources/ArasanEmbedded/ArasanEmbedded.docc` documents the public Swift API.

## Licensing

Package-owned code is MIT licensed. The vendored Arasan engine source, selected
upstream documentation, bundled NNUE file, and Fathom Syzygy probing source keep
their upstream notices. The retained core source tree includes upstream utility
sources used to regenerate the opening-book fixture; those utilities are not
library products. GUI/font assets, external upstream test corpora, and
opening-book source material are intentionally not vendored.

Source and binary distributions must preserve the package, Arasan, and Fathom
license notices. See [LICENSE](LICENSE), [Arasan's license](ThirdParty/Arasan/LICENSE),
[Fathom's license](ThirdParty/Arasan/src/syzygy/LICENSE), and
[Provenance](Docs/Provenance.md).
