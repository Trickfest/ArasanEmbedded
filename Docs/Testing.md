# Testing

`ArasanEmbedded` uses non-GUI tests to validate the Swift wrapper, the embedded
Arasan UCI lifecycle, bundled NNUE loading, runtime asset options, and repeated
search behavior. There are no Objective-C or GUI tests because the package is
SwiftPM-first and exposes a Swift-facing API.

## Full Local Release Gate

Run this gate before a public release or before committing behavior changes:

```sh
swift package dump-package
swift build
swift test
swift run arasan-smoke --depth 1
swift run arasan-soak --iterations 5 --movetime 500
xcodebuild -scheme ArasanEmbedded -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -derivedDataPath .build/xcode-ios build
```

`swift test` is the XCTest suite. The two CLI commands exercise the package as a
consumer would, and the iOS simulator build verifies that the SwiftPM package
continues to build for iOS/iPadOS.

## XCTest Suite

The package tests live in `Tests/ArasanEmbeddedTests`.

`ArasanEmbeddedTests.swift` covers configuration and basic engine behavior:

- default configuration uses the bundled NNUE file
- opening-book options build the expected UCI commands
- Syzygy tablebase options build the expected UCI commands
- missing NNUE/book/tablebase paths are rejected before engine start
- invalid tablebase probe depth is rejected
- UCI startup reaches `uciok` and `readyok`
- a short real search returns `bestmove`
- the process-wide single-engine policy is enforced

`ArasanEngineContractTests.swift` covers wrapper lifecycle contracts:

- startup emits identity, option, `uciok`, and `readyok` lines
- repeated `isready` probes return `readyok`
- `bestmove` lines have valid UCI move syntax
- start and stop are predictable and idempotent where expected
- commands before start and after stop are ignored safely
- `uci` can be issued again after startup
- concurrent command enqueue does not deadlock
- back-to-back searches return best moves
- UCI `stop` during a bounded search returns a valid best move promptly
- `ArasanSoakRunner` completes a short in-process run

`ArasanLichessRegressionTests.swift` covers the curated Lichess corpus:

- the corpus has the expected row count and theme coverage
- every row has source/provenance fields
- every normalized position returns an allowed move at depth 4

The regression test sends `ucinewgame` and waits for `readyok` between
independent puzzle positions. That keeps the tactical checks deterministic and
avoids carrying search state from one puzzle into the next.

## CLI Smoke

`arasan-smoke` is a quick one-shot command-line validation tool. It starts the
engine, waits for `uciok` and `readyok`, searches one position, and waits for a
`bestmove` line.

Examples:

```sh
swift run arasan-smoke --depth 1
swift run arasan-smoke --fen "8/8/8/8/8/8/4K3/4k3 w - - 0 1" --depth 4
swift run arasan-smoke --book /path/to/book.bin --depth 8
swift run arasan-smoke --tablebases /path/to/syzygy --probe-depth 4 --fen "<endgame fen>"
```

Use this when you want the fastest real-engine sanity check.

## CLI Soak

`arasan-soak` runs repeated searches against one engine instance. It is the
command-line counterpart to `ArasanSoakRunner` and is the main long-running
non-GUI validation tool.

Common runs:

```sh
swift run arasan-soak --iterations 5 --movetime 500
swift run arasan-soak --iterations 100 --depth 8
swift run arasan-soak --positions Resources/Soak/lichess_puzzles.tsv --ready-each
```

Useful options:

- `--positions PATH`: Load a TSV corpus or plain FEN file. Can be repeated.
- `--iterations N`: Cap the run. Omit it for an indefinite local soak.
- `--depth N`, `--movetime MS`, `--nodes N`: Choose one search limit.
- `--timeout SECONDS`: Per-position `bestmove` timeout.
- `--stop-timeout SECONDS`: Timeout after sending `stop`.
- `--handshake-timeout SECONDS`: Timeout waiting for `uciok` or `readyok`.
- `--delay-ms MS`: Delay between iterations.
- `--ready-each`: Send `isready` before every search.
- `--continue-on-timeout`: Continue after a timeout instead of failing fast.
- `--log-output`: Print raw engine output.

The short CI run uses:

```sh
swift run arasan-soak --iterations 5 --movetime 250
```

Longer local soaks are useful before release candidates:

```sh
swift run arasan-soak --iterations 100 --depth 8 --ready-each
swift run arasan-soak --iterations 200 --movetime 250 --delay-ms 100
```

## Lichess Corpus

The default soak corpus is `Resources/Soak/lichess_puzzles.tsv`. It is a small
curated subset of the official Lichess puzzle database, which Lichess publishes
under CC0. The full database is not vendored.

See `Resources/Soak/README.md` for:

- source URL
- CC0 attribution
- normalization rule
- TSV column definitions

The key normalization rule is that Lichess puzzle FENs are before the
opponent's forcing move. The committed `fen` column is after applying the first
UCI move from the Lichess `Moves` field, and `expected_move` is the second UCI
move.

## CI

GitHub Actions runs the practical public gate:

- validate the package manifest
- build the package
- run `swift test`
- run `arasan-smoke`
- run a short `arasan-soak`
- build the iOS simulator package product

CI intentionally keeps the soak short. Longer soak runs belong in local release
validation.

## Adding Tests

For wrapper behavior, prefer lifecycle tests that assert UCI protocol boundaries
and process safety. Good examples are readiness probes, command ordering,
repeated searches, and timeout/stop behavior.

For search regression tests, prefer stable tactical positions with clear
expected moves. If a position has multiple engine-equivalent moves, put all
acceptable UCI moves in the corpus `allowed_moves` column. Avoid using the
corpus as a general engine-strength benchmark.

For new Lichess rows:

1. Start from the official puzzle CSV.
2. Apply the first move from `Moves` to create the searched FEN.
3. Use the second move from `Moves` as the expected move.
4. Verify the row against the current embedded Arasan snapshot.
5. Keep provenance fields intact.

Do not vendor the full Lichess export.
