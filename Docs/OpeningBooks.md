# Opening Books

Arasan can use an opening book through its UCI `OwnBook` and `BookPath` options.
`ArasanEmbedded` supports these options but keeps opening book usage disabled by
default.

## Why Disabled By Default

Opening books are useful for game play, but normal tests and examples should not
depend on an external `book.bin` or book-move selection policy. For a reusable
embedded engine package, the default should prove engine startup, NNUE loading,
search, and `bestmove` behavior without hidden opening policy. Apps can opt in
explicitly when they want book play.

## Enabling A Book

Bundle or download an Arasan-compatible `book.bin`, then pass its URL:

```swift
let bookURL = Bundle.main.url(forResource: "book", withExtension: "bin")!

let configuration = ArasanEngine.Configuration(
    useOpeningBook: true,
    openingBookURL: bookURL
)

let engine = ArasanEngine(configuration: configuration) { line in
    print(line)
}
```

The wrapper sends:

```text
setoption name BookPath value /path/to/book.bin
setoption name OwnBook value true
```

## Using Arasan's Default Book Path

You may enable book mode without passing a path:

```swift
let configuration = ArasanEngine.Configuration(useOpeningBook: true)
```

In that case Arasan uses its own default path resolution for `book.bin`. This is
less predictable in app bundles, so app code should normally pass an explicit
URL.

## Missing Book Behavior

If `useOpeningBook` is true and `openingBookURL` is non-nil, `ArasanEmbedded`
validates the file before starting the engine. Missing explicit book files throw
`ArasanEngine.Error.missingOpeningBook`.

If `useOpeningBook` is true and no path is provided, Arasan owns the default
path lookup. That mode is intended for advanced users who know where Arasan will
look for `book.bin`.

## Test Fixture

`Resources/OpeningBooks` contains a tiny repo-owned PGN and generated
`book.bin`. The default XCTest suite uses that book to prove that Arasan honors
`OwnBook` and `BookPath` with a real engine run.

The fixture's first move is `1. a3`, so the expected book response from the
starting position is:

```text
bestmove a2a3
```

Regenerate the binary fixture with:

```sh
Scripts/regenerate-opening-book-fixture.sh
```
