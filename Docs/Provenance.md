# Provenance

`ArasanEmbedded` vendors Arasan from:

```text
https://github.com/jdart1/arasan-chess
```

Current vendored upstream commit:

```text
ac0b2c14fdcaec44812407ca3af795c41c6460ac
```

Commit message:

```text
Fix for large hash sizes: cast hash index to size_t, not int.
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
