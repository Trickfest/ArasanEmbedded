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
  NNUE network file, retained core utilities, and Fathom Syzygy probing source
  from upstream.
- `Docs/` - product documentation and advanced runtime asset guidance.

## Build And Test

Run the complete offline release gate before committing behavior changes:

```sh
Scripts/validate.sh
```

The script covers Debug and Release builds, normal and Thread Sanitizer tests,
CLI smoke/soak validation including constrained-stack startup, iOS simulator
and generic-device builds, API compatibility against its configured release
baseline, and license contents.
On a clean checkout it also verifies the committed SwiftPM source archive;
before a commit it verifies the exact worktree's license files and reports that
the committed-source archive check was skipped. Override its simulator with
`ARASAN_IOS_SIMULATOR_NAME` if needed.

Changes to embedded startup or native thread creation also require a disposable
local-package override in `SwiftChessDemo` and an engine-vs-engine smoke test on
a physical iOS/iPadOS device. The simulator runs inside a macOS host process and
does not reproduce every physical-device process limit. Never commit the local
package override.

GitHub-hosted validation is optional, manual-only, and not part of task,
merge, or release acceptance. When the user explicitly wants that secondary
check, dispatch the already-published branch or tag with:

```sh
Scripts/run-github-ci.sh [branch-or-tag]
```

The helper verifies GitHub CLI authentication and the remote workflow before
dispatching. It never commits or pushes local changes. A hosted run that cannot
start or finish because GitHub Actions credits are unavailable is nonblocking;
use `Scripts/validate.sh` for the expected local gate.

Optional external asset coverage downloads and caches a tiny Syzygy fixture:

```sh
Scripts/test-external-assets.sh
```

## Vendored Arasan

Arasan is vendored from `https://github.com/jdart1/arasan-chess`.
The current vendored upstream commit is:

```text
c51273aa812c38bd54460adf68f2e15c32e74d71
```

The Fathom Syzygy probing submodule is materialized as normal files under
`ThirdParty/Arasan/src/syzygy` so this repo is self-contained. Its current
upstream revision is:

```text
c9c6fef0dddc05d2e242c183acf5833149ab676d
```

The bundled network is `arasanv8-20260622.nnue`, 25,024,576 bytes, with SHA-256
`b42f9e13a37debb4af425d2ca74b5edff1d8034a616806bccdb67b79530201ac`.

When updating Arasan:

1. Fetch latest upstream `master`.
2. Re-vendor the core `src` tree (including `src/util`), selected upstream docs,
   required NNUE, and materialized Fathom source; do not vendor GUI/font assets,
   external upstream test corpora, opening-book source material, training
   artifacts, or nested `.git` directories.
3. Check whether the default NNUE filename changed.
4. Keep only the NNUE file required by the current vendored Arasan snapshot.
5. Compare upstream `globals::initGlobals()` with the package-owned
   `initArasanEmbeddedGlobals()` and carry forward every non-stack initialization
   step. Do not reintroduce upstream's process-wide stack-limit mutation into the
   embedded entry path.
6. Update `README.md`, `Docs/UpdatingArasan.md`, and `Docs/Provenance.md`.
7. Update `API_BASELINE` in `Scripts/validate.sh` to the release that consumers
   are upgrading from.
8. Run the local release gate and the physical-device consumer smoke test.

The current package is arm64-only. Arasan's NNUE code requires a compile-time
NEON or SSE backend, and SwiftPM cannot select those C++ defines per
architecture in a universal target. Do not add unsafe architecture flags or
edit vendor sources merely to make an x86_64 build appear to pass; treat an
architecture expansion as an explicit design change with cross-architecture
tests.

## Product Boundaries

`ArasanEmbedded` starts Arasan, applies resource-related UCI options, sends UCI
commands, and returns UCI output lines. It does not parse rich UCI models, own
chess rules, mutate FEN, choose engine policy, or render UI. Those concerns
belong in `SwiftChessTools` or the consuming app.

Only one engine may be active process-wide. Output callbacks are ordered on a
serial background queue. `stop()` blocks through native teardown, is safe from
the callback, and permits restarting the same instance. Keep raw commands to
one trusted UCI line, configure NNUE only before `start()`, and keep Arasan's
embedded `Threads` option fixed at `1` until upstream pool teardown is safe.

Do not review or casually refactor `ThirdParty/Arasan` as package-owned code.
Limit changes there to intentional upstream refreshes or narrowly documented
integration patches. Prefer bridge-owned guards and tests when a vendor failure
can be contained without modifying upstream source.

## Licensing

The package-owned wrapper code is MIT licensed. Vendored Arasan source and the
bundled network file are MIT licensed by Jon Dart; Fathom has its own preserved
MIT notice. Source and binary distributions must keep the root, Arasan, and
Fathom notices. Do not remove provenance files from `ThirdParty/Arasan`.
