# Changelog

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
