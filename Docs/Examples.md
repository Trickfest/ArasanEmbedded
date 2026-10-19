# Examples

Start with the complete, readiness-gated [README example](../README.md#quick-start-with-swift-package-manager).
The search snippets below assume a retained, running engine whose handshake
has completed, and no other active search. Configuration snippets are applied
before creating/starting an engine; they do not themselves run a search.

## Search from FEN

```swift
engine.sendCommand("position fen 6k1/8/8/8/8/8/8/6KQ w - - 0 1")
engine.sendCommand("go depth 4")
```

Validate user positions in the app's rules layer before generating UCI. For a
new independent game, send `ucinewgame`, probe `isready`, and await `readyok`
before setting its position/search.

## Default resources

The default configuration can also be selected explicitly:

```swift
let engine = ArasanEngine(configuration: .default) { line in
    print(line)
}
```

It uses the bundled NNUE and disables opening-book moves and tablebase probing.
Start it with the readiness-gated lifecycle from the README before searching.

## Search limits and cancellation

Choose one limit for each search:

```swift
engine.sendCommand("position startpos moves e2e4")
engine.sendCommand("go movetime 250")
```

`go depth 8` and `go nodes 10000` are alternatives. To end an active search,
send `engine.sendCommand("stop")` and wait for `bestmove`. This does not shut
down the wrapper. `engine.stop()` blocks through teardown; unlike SFEngine,
a stopped ArasanEngine can restart and will perform its startup setup again.

## Opening books

```swift
import ArasanEmbedded
import Foundation

let configuration = ArasanEngine.Configuration(
    useOpeningBook: true,
    openingBookURL: Bundle.main.url(forResource: "book", withExtension: "bin")
)
let engine = ArasanEngine(configuration: configuration) { line in
    print(line)
}
```

Supply a real Arasan `book.bin` file and use the readiness-gated startup from
the README before searching. See [Opening books](OpeningBooks.md) for default
path and missing-file behavior.

## Syzygy tablebases

```swift
let configuration = ArasanEngine.Configuration(
    useTablebases: true,
    tablebaseDirectoryURL: URL(fileURLWithPath: "/Users/me/Chess/Syzygy345"),
    tablebaseProbeDepth: 4,
    syzygyUses50MoveRule: true
)
```

Create the engine with that configuration and the usual output handler.
See [Tablebases](Tablebases.md) for iOS/macOS storage and access guidance.

## Custom NNUE

```swift
let configuration = ArasanEngine.Configuration(
    nnueURL: URL(fileURLWithPath: "/Users/me/Chess/arasan-custom.nnue")
)
```

The file must match this snapshot's byte count and format header. Merely naming
another file `.nnue` does not make it compatible. Keep it stable through startup.
The default configuration already selects the bundled network.

## UI ownership

Keep one session owner and its task/engine alive. Observe errors thrown by
startup and dispatch output-derived UI changes to the main actor. Bound startup
and searches with client timeouts, reject replies belonging to old requests,
and schedule blocking shutdown off the UI actor when leaving a screen.

For SwiftUI, an `@MainActor` observable model can retain the engine/task and
publish received UCI lines. Keep controls such as `useOpeningBook`,
`useTablebases`, and a tablebase path in that model, then build the configuration
from them before starting. Forward background callbacks to the model with
`Task { @MainActor in ... }`; do not mutate published UI state on the callback
queue. Use `ChessUCI` to parse protocol output and `ChessCore` for board state,
rather than making the engine wrapper responsible for either.

For an owner with an `engine: ArasanEngine?` property, teardown can transfer the
retained engine to a detached task while immediately clearing the UI owner's
reference:

```swift
func stop() -> Task<Void, Never> {
    let engineToStop = engine
    engine = nil
    return Task.detached(priority: .userInitiated) {
        engineToStop?.stop()
    }
}
```

That method is a fragment for the observable owner, not a complete session
manager. Retain its returned task and await its `value` before starting another
embedded engine. Discard output from the previous session using request/session
identity.

The README's detached task demonstrates one search, not a full UI session
manager. Its returned task can be cancelled; an async command-line client must
await its throwing value before exiting. SwiftChessDemo is the shared SwiftUI
reference app; use its lifecycle coordination rather than adding another demo.

## CLI soak

Use the existing package CLI for repeated non-UI validation:

```sh
swift run arasan-soak --iterations 5 --movetime 500
```

See [Testing](Testing.md#cli-soak) for options, fixture provenance, and longer
runs. Keep the soak event handler fast; dispatch slow logging elsewhere.
