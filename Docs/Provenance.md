# Provenance

`ArasanEmbedded` vendors Arasan from:

```text
https://github.com/jdart1/arasan-chess
```

Current vendored upstream commit:

```text
c51273aa812c38bd54460adf68f2e15c32e74d71
```

Commit message:

```text
update submodule information
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

Its checked-in identity is:

```text
Byte count: 25024576
SHA-256: b42f9e13a37debb4af425d2ca74b5edff1d8034a616806bccdb67b79530201ac
Format header: 41 52 41 08 (ARA plus version 8)
```

`Scripts/validate.sh` pins and verifies all three values before building so an
accidental same-format resource replacement cannot silently invalidate this
record.

The materialized Fathom source comes from:

```text
https://github.com/jdart1/Fathom
c9c6fef0dddc05d2e242c183acf5833149ab676d
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

No local adjustment is carried in `ThirdParty/Arasan/src/globals.cpp`. The
package-owned embedded entry point instead calls
`initArasanEmbeddedGlobals()`, which mirrors upstream
`globals::initGlobals()` without its process-wide stack-limit mutation.
`AEEngine` supplies the required 4 MiB pthread stack directly, preventing the
upstream failure path from terminating a physical Apple host. The two
initializers must be reconciled whenever the upstream snapshot changes.

Package-owned bridge code converts Fathom's otherwise fatal allocation/mapping
paths into C++ exceptions at the include boundary and catches them on the
engine thread. That containment lives in
`Sources/CArasanEmbedded/ArasanSyzygyProbe.cpp`; the materialized Fathom files
are unchanged.

## Excluded Upstream Material

The retained core `src` tree includes `src/util`, including the upstream
`makebook` source used to regenerate the package's tiny opening-book fixture.
Those utility programs are not exposed as package products. The package
intentionally does not vendor Arasan's GUI, GUI fonts, Visual Studio project
files, external upstream test corpus, opening-book source material, training
logs, or NNUE training-source files. Those assets are not needed to build or
use the embedded UCI wrapper and would make the Swift package larger and less
focused.

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

Source and binary distributors must also retain the package-owned MIT notice at
the repository root. A binary-distribution notice bundle should therefore
include all three license files.
