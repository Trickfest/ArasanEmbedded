# Changelog

## 1.1.0 - 2026-07-13

### Added

- Add one-command offline validation covering Debug and Release builds, native
  assertion stripping, normal and Thread Sanitizer tests, CLI smoke and soak
  runs, simulator and generic iOS builds, API compatibility, and source-archive
  license contents.
- Add `Scripts/run-github-ci.sh` to manually dispatch optional GitHub-hosted
  validation for an existing remote branch or tag without committing or pushing.
- Add regression coverage for callback-safe shutdown, raw `quit`, restart,
  concurrent lifecycle calls, process-option reset, command validation,
  callback ordering and suppression, stream framing/restoration, native stack
  size, wrapper-owned global initialization, startup under a constrained host
  stack limit, soak cancellation and event ordering, timeout recovery, and
  CLI/corpus validation.
- Package the default Lichess-derived corpus with `arasan-soak`, so an installed
  executable can run without relying on the source checkout.

### Changed

- Refresh vendored Arasan source to upstream `master` commit
  `c51273aa812c38bd54460adf68f2e15c32e74d71`, including removal of its
  unmaintained NUMA-only code.
- Deliver engine output in order on a wrapper-owned serial background queue and
  start each configured engine with one atomic UCI command batch.
- Make lifecycle operations serialized and restartable, enforce one active
  engine per linked package copy, use a 4 MiB native engine-thread stack, and
  make `stop()` idempotent, callback-safe, and blocking through teardown.
- Replace upstream `globals::initGlobals()` in the embedded entry path with the
  package-owned `initArasanEmbeddedGlobals()`, which mirrors its non-stack
  initialization without modifying vendored source.
- Validate NNUE format, resource paths, raw UCI commands, soak settings, FEN
  input, CLI numeric arguments, and external-asset manifests before native
  engine work begins.
- Require every timed-out soak search to reach its terminal `bestmove` before
  another position can start, and serialize structured event delivery.
- Build native assertions out of Release configurations while retaining them in
  Debug, and document the current Apple arm64 architecture boundary.
- Fix embedded searches at one Arasan thread because the current vendored pool
  cannot safely shrink a dynamically created worker during in-process teardown.
- Keep GitHub-hosted validation optional, manual-only, and nonblocking while
  running the complete validation script with release-tag history available for
  API comparison.

### Fixed

- Prevent handler-initiated shutdown from joining the callback's own thread and
  eliminate start/stop/restart races, early-returning concurrent stops, queued
  command backlog during shutdown, and stale callbacks after stop.
- Reset Arasan's process-global options between instances and fully restore the
  host process's C++ stream buffers, ties, locale, format flags, and state.
- Release Fathom tablebase mappings during teardown.
- Prevent physical Apple hosts from terminating during Arasan startup by
  avoiding process-wide stack resource changes and using the explicitly sized
  engine thread instead.
- Treat output flushes as flushes rather than fabricated newlines, synchronize
  shared output framing, and preserve partial final output safely.
- Contain recoverable NNUE, tablebase, engine-thread, and native exception
  failures at the package boundary instead of allowing vendor fatal exits.
- Make CLI failures return a normal nonzero status, harden fixture scripts, and
  cap corpus reads even through symlinks, remove false-positive soak success
  paths, and prevent stale-`bestmove` attribution.

### Compatibility

- Existing public entry points remain available, including recovered-timeout
  continuation, and `ArasanSoakRunner.stop()` is additive. New resource
  validation failures use an internal `LocalizedError`, preserving exhaustive
  switches over the existing public `ArasanEngine.Error` cases. Runtime NNUE
  changes through raw UCI are now rejected; create a new configured engine
  instead. Runtime `Threads` changes are also rejected, and embedded searches
  remain at one engine thread.

## 1.0.6 - 2026-07-05

- Update vendored Arasan source to upstream `master` commit
  `c4bfcab0d5873cb5f61531426fad7a1b3abfe7f1`.
- Replace the local mate-score hash clamp workaround with Arasan's upstream
  mate-distance-pruning root-cause fix for debug assertion crashes when
  quiescence search stores mate-range hash scores.
- Refresh vendored Fathom Syzygy source and Arasan provenance documentation for
  the new upstream snapshot.

## 1.0.5 - 2026-07-02

- Clamp Arasan mate-score hash conversion at mate bounds instead of aborting in
  debug builds when a mate-range score is stored from a deeper ply.

## 1.0.4 - 2026-07-02

- Update vendored Arasan source to upstream `master` commit
  `36774cd7581685491ad0e0f77ec7b3a0a5763376`.
- Pick up Arasan's upstream arm64 NEON sparse NNUE accumulation fix, replacing
  the previous local vendored patch for that issue.
- Preserve and document the package-specific embedded stream-input polling path
  used by the in-process UCI wrapper.
- Refresh Arasan provenance and vendored-update documentation for the new
  snapshot.

## 1.0.3 - 2026-06-29

- Detach `std::cin` from `std::cout` while Arasan runs against wrapper-provided
  streams, avoiding flushes against redirected output during engine shutdown
  and restart.
- Add repeated stop/search lifecycle coverage for active searches and fresh
  engine starts.

## 1.0.2 - 2026-06-29

- Fix embedded search-time command polling so `stop` is observed while Arasan is
  actively searching through the wrapper's C++ stream input.
- Stop joining the engine thread only after it exits, avoiding a detached native
  thread reading from wrapper input objects that have already been destroyed.
- Add lifecycle regression coverage for stopping an active deep search and
  starting a fresh `ArasanEngine` instance.

## 1.0.1 - 2026-06-29

- Fix arm64 NEON sparse NNUE accumulation so Arasan reports material
  imbalances correctly on Apple Silicon.
- Add a material-imbalance integration regression test that verifies large
  positive and negative centipawn scores.
- Document the local vendored Arasan NEON adjustment and update the vendored
  refresh process to preserve or reconcile it.
- Refresh the README relationship note now that `SwiftChessDemo` can run with
  either `StockfishEmbedded` or `ArasanEmbedded`.

## 1.0.0 - 2026-06-28

- Prepare the first public `ArasanEmbedded` release.
- Update README status and installation guidance for public SwiftPM use.
- Keep the package SPI-ready with a root `Package.swift`, `.spi.yml`, CI,
  semantic-version release guidance, and focused product documentation.
- Confirm the package remains intentionally narrow: it starts Arasan, applies
  runtime asset options, sends UCI commands, and returns raw UCI output lines.
- Keep the bundled Arasan NNUE resource model and caller-provided opening-book
  and Syzygy tablebase configuration.
- Suppress a third-party Fathom conversion warning at the wrapper boundary
  without modifying vendored source.
- Add `ArasanSoakRunner` and the `arasan-soak` CLI for repeated non-GUI engine
  validation.
- Add a curated Lichess CC0 puzzle corpus for soak and search regression tests.
- Expand package tests with lifecycle contract coverage and Lichess-backed
  tactical regression coverage.
- Add the short CLI soak run to CI and the documented release gate.
- Add `Docs/Testing.md` as the canonical guide for the test suite, CLI smoke,
  CLI soak, CI coverage, and release validation.
- Add a real opening-book integration fixture and optional external Syzygy
  tablebase integration test with cached, checksum-verified downloads.
- Migrate package tests from XCTest to Swift Testing, with engine-starting
  coverage isolated in one serialized suite.

## 0.1.0 - 2026-06-24

- Initial `ArasanEmbedded` package scaffold.
- Vendor Arasan from upstream `master` commit `ac0b2c14fdcaec44812407ca3af795c41c6460ac`.
- Add SwiftPM-first `ArasanEmbedded` library product and `arasan-smoke` CLI.
- Add in-process Arasan UCI wrapper, bundled NNUE resource, opening-book options,
  and caller-provided Syzygy tablebase configuration.
- Add package tests covering configuration validation, UCI handshake, short
  search, and process-wide single-engine policy.
- Add SPI-ready package metadata and CI workflow.
