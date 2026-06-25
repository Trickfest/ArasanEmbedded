# Changelog

## 0.1.0 - 2026-06-24

- Initial private `ArasanEmbedded` package scaffold.
- Vendor Arasan from upstream `master` commit `ac0b2c14fdcaec44812407ca3af795c41c6460ac`.
- Add SwiftPM-first `ArasanEmbedded` library product and `arasan-smoke` CLI.
- Add in-process Arasan UCI wrapper, bundled NNUE resource, opening-book options,
  and caller-provided Syzygy tablebase configuration.
- Add package tests covering configuration validation, UCI handshake, short
  search, and process-wide single-engine policy.
- Add SPI-ready package metadata and private CI workflow.
