# Testing

`ArasanEmbedded` uses Swift Testing plus small native bridge probes to validate
the Swift wrapper, embedded Arasan UCI lifecycle, bundled NNUE loading, runtime
asset options, host stream-state restoration, and repeated search behavior. It
has no GUI test target because the package is SwiftPM-first and exposes a
Swift-facing API.

## Full Local Release Gate

Run this gate before a public release or before committing behavior changes:

```sh
Scripts/validate.sh
```

The script validates the manifest; performs Debug and Release builds; confirms
Release binaries do not import native assertions; runs the normal and Thread
Sanitizer suites; exercises both CLIs, a child-process startup with a constrained
stack limit, and invalid-input paths; builds for an iOS simulator and a generic
iOS device; checks the public API against the configured `v1.0.6` baseline; and
verifies all three required worktree
license files. On a clean checkout it also checks those licenses inside the
committed SwiftPM source archive. `swift package archive-source` archives Git
HEAD rather than dirty/untracked files, so the script explicitly skips that
archive assertion during pre-commit work. It uses `iPhone 17 Pro` by default;
set `ARASAN_IOS_SIMULATOR_NAME` to another available simulator when needed.

The simulator runs inside a macOS host process, so a successful simulator build
or launch does not exercise every physical iOS process limit. Changes to native
startup, global initialization, or thread creation require the physical-device
consumer smoke below in addition to `Scripts/validate.sh`.

## Physical iOS Consumer Smoke

Before releasing a change to native startup or thread creation:

1. Use a disposable copy of `SwiftChessDemo` that resolves `ArasanEmbedded` to
   this local checkout. Do not commit the package override.
2. Build and run the app on a physical iPhone or iPad.
3. Run Arasan versus Arasan for at least 50 plies.
4. Run a mixed Stockfish-versus-Arasan game long enough for each engine to move
   several times.
5. Confirm the app remains alive, both engines continue returning `bestmove`,
   and no Arasan startup error appears.
6. Restore the normally resolved package before finishing.

## Swift Testing Suite

The package tests live in `Tests/ArasanEmbeddedTests`.

`ArasanConfigurationTests.swift` covers wrapper configuration:

- default configuration uses the bundled NNUE file
- opening-book options build the expected UCI commands
- Syzygy tablebase options build the expected UCI commands
- missing NNUE/book/tablebase paths are rejected before engine start
- incompatible NNUE files and unsafe multiline/trailing-whitespace resource
  paths are rejected
- invalid tablebase probe depth is rejected

`LichessCorpusTests.swift` covers the curated Lichess corpus:

- the corpus has the expected row count and theme coverage
- every row has source/provenance fields
- every row has normalized FEN and allowed UCI moves

`ArasanHashRegressionTests.swift` covers low-level search-score storage:

- legal ply-relative mate scores convert to the positive and negative hash
  bounds when stored in the hash table
- normal non-mate scores and the invalid-score sentinel are preserved

`ArasanEngineIntegrationTests.swift` covers real engine behavior:

- UCI startup reaches `uciok` and `readyok`
- a short real search returns `bestmove`
- the process-wide single-engine policy is enforced
- startup emits identity, option, `uciok`, and `readyok` lines
- repeated `isready` probes return `readyok`
- `bestmove` lines have valid UCI move syntax
- material-imbalance searches produce large centipawn scores with the expected
  sign
- start and stop are predictable and idempotent where expected
- callback-initiated, concurrent, raw-`quit`, release-without-stop, and restart
  lifecycle paths complete safely
- the native engine thread receives Arasan's required 4 MiB stack while the
  package-owned embedded initializer supports repeated startup and teardown
- commands before start and after stop are ignored safely
- malformed, multiline, NUL-containing, oversized, and runtime-NNUE commands
  are rejected without corrupting the UCI session
- runtime `Threads` changes are rejected so native teardown never inherits an
  unsafe dynamically resized vendor pool
- `uci` can be issued again after startup
- concurrent command enqueue and repeated ready probes do not deadlock or lose
  replies
- back-to-back searches return best moves
- UCI `stop` during a bounded search returns a valid best move promptly
- process-global options and host C++ stream state are restored between runs
- live option values are checked before and after reset
- output flushes do not invent protocol lines, and callbacks remain ordered
- `ArasanSoakRunner` validates input, handles task cancellation and concurrent
  run rejection, preserves timeout-boundary results, emits terminal events in
  order, and cannot attribute a stale `bestmove` to a later search
- a tiny generated `book.bin` fixture supplies a real opening-book best move
- every normalized position returns an allowed move at depth 4
- optional downloaded Syzygy fixtures produce real `tbhits` output

The engine integration suite is marked `.serialized` because Arasan is exposed
as one process-wide embedded engine instance. Corpus and configuration tests can
still run independently, but engine-starting tests intentionally do not overlap.

The Lichess-backed regression test sends `ucinewgame` and waits for `readyok`
between independent puzzle positions. That keeps the tactical checks
deterministic and avoids carrying search state from one puzzle into the next.

The optional Syzygy test is skipped by normal `swift test`. Enable it through
`Scripts/test-external-assets.sh` after downloading or verifying the fixture
files.

## CLI Smoke

`arasan-smoke` is a quick one-shot command-line validation tool. It starts the
engine, waits for `uciok` and `readyok`, searches one position, and waits for a
`bestmove` line.

Examples:

```sh
swift run arasan-smoke --depth 1
swift run arasan-smoke --fen "6k1/8/8/8/8/8/8/6KQ w - - 0 1" --depth 4
swift run arasan-smoke --book /path/to/book.bin --depth 8
swift run arasan-smoke --tablebases /path/to/syzygy --probe-depth 4 --fen "<endgame fen>"
```

Use this when you want the fastest real-engine sanity check.

The release gate also launches the already-built smoke executable in a child
process with a 2 MiB soft and hard stack resource limit. That regression proves
the package-owned entry path does not call upstream `globals::initGlobals()`,
which would attempt a forbidden increase to 4 MiB and terminate the process.

## Opening Book Fixture

The default Swift Testing suite includes a real opening-book integration test.
The fixture lives in `Resources/OpeningBooks`:

- `fixture.pgn`: a tiny repo-owned PGN whose first move is `1. a3`
- `book.bin`: the generated Arasan opening book committed for offline tests

The test configures Arasan with `OwnBook` and the fixture book, searches the
starting position, and expects `bestmove a2a3`. The move is intentionally odd,
which makes it clear that the result came from the book rather than normal
search.

Regenerate the binary fixture after changing the PGN:

```sh
Scripts/regenerate-opening-book-fixture.sh
```

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
- `--continue-on-timeout`: Continue only after `stop` produces that search's
  terminal `bestmove`; an unrecovered timeout always ends the run.
- `--log-output`: Print raw engine output.

Timeout and delay values must fit between zero (where allowed) and one year;
larger finite values are rejected before conversion to Swift `Duration`.

The short validation soak uses:

```sh
swift run arasan-soak --iterations 5 --movetime 500
```

Longer local soaks are useful before release candidates:

```sh
swift run arasan-soak --iterations 100 --depth 8 --ready-each
swift run arasan-soak --iterations 200 --movetime 250 --delay-ms 100
```

## Optional External Asset Tests

The default release gate does not download anything. To exercise real external
Syzygy tablebase files, run:

```sh
Scripts/test-external-assets.sh
```

That script:

1. reads `Resources/ExternalAssets/syzygy_kqvk.tsv`
2. downloads `KQvK.rtbw` and `KQvK.rtbz` from the Lichess Syzygy mirror when
   they are missing or checksum-invalid
3. verifies byte counts and SHA-256 checksums
4. stores the files in `.build/test-assets/syzygy`
5. runs only `downloadedKQvKSyzygyFixtureProducesTablebaseHits`

The current download is tiny:

- `KQvK.rtbw`: 272 bytes
- `KQvK.rtbz`: 5,392 bytes

Subsequent runs reuse the cached files. To force a fresh download, remove:

```sh
rm -rf .build/test-assets/syzygy
```

You can use a different directory by setting `ARASAN_SYZYGY_FIXTURE_DIR`:

```sh
ARASAN_SYZYGY_FIXTURE_DIR=/path/to/syzygy Scripts/test-external-assets.sh
```

To run the Swift Testing test directly after assets already exist:

```sh
ARASAN_RUN_EXTERNAL_ASSET_TESTS=1 \
ARASAN_SYZYGY_PATH=/path/to/syzygy \
swift test --filter downloadedKQvKSyzygyFixtureProducesTablebaseHits
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

## Optional Manual GitHub Validation

GitHub Actions does not run for pushes or pull requests. The manual workflow is
an optional, nonblocking secondary check and is not part of task, merge, or
release acceptance. It runs the same complete offline `Scripts/validate.sh`
gate on a macOS 26 runner with a deliberately short soak.

To dispatch an already-published branch or tag:

```sh
Scripts/run-github-ci.sh [branch-or-tag]
```

The helper verifies GitHub CLI authentication and that the remote ref contains
the manual workflow. It does not commit or push local work. The command prints
GitHub's run URL when available, plus a workflow-runs URL as a fallback.
Unavailable GitHub Actions credits or a failed hosted run do not block local
acceptance. Optional Syzygy downloads and longer soak runs remain explicit
local checks.

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
