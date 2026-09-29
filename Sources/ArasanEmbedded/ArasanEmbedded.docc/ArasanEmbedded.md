# ``ArasanEmbedded``

Embed the Arasan UCI chess engine directly in an iOS, iPadOS, or macOS app.

## Overview

ArasanEmbedded packages the MIT-licensed Arasan engine behind a small Swift
API. It bundles the required NNUE evaluation network, so the default
configuration is ready to search without downloading an additional model.

Create an ``ArasanEngine``, start it, and send standard UCI commands:

```swift
import ArasanEmbedded

let engine = ArasanEngine { line in
    print(line)
}

try engine.start()
engine.sendCommand("position startpos moves e2e4")
engine.sendCommand("go depth 8")

// After the line handler receives `bestmove ...`:
engine.stop()
```

Starting an engine sends `uci`, applies its resource options, and then sends
`isready`. A production client should wait for both `uciok` and `readyok`
before beginning a search.

> Important: Arasan uses process-global state, so only one engine may be
> active in a process. Output arrives in order on a background serial queue.
> Dispatch UI work to the main actor, and call the blocking `stop()` method
> away from the main actor.

## Runtime assets

``ArasanEngine/Configuration`` uses the bundled NNUE network by default and
leaves opening books and Syzygy tablebases disabled. Apps may opt into an
Arasan `book.bin` file or a caller-managed Syzygy directory before starting
the engine. These optional assets are not bundled.

Use ``ArasanSoakRunner`` for repeated, non-UI engine validation with structured
progress events, timeouts, cancellation, and summary counters.

## Topics

### Engine lifecycle

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
