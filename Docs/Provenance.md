# Provenance

`ArasanEmbedded` vendors Arasan from:

```text
https://github.com/jdart1/arasan-chess
```

Current vendored upstream commit:

```text
c4bfcab0d5873cb5f61531426fad7a1b3abfe7f1
```

Commit message:

```text
Makefile fix
```

## Included Upstream Material

The vendored copy under `ThirdParty/Arasan` includes:

- Arasan engine source under `ThirdParty/Arasan/src`
- selected upstream documentation under `ThirdParty/Arasan/doc`
- upstream `LICENSE` and `README.md`
- the current Arasan NNUE network file required by this package
- the Fathom Syzygy probing submodule materialized under
  `ThirdParty/Arasan/src/syzygy`

The package currently bundles this Arasan NNUE file as a SwiftPM resource:

```text
ThirdParty/Arasan/network/arasanv8-20260622.nnue
```

## Local Vendored Adjustments

`ArasanEmbedded` carries wrapper-specific adjustments in the vendored source:

- `ThirdParty/Arasan/src/input.cpp`: when `ARASAN_EMBEDDED_STREAM_INPUT` is
  defined, command polling reads from redirected C++ streams instead of polling
  platform stdin file descriptors. This lets the in-process wrapper feed UCI
  commands without running Arasan as a separate process.

The arm64 NEON `dpbusd_epi32` sparse NNUE accumulation fix is now included
upstream in Arasan commit `58c58cf9`, so this package no longer carries that
fix as a local vendored adjustment.

Arasan's mate-distance-pruning fix for issue #70 is now included upstream in
Arasan commit `b2cbcae8`, so this package no longer carries a local hash-score
clamp workaround for that debug assertion.

## Excluded Upstream Material

This package intentionally does not vendor Arasan's GUI, GUI fonts, Visual
Studio project files, upstream test corpus, development tools, opening-book
source material, training logs, or NNUE training-source files. Those assets are
not needed to build or use the embedded UCI wrapper and would make the Swift
package larger and less focused.

Opening-book support remains available through caller-provided `book.bin`
files; see `Docs/OpeningBooks.md`.

## License

Arasan is MIT licensed by Jon Dart. The upstream license file is preserved at:

```text
ThirdParty/Arasan/LICENSE
```

The Fathom Syzygy probing source carries its own upstream license file at:

```text
ThirdParty/Arasan/src/syzygy/LICENSE
```

Do not remove either notice when updating vendored source.
