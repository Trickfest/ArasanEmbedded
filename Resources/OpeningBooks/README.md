# Opening Book Test Fixture

This directory contains the tiny Arasan opening-book fixture used by the test
suite.

`fixture.pgn` is a deliberately small, repo-owned PGN. The first move is
`1. a3`, which is legal but intentionally unlikely to be selected by normal
search. That makes it a useful integration fixture: when Arasan is configured
with `OwnBook` and this `book.bin`, the expected move from the starting
position is `a2a3`.

`book.bin` is generated from `fixture.pgn` with Arasan's upstream `makebook`
utility. Regenerate it with:

```sh
Scripts/regenerate-opening-book-fixture.sh
```

The binary is committed because it is tiny and keeps the default Swift Testing
suite offline and deterministic.
