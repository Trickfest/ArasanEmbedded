# Changelog

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

## 0.1.0 - 2026-06-24

- Initial `ArasanEmbedded` package scaffold.
- Vendor Arasan from upstream `master` commit `ac0b2c14fdcaec44812407ca3af795c41c6460ac`.
- Add SwiftPM-first `ArasanEmbedded` library product and `arasan-smoke` CLI.
- Add in-process Arasan UCI wrapper, bundled NNUE resource, opening-book options,
  and caller-provided Syzygy tablebase configuration.
- Add package tests covering configuration validation, UCI handshake, short
  search, and process-wide single-engine policy.
- Add SPI-ready package metadata and CI workflow.
