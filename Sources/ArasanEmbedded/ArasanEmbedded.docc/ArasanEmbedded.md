# ``ArasanEmbedded``

Run Arasan in-process from an iOS, iPadOS, or macOS app.

## Overview

ArasanEmbedded provides an engine bridge, not chess rules, game state, UI, or a
typed UCI parser. Its Swift API configures runtime assets and forwards UCI
commands/output. The package, Arasan, and bundled network use permissive MIT
licensing; retain the package, Arasan, and Fathom notices.

## Getting started

Add the `ArasanEmbedded` package product. Its required NNUE evaluation network
is bundled, so the default configuration needs no separate model download.
The [README quick start](https://github.com/Trickfest/ArasanEmbedded#quick-start-with-swift-package-manager)
covers installation and the default resources.

The following one-search task waits for UCI readiness and shuts down off the UI
actor:

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

Keep the task handle to cancel it with the owning screen and observe its
throwing result to report startup errors. An async command-line client uses
`try await searchTask.value` before exiting. This example has no startup
deadline; production clients should use timeouts and request attribution as
shown by SwiftChessDemo.

## Runtime assets

``ArasanEngine/Configuration`` defaults to the bundled network with opening
books and tablebases disabled. Custom networks must pass the pinned format/size
check; keep the file stable through startup. Optional books and Syzygy directories
are caller-owned and configured before startup.

Malformed FEN rejection preserves the previous valid board in this snapshot.
That recovery safeguard does not replace app-level validation of user positions.

## Lifecycle and threading

`start()` validates configuration, launches the engine, and sends UCI setup;
it does not wait for readiness. Observe `uciok` and `readyok` before searching.
`isRunning` describes the loop, not readiness. Output is ordered on a serial
background queue. Dispatch UI work to the main actor and keep blocking teardown
away from it.

UCI `stop` requests a search's terminal bestmove; wrapper `stop()` shuts down
the session. It is safe to repeat, and a stopped instance can restart. Arasan
does not expose Stockfish's state-preserving suspend/resume API. The embedded
Threads option stays at one; runtime Threads and NNUE-file changes are rejected.

Generate single-line UCI from validated app state. Only one ArasanEngine may
run within a linked package copy, and the app must serialize Arasan with
Stockfish because both use process-wide streams. They do not share a
cross-package native scheduler.

## Reference app and validation

[SwiftChessDemo](https://github.com/Trickfest/SwiftChessDemo) uses both embedded
engines with SwiftChessTools. See the repository's
[Examples](https://github.com/Trickfest/ArasanEmbedded/blob/main/Docs/Examples.md),
[Testing](https://github.com/Trickfest/ArasanEmbedded/blob/main/Docs/Testing.md),
and [Troubleshooting](https://github.com/Trickfest/ArasanEmbedded/blob/main/Docs/Troubleshooting.md)
guides. ``ArasanSoakRunner`` provides repeated, non-UI validation with structured
progress events, timeouts, cancellation, and summary counters.

## Topics

### Engine API

- ``ArasanEngine``
- ``ArasanEngine/Configuration``
- ``ArasanEngine/Error``

### Repeated validation

- ``ArasanSoakRunner``
- ``ArasanSoakRunner/Configuration``
- ``ArasanSoakRunner/PositionSpec``
- ``ArasanSoakRunner/SearchLimit``
- ``ArasanSoakRunner/Event``
- ``ArasanSoakRunner/Summary``
