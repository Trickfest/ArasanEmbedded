# Examples

This document collects copy-paste examples for exercising the main
`ArasanEmbedded` options.

## Minimal Search

```swift
let engine = ArasanEngine { line in
    print(line)
}

try engine.start()
engine.sendCommand("position startpos")
engine.sendCommand("go depth 6")
```

Watch for:

```text
readyok
bestmove ...
```

## Search From FEN

```swift
try engine.start()
engine.sendCommand("position fen 6k1/8/8/8/8/8/8/6KQ w - - 0 1")
engine.sendCommand("go depth 4")
```

## Opening Book

```swift
let configuration = ArasanEngine.Configuration(
    useOpeningBook: true,
    openingBookURL: Bundle.main.url(forResource: "book", withExtension: "bin")
)

let engine = ArasanEngine(configuration: configuration) { line in
    print(line)
}
```

## Syzygy Tablebases

```swift
let configuration = ArasanEngine.Configuration(
    useTablebases: true,
    tablebaseDirectoryURL: URL(fileURLWithPath: "/Users/me/Chess/Syzygy345"),
    tablebaseProbeDepth: 4,
    syzygyUses50MoveRule: true
)
```

## Custom NNUE

```swift
let configuration = ArasanEngine.Configuration(
    nnueURL: URL(fileURLWithPath: "/Users/me/Chess/arasan-custom.nnue")
)
```

## CLI Soak

Use `arasan-soak` when you want repeated non-GUI validation:

```sh
swift run arasan-soak --iterations 5 --movetime 500
```

See `Docs/Testing.md` for the full test-suite guide and additional soak
examples.

## SwiftUI Harness Pattern

Use an observable model that owns one engine instance, appends raw UCI lines to
state, and exposes toggles for runtime options before starting the engine:

```swift
@MainActor
final class EngineHarnessModel: ObservableObject {
    @Published var lines: [String] = []
    @Published var useOpeningBook = false
    @Published var useTablebases = false
    @Published var tablebasePath = ""

    private var engine: ArasanEngine?

    func start() throws {
        let configuration = ArasanEngine.Configuration(
            useOpeningBook: useOpeningBook,
            useTablebases: useTablebases,
            tablebaseDirectoryURL: tablebasePath.isEmpty
                ? nil
                : URL(fileURLWithPath: tablebasePath),
            tablebaseProbeDepth: 4
        )

        let engine = ArasanEngine(configuration: configuration) { [weak self] line in
            Task { @MainActor in
                self?.lines.append(line)
            }
        }
        self.engine = engine
        try engine.start()
    }

    func searchStartPosition(depth: Int) {
        engine?.sendCommand("position startpos")
        engine?.sendCommand("go depth \(depth)")
    }

    func stop() {
        let engine = engine
        self.engine = nil
        Task.detached(priority: .userInitiated) {
            engine?.stop()
        }
    }
}
```

This pattern is appropriate for an iOS/macOS smoke app. A production app should
usually parse output with `ChessUCI` and keep board state in `ChessCore`.
`stop()` waits for native teardown, so the example deliberately performs it
away from the main actor.
